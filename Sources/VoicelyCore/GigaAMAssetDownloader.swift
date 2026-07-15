import CryptoKit
import Darwin
@preconcurrency import Foundation

enum GigaAMAssetDownloadError: Error, LocalizedError, Equatable {
    case requiresMacOS15
    case invalidRelativePath(String)
    case diskCapacityUnavailable
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case assetUnavailable(relativePath: String, revision: String)
    case sizeMismatch(relativePath: String, expected: Int64, actual: Int64)
    case checksumMismatch(relativePath: String, expected: String, actual: String)
    case insecureTopology(String)
    case lockUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS15:
            return "GigaAM requires macOS 15 or later."
        case .invalidRelativePath(let path):
            return "Invalid GigaAM asset path: \(path)"
        case .diskCapacityUnavailable:
            return "Could not verify free disk space for GigaAM assets."
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space for GigaAM assets: need \(required) bytes, have \(available) bytes."
        case .assetUnavailable(let path, let revision):
            return "GigaAM asset unavailable offline: \(path) at revision \(revision)."
        case .sizeMismatch(let path, let expected, let actual):
            return "GigaAM asset size mismatch for \(path): expected \(expected), got \(actual)."
        case .checksumMismatch(let path, let expected, let actual):
            return "GigaAM asset checksum mismatch for \(path): expected \(expected), got \(actual)."
        case .insecureTopology(let path):
            return "GigaAM model storage has insecure or unexpected topology: \(path)"
        case .lockUnavailable(let path):
            return "Could not acquire the GigaAM model lock: \(path)"
        }
    }
}

enum GigaAMPlatformReadiness {
    static func isSupported(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 15
    }

    static func requireSupported() throws {
        guard #available(macOS 15, *) else {
            throw GigaAMAssetDownloadError.requiresMacOS15
        }
    }
}

enum GigaAMSecureStorage {
    private static let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)

    static func requireDirectory(_ url: URL, strictPermissions: Bool = true) throws {
        let info = try lstatInfo(url)
        guard fileType(info.st_mode) == mode_t(S_IFDIR), info.st_uid == geteuid() else {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
        if strictPermissions, info.st_mode & unsafeWriteBits != 0 {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
    }

    static func requireRegularFile(_ url: URL, strictPermissions: Bool = true) throws {
        let info = try lstatInfo(url)
        guard fileType(info.st_mode) == mode_t(S_IFREG), info.st_uid == geteuid() else {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
        if strictPermissions, info.st_mode & unsafeWriteBits != 0 {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
    }

    static func hardenTree(at root: URL) throws {
        try requireDirectory(root, strictPermissions: false)
        guard chmod(root.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw GigaAMAssetDownloadError.insecureTopology(root.path)
        }
        for case let url as URL in enumerator {
            let info = try lstatInfo(url)
            switch fileType(info.st_mode) {
            case mode_t(S_IFDIR):
                guard info.st_uid == geteuid(), chmod(url.path, 0o700) == 0 else {
                    throw GigaAMAssetDownloadError.insecureTopology(url.path)
                }
            case mode_t(S_IFREG):
                guard info.st_uid == geteuid(), chmod(url.path, 0o600) == 0 else {
                    throw GigaAMAssetDownloadError.insecureTopology(url.path)
                }
            default:
                throw GigaAMAssetDownloadError.insecureTopology(url.path)
            }
        }
    }

    static func requireDirectoryChain(from root: URL, through descendant: URL) throws {
        let base = root.standardizedFileURL
        let target = descendant.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw GigaAMAssetDownloadError.insecureTopology(target.path)
        }
        try requireDirectory(base, strictPermissions: false)
        var cursor = base
        let suffix = target.path.dropFirst(base.path.count)
        for component in suffix.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            try requireDirectory(cursor, strictPermissions: false)
        }
    }

    static func secureTreeEntries(at root: URL, excluding names: Set<String> = []) throws -> [(String, Bool, Int64, String)] {
        var canonicalRootPath = try realPath(root)
        while canonicalRootPath.count > 1 && canonicalRootPath.hasSuffix("/") {
            canonicalRootPath.removeLast()
        }
        try requireDirectory(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw GigaAMAssetDownloadError.insecureTopology(root.path)
        }
        var result: [(String, Bool, Int64, String)] = []
        for case let url as URL in enumerator {
            let canonicalEntryPath = try realPath(url)
            guard canonicalEntryPath.hasPrefix(canonicalRootPath + "/") else {
                throw GigaAMAssetDownloadError.insecureTopology(url.path)
            }
            let relative = String(canonicalEntryPath.dropFirst(canonicalRootPath.count + 1))
            if names.contains(relative) {
                continue
            }
            let info = try lstatInfo(url)
            switch fileType(info.st_mode) {
            case mode_t(S_IFDIR):
                try requireDirectory(url)
                result.append((relative, true, 0, ""))
            case mode_t(S_IFREG):
                try requireRegularFile(url)
                result.append((relative, false, info.st_size, try sha256Hex(at: url)))
            default:
                throw GigaAMAssetDownloadError.insecureTopology(url.path)
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    static func sha256Hex(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Publish a private marker without ever opening a destination symlink.
    /// The temporary inode is complete, durable, owned by this user, and mode
    /// 0600 before the same-directory atomic rename makes it visible.
    static func writePrivateFileAtomically(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try requireDirectory(parent)
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else {
            throw GigaAMAssetDownloadError.insecureTopology(parent.path)
        }
        defer { _ = close(parentFD) }

        let destinationName = destination.lastPathComponent
        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let temporaryFD = openat(
            parentFD,
            temporaryName,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            0o600
        )
        guard temporaryFD >= 0 else {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
        var temporaryIsOpen = true
        var temporaryExists = true
        defer {
            if temporaryIsOpen { _ = close(temporaryFD) }
            if temporaryExists { _ = unlinkat(parentFD, temporaryName, 0) }
        }

        var temporaryInfo = stat()
        guard fstat(temporaryFD, &temporaryInfo) == 0,
              fileType(temporaryInfo.st_mode) == mode_t(S_IFREG),
              temporaryInfo.st_uid == geteuid(),
              fchmod(temporaryFD, 0o600) == 0 else {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw GigaAMAssetDownloadError.insecureTopology(destination.path)
                }
                let count = Darwin.write(
                    temporaryFD,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fsync(temporaryFD) == 0 else {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
        guard close(temporaryFD) == 0 else {
            temporaryIsOpen = false
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
        temporaryIsOpen = false

        var existingInfo = stat()
        if fstatat(parentFD, destinationName, &existingInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard fileType(existingInfo.st_mode) == mode_t(S_IFREG),
                  existingInfo.st_uid == geteuid() else {
                throw GigaAMAssetDownloadError.insecureTopology(destination.path)
            }
        } else if errno != ENOENT {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }

        guard renameat(parentFD, temporaryName, parentFD, destinationName) == 0,
              fsync(parentFD) == 0 else {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
        temporaryExists = false
        let publishedInfo = try lstatInfo(destination)
        guard fileType(publishedInfo.st_mode) == mode_t(S_IFREG),
              publishedInfo.st_uid == geteuid(),
              publishedInfo.st_mode & 0o777 == 0o600 else {
            throw GigaAMAssetDownloadError.insecureTopology(destination.path)
        }
    }

    private static func lstatInfo(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw CocoaError(.fileNoSuchFile) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info
    }

    private static func realPath(_ url: URL) throws -> String {
        guard let resolved = realpath(url.path, nil) else {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & mode_t(S_IFMT)
    }
}

final class GigaAMInterprocessLock: @unchecked Sendable {
    private let descriptor: Int32

    init(modelRoot: URL) throws {
        try GigaAMSecureStorage.requireDirectory(modelRoot)
        let lockURL = modelRoot.appendingPathComponent(".model.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw GigaAMAssetDownloadError.lockUnavailable(lockURL.path)
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw GigaAMAssetDownloadError.lockUnavailable(lockURL.path)
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                close(fd)
                throw GigaAMAssetDownloadError.lockUnavailable(lockURL.path)
            }
            do {
                try Task.checkCancellation()
            } catch {
                close(fd)
                throw error
            }
            usleep(50_000)
        }
        descriptor = fd
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

struct GigaAMCompiledCacheMarker: Codable, Equatable {
    let schemaVersion: Int
    let sourceManifestSHA256: String
    let compiledTreeSHA256: String
}

/// Identifies one model's source manifest and expected compiled artifacts.
/// The v3 policy is the default everywhere to keep existing call sites and
/// fixtures unchanged.
struct GigaAMCompiledCachePolicy: Sendable {
    let expectedPackageNames: Set<String>
    let sourceManifestSHA256: String

    static func manifestSHA256(revision: String, assets: [GigaAMAssetDescriptor]) -> String {
        var lines = ["revision|\(revision)"]
        lines.append(contentsOf: assets.map {
            "\($0.relativePath)|\($0.expectedByteCount)|\($0.expectedSHA256.lowercased())"
        })
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static let v3 = GigaAMCompiledCachePolicy(
        expectedPackageNames: [
            "GigaAMv3Encoder.mlmodelc",
            "GigaAMv3DecoderStep.mlmodelc",
            "GigaAMv3JointStep.mlmodelc",
        ],
        sourceManifestSHA256: manifestSHA256(
            revision: GigaAMAssetCatalog.revision,
            assets: GigaAMAssetCatalog.assets
        )
    )

    static let multilingualCTC = GigaAMCompiledCachePolicy(
        expectedPackageNames: ["GigaAMMultilingualCTC.mlmodelc"],
        sourceManifestSHA256: manifestSHA256(
            revision: GigaAMMultilingualAssetCatalog.revision,
            assets: GigaAMMultilingualAssetCatalog.assets
        )
    )
}

enum GigaAMCompiledCache {
    static let markerName = ".validated-cache-manifest.json"
    static var expectedPackageNames: Set<String> {
        GigaAMCompiledCachePolicy.v3.expectedPackageNames
    }

    static var sourceManifestSHA256: String {
        GigaAMCompiledCachePolicy.v3.sourceManifestSHA256
    }

    static func isReady(compiledRoot: URL, policy: GigaAMCompiledCachePolicy = .v3) -> Bool {
        (try? requireReady(compiledRoot: compiledRoot, policy: policy)) != nil
    }

    static func seal(compiledRoot: URL, policy: GigaAMCompiledCachePolicy = .v3) throws {
        try GigaAMSecureStorage.hardenTree(at: compiledRoot)
        let markerURL = compiledRoot.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try GigaAMSecureStorage.requireRegularFile(markerURL, strictPermissions: false)
            try FileManager.default.removeItem(at: markerURL)
        }
        let marker = GigaAMCompiledCacheMarker(
            schemaVersion: 1,
            sourceManifestSHA256: policy.sourceManifestSHA256,
            compiledTreeSHA256: try compiledTreeSHA256(compiledRoot: compiledRoot)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try GigaAMSecureStorage.writePrivateFileAtomically(
            encoder.encode(marker),
            to: markerURL
        )
        try requireReady(compiledRoot: compiledRoot, policy: policy)
    }

    private static func requireReady(
        compiledRoot: URL,
        policy: GigaAMCompiledCachePolicy
    ) throws {
        try GigaAMSecureStorage.requireDirectory(compiledRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: compiledRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard Set(children.map(\.lastPathComponent)) == policy.expectedPackageNames.union([markerName]) else {
            throw GigaAMAssetDownloadError.insecureTopology(compiledRoot.path)
        }
        for packageName in policy.expectedPackageNames {
            try GigaAMSecureStorage.requireDirectory(compiledRoot.appendingPathComponent(packageName))
        }
        let markerURL = compiledRoot.appendingPathComponent(markerName)
        try GigaAMSecureStorage.requireRegularFile(markerURL)
        let marker = try JSONDecoder().decode(
            GigaAMCompiledCacheMarker.self,
            from: Data(contentsOf: markerURL)
        )
        guard marker.schemaVersion == 1,
              marker.sourceManifestSHA256 == policy.sourceManifestSHA256,
              marker.compiledTreeSHA256 == (try compiledTreeSHA256(compiledRoot: compiledRoot)) else {
            throw GigaAMAssetDownloadError.insecureTopology(markerURL.path)
        }
    }

    private static func compiledTreeSHA256(compiledRoot: URL) throws -> String {
        let entries = try GigaAMSecureStorage.secureTreeEntries(
            at: compiledRoot,
            excluding: [markerName]
        )
        let manifest = entries.map { relative, isDirectory, size, hash in
            "\(isDirectory ? "d" : "f")|\(relative)|\(size)|\(hash)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(manifest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

protocol GigaAMAssetTransport: Sendable {
    /// Stream `url` to the on-disk staging destination. The destination is never
    /// a live model path; validation and the final atomic rename happen later.
    func download(from url: URL, to stagingURL: URL) async throws
}

protocol GigaAMAssetFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func createPrivateDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func setPrivateFilePermissions(at url: URL) throws
    func validatePrivateRegularFile(at url: URL) throws
    func validatePrivateDirectoryChain(from root: URL, through descendant: URL) throws
    func fileSize(at url: URL) throws -> Int64
    func sha256Hex(at url: URL) throws -> String
    func availableCapacity(at url: URL) throws -> Int64
}

struct FoundationGigaAMAssetFileSystem: @unchecked Sendable, GigaAMAssetFileSystem {
    private let fileManager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createPrivateDirectory(at url: URL) throws {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw GigaAMAssetDownloadError.insecureTopology(url.path)
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try GigaAMSecureStorage.requireDirectory(url, strictPermissions: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func setPrivateFilePermissions(at url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func validatePrivateRegularFile(at url: URL) throws {
        try GigaAMSecureStorage.requireRegularFile(url)
    }

    func validatePrivateDirectoryChain(from root: URL, through descendant: URL) throws {
        try GigaAMSecureStorage.requireDirectoryChain(from: root, through: descendant)
    }

    func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.int64Value
    }

    /// Incremental hashing keeps verification memory flat even for the 422 MB
    /// encoder weights file.
    func sha256Hex(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        if let capacity = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return max(0, capacity)
        }
        let attributes = try fileManager.attributesOfFileSystem(forPath: url.path)
        if let number = attributes[.systemFreeSize] as? NSNumber {
            return max(0, number.int64Value)
        }
        throw GigaAMAssetDownloadError.diskCapacityUnavailable
    }
}

struct URLSessionGigaAMAssetTransport: GigaAMAssetTransport {
    func download(from url: URL, to stagingURL: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
    }
}

struct GigaAMAssetInstallResult: Sendable, Equatable {
    let downloadedAssetCount: Int
    let replacedAssetCount: Int
    let validatedAssetCount: Int

    var didMutateSource: Bool {
        downloadedAssetCount > 0 || replacedAssetCount > 0
    }
}

struct GigaAMAssetDownloader: Sendable {
    static let defaultFreeSpaceHeadroom: Int64 = 512 * 1_024 * 1_024

    private enum ExistingState: Equatable {
        case missing
        case valid
        case invalid
    }

    let assets: [GigaAMAssetDescriptor]
    let revision: String
    let transport: any GigaAMAssetTransport
    let fileSystem: any GigaAMAssetFileSystem
    let freeSpaceHeadroom: Int64
    let makeQuarantineID: @Sendable () -> String
    let resolveURL: @Sendable (GigaAMAssetDescriptor) -> URL

    init(
        assets: [GigaAMAssetDescriptor] = GigaAMAssetCatalog.assets,
        revision: String = GigaAMAssetCatalog.revision,
        transport: any GigaAMAssetTransport = URLSessionGigaAMAssetTransport(),
        fileSystem: any GigaAMAssetFileSystem = FoundationGigaAMAssetFileSystem(),
        freeSpaceHeadroom: Int64 = GigaAMAssetDownloader.defaultFreeSpaceHeadroom,
        makeQuarantineID: @Sendable @escaping () -> String = { UUID().uuidString },
        resolveURL: @Sendable @escaping (GigaAMAssetDescriptor) -> URL = {
            GigaAMAssetCatalog.resolveURL(for: $0)
        }
    ) {
        self.assets = assets
        self.revision = revision
        self.transport = transport
        self.fileSystem = fileSystem
        self.freeSpaceHeadroom = max(0, freeSpaceHeadroom)
        self.makeQuarantineID = makeQuarantineID
        self.resolveURL = resolveURL
    }

    /// Verify every installed byte, fetch only missing/corrupt assets, and make
    /// each validated file live with one same-directory rename.
    func ensureAssets(
        in sourceRoot: URL,
        additionalRequiredBytes: Int64,
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> GigaAMAssetInstallResult {
        try Task.checkCancellation()
        try fileSystem.createPrivateDirectory(at: sourceRoot)
        try fileSystem.validatePrivateDirectoryChain(from: sourceRoot, through: sourceRoot)

        var states: [String: ExistingState] = [:]
        var assetsNeedingDownload: [GigaAMAssetDescriptor] = []
        var validatedAssetCount = 0

        for asset in assets {
            try validateRelativePath(asset.relativePath)
            let destination = sourceRoot.appendingPathComponent(asset.relativePath)
            let staging = stagingURL(for: destination)
            if fileSystem.fileExists(at: staging) {
                try fileSystem.validatePrivateRegularFile(at: staging)
                try quarantine(
                    staging,
                    relativePath: asset.relativePath + ".partial",
                    under: sourceRoot
                )
            }

            let state = try existingState(of: asset, at: destination)
            states[asset.relativePath] = state
            switch state {
            case .valid:
                try fileSystem.setPrivateFilePermissions(at: destination)
                validatedAssetCount += 1
            case .missing, .invalid:
                assetsNeedingDownload.append(asset)
            }
        }

        let downloadBytes = saturatedSum(assetsNeedingDownload.map(\.expectedByteCount))
        if downloadBytes > 0 || additionalRequiredBytes > 0 {
            let requiredBytes = saturatedSum([
                downloadBytes,
                max(0, additionalRequiredBytes),
                freeSpaceHeadroom,
            ])
            let availableBytes = try fileSystem.availableCapacity(at: sourceRoot)
            guard availableBytes >= requiredBytes else {
                throw GigaAMAssetDownloadError.insufficientDiskSpace(
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            }
        }

        var downloadedAssetCount = 0
        var replacedAssetCount = 0
        let totalDownloads = assetsNeedingDownload.count

        for asset in assetsNeedingDownload {
            try Task.checkCancellation()
            let destination = sourceRoot.appendingPathComponent(asset.relativePath)
            let staging = stagingURL(for: destination)
            let destinationDirectory = destination.deletingLastPathComponent()
            try fileSystem.createPrivateDirectory(at: destinationDirectory)
            try fileSystem.validatePrivateDirectoryChain(
                from: sourceRoot,
                through: destinationDirectory
            )

            if states[asset.relativePath] == .invalid,
               fileSystem.fileExists(at: destination) {
                try quarantine(destination, relativePath: asset.relativePath + ".corrupt", under: sourceRoot)
                replacedAssetCount += 1
            }

            do {
                try await transport.download(from: resolveURL(asset), to: staging)
                try Task.checkCancellation()
                guard fileSystem.fileExists(at: staging) else {
                    throw GigaAMAssetDownloadError.assetUnavailable(
                        relativePath: asset.relativePath,
                        revision: revision
                    )
                }
                try fileSystem.setPrivateFilePermissions(at: staging)
                try verify(asset, at: staging)
                try Task.checkCancellation()

                if fileSystem.fileExists(at: destination) {
                    try fileSystem.validatePrivateRegularFile(at: destination)
                    try quarantine(destination, relativePath: asset.relativePath + ".race", under: sourceRoot)
                }
                try fileSystem.moveItem(at: staging, to: destination)
                try fileSystem.setPrivateFilePermissions(at: destination)
                downloadedAssetCount += 1
                validatedAssetCount += 1
                onProgress(downloadedAssetCount, totalDownloads)
            } catch is CancellationError {
                try? quarantinePartial(staging, asset: asset, under: sourceRoot)
                throw CancellationError()
            } catch let error as GigaAMAssetDownloadError {
                try? quarantinePartial(staging, asset: asset, under: sourceRoot)
                throw error
            } catch {
                try? quarantinePartial(staging, asset: asset, under: sourceRoot)
                if Task.isCancelled { throw CancellationError() }
                throw GigaAMAssetDownloadError.assetUnavailable(
                    relativePath: asset.relativePath,
                    revision: revision
                )
            }
        }

        return GigaAMAssetInstallResult(
            downloadedAssetCount: downloadedAssetCount,
            replacedAssetCount: replacedAssetCount,
            validatedAssetCount: validatedAssetCount
        )
    }

    private func existingState(
        of asset: GigaAMAssetDescriptor,
        at destination: URL
    ) throws -> ExistingState {
        guard fileSystem.fileExists(at: destination) else { return .missing }
        do {
            try verify(asset, at: destination)
            return .valid
        } catch let error as GigaAMAssetDownloadError {
            switch error {
            case .sizeMismatch, .checksumMismatch:
                return .invalid
            default:
                throw error
            }
        }
    }

    private func verify(_ asset: GigaAMAssetDescriptor, at url: URL) throws {
        try fileSystem.validatePrivateRegularFile(at: url)
        let actualSize = try fileSystem.fileSize(at: url)
        guard actualSize == asset.expectedByteCount else {
            throw GigaAMAssetDownloadError.sizeMismatch(
                relativePath: asset.relativePath,
                expected: asset.expectedByteCount,
                actual: actualSize
            )
        }
        let actualHash = try fileSystem.sha256Hex(at: url).lowercased()
        guard actualHash == asset.expectedSHA256.lowercased() else {
            throw GigaAMAssetDownloadError.checksumMismatch(
                relativePath: asset.relativePath,
                expected: asset.expectedSHA256.lowercased(),
                actual: actualHash
            )
        }
    }

    private func validateRelativePath(_ relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw GigaAMAssetDownloadError.invalidRelativePath(relativePath)
        }
    }

    private func stagingURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".partial")
    }

    private func quarantinePartial(
        _ staging: URL,
        asset: GigaAMAssetDescriptor,
        under sourceRoot: URL
    ) throws {
        guard fileSystem.fileExists(at: staging) else { return }
        try quarantine(
            staging,
            relativePath: asset.relativePath + ".partial",
            under: sourceRoot
        )
    }

    private func quarantine(
        _ source: URL,
        relativePath: String,
        under sourceRoot: URL
    ) throws {
        let quarantineRoot = sourceRoot
            .appendingPathComponent(".quarantine", isDirectory: true)
            .appendingPathComponent(makeQuarantineID(), isDirectory: true)
        let destination = quarantineRoot.appendingPathComponent(relativePath)
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileSystem.createPrivateDirectory(at: destinationDirectory)
        try fileSystem.validatePrivateDirectoryChain(
            from: sourceRoot,
            through: destinationDirectory
        )
        try fileSystem.moveItem(at: source, to: destination)
        try fileSystem.setPrivateFilePermissions(at: destination)
    }

    private func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(max(0, value))
            return overflow ? Int64.max : sum
        }
    }
}
