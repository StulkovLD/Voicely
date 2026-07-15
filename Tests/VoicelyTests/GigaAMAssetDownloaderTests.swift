import CryptoKit
import Foundation
import XCTest
@testable import VoicelyCore

private final class MockGigaAMFileSystem: @unchecked Sendable, GigaAMAssetFileSystem {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var permissions: [String: Int] = [:]
    var capacity: Int64

    init(capacity: Int64 = 10_000_000) {
        self.capacity = capacity
    }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { files[url.path] != nil || directories.contains(url.path) }
    }

    func createPrivateDirectory(at url: URL) throws {
        lock.withLock {
            directories.insert(url.path)
            permissions[url.path] = 0o700
        }
    }

    func removeItem(at url: URL) throws {
        lock.withLock {
            files.removeValue(forKey: url.path)
            directories.remove(url.path)
            permissions.removeValue(forKey: url.path)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try lock.withLock {
            guard let data = files.removeValue(forKey: sourceURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            files[destinationURL.path] = data
            permissions[destinationURL.path] = permissions.removeValue(forKey: sourceURL.path)
        }
    }

    func setPrivateFilePermissions(at url: URL) throws {
        lock.withLock { permissions[url.path] = 0o600 }
    }

    func validatePrivateRegularFile(at url: URL) throws {
        try lock.withLock {
            guard files[url.path] != nil else { throw CocoaError(.fileNoSuchFile) }
        }
    }

    func validatePrivateDirectoryChain(from root: URL, through descendant: URL) throws {
        guard descendant.path == root.path || descendant.path.hasPrefix(root.path + "/") else {
            throw GigaAMAssetDownloadError.insecureTopology(descendant.path)
        }
    }

    func fileSize(at url: URL) throws -> Int64 {
        try lock.withLock {
            guard let data = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
            return Int64(data.count)
        }
    }

    func sha256Hex(at url: URL) throws -> String {
        try lock.withLock {
            guard let data = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        capacity
    }

    func put(_ data: Data, at url: URL, permissions mode: Int? = nil) {
        lock.withLock {
            files[url.path] = data
            if let mode { permissions[url.path] = mode }
        }
    }

    func data(at url: URL) -> Data? {
        lock.withLock { files[url.path] }
    }

    func mode(at url: URL) -> Int? {
        lock.withLock { permissions[url.path] }
    }

    func paths() -> [String] {
        lock.withLock { Array(files.keys).sorted() }
    }
}

private final class MockGigaAMTransport: @unchecked Sendable, GigaAMAssetTransport {
    enum Behavior {
        case success(Data)
        case partialThenOffline(Data)
        case waitForCancellation(Data)
    }

    private let lock = NSLock()
    private let fileSystem: MockGigaAMFileSystem
    private let behavior: Behavior
    private var requestedURLs: [URL] = []
    private var started = false

    init(fileSystem: MockGigaAMFileSystem, behavior: Behavior) {
        self.fileSystem = fileSystem
        self.behavior = behavior
    }

    func download(from url: URL, to stagingURL: URL) async throws {
        lock.withLock {
            requestedURLs.append(url)
            started = true
        }
        switch behavior {
        case .success(let data):
            fileSystem.put(data, at: stagingURL)
        case .partialThenOffline(let partial):
            fileSystem.put(partial, at: stagingURL)
            throw URLError(.notConnectedToInternet)
        case .waitForCancellation(let partial):
            fileSystem.put(partial, at: stagingURL)
            try await Task.sleep(for: .seconds(60))
        }
    }

    func callCount() -> Int { lock.withLock { requestedURLs.count } }
    func urls() -> [URL] { lock.withLock { requestedURLs } }
    func hasStarted() -> Bool { lock.withLock { started } }
}

@MainActor
final class GigaAMAssetDownloaderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/models/gigaam/source", isDirectory: true)

    private func descriptor(path: String = "package/model.bin", data: Data) -> GigaAMAssetDescriptor {
        GigaAMAssetDescriptor(
            relativePath: path,
            expectedByteCount: Int64(data.count),
            expectedSHA256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func makeDownloader(
        asset: GigaAMAssetDescriptor,
        fileSystem: MockGigaAMFileSystem,
        transport: MockGigaAMTransport,
        headroom: Int64 = 0,
        quarantineID: String = "q1"
    ) -> GigaAMAssetDownloader {
        GigaAMAssetDownloader(
            assets: [asset],
            revision: "immutable-revision",
            transport: transport,
            fileSystem: fileSystem,
            freeSpaceHeadroom: headroom,
            makeQuarantineID: { quarantineID },
            resolveURL: { asset in
                URL(string: "https://publisher.invalid/resolve/immutable-revision/\(asset.relativePath)")!
            }
        )
    }

    private func waitUntilStarted(_ transport: MockGigaAMTransport) async -> Bool {
        for _ in 0..<100 {
            if transport.hasStarted() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testValidDownloadIsVerifiedThenAtomicallyPromotedWithPrivatePermissions() async throws {
        let expected = Data("verified asset".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let transport = MockGigaAMTransport(fileSystem: fileSystem, behavior: .success(expected))
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        let result = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)

        let destination = root.appendingPathComponent(asset.relativePath)
        XCTAssertEqual(fileSystem.data(at: destination), expected)
        XCTAssertNil(fileSystem.data(at: URL(fileURLWithPath: destination.path + ".partial")))
        XCTAssertEqual(fileSystem.mode(at: root), 0o700)
        XCTAssertEqual(fileSystem.mode(at: destination.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(fileSystem.mode(at: destination), 0o600)
        XCTAssertEqual(result.downloadedAssetCount, 1)
        XCTAssertEqual(result.validatedAssetCount, 1)
        XCTAssertTrue(transport.urls().allSatisfy { $0.absoluteString.contains("immutable-revision") })
    }

    func testCorruptInstalledAssetIsQuarantinedBeforeReplacement() async throws {
        let expected = Data("correct".utf8)
        let corrupt = Data("corrupt".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let destination = root.appendingPathComponent(asset.relativePath)
        fileSystem.put(corrupt, at: destination)
        let transport = MockGigaAMTransport(fileSystem: fileSystem, behavior: .success(expected))
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        let result = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)

        XCTAssertEqual(fileSystem.data(at: destination), expected)
        let quarantined = root
            .appendingPathComponent(".quarantine/q1")
            .appendingPathComponent(asset.relativePath + ".corrupt")
        XCTAssertEqual(fileSystem.data(at: quarantined), corrupt)
        XCTAssertEqual(result.replacedAssetCount, 1)
    }

    func testShortDownloadIsQuarantinedAndNeverRenamed() async throws {
        let expected = Data("complete".utf8)
        let partial = Data("part".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let transport = MockGigaAMTransport(fileSystem: fileSystem, behavior: .success(partial))
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        do {
            _ = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)
            XCTFail("short download must fail verification")
        } catch let error as GigaAMAssetDownloadError {
            XCTAssertEqual(error, .sizeMismatch(
                relativePath: asset.relativePath,
                expected: Int64(expected.count),
                actual: Int64(partial.count)
            ))
        }

        XCTAssertNil(fileSystem.data(at: root.appendingPathComponent(asset.relativePath)))
        XCTAssertTrue(fileSystem.paths().contains { $0.hasSuffix("model.bin.partial") })
    }

    func testOfflineFailureHasDeterministicErrorAndQuarantinesPartial() async throws {
        let expected = Data("complete".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let transport = MockGigaAMTransport(
            fileSystem: fileSystem,
            behavior: .partialThenOffline(Data("part".utf8))
        )
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        do {
            _ = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)
            XCTFail("offline download must fail")
        } catch let error as GigaAMAssetDownloadError {
            XCTAssertEqual(error, .assetUnavailable(
                relativePath: asset.relativePath,
                revision: "immutable-revision"
            ))
        }
        XCTAssertNil(fileSystem.data(at: root.appendingPathComponent(asset.relativePath)))
        XCTAssertTrue(fileSystem.paths().contains { $0.hasSuffix("model.bin.partial") })
    }

    func testCancellationQuarantinesPartialAndPublishesNoAsset() async throws {
        let expected = Data("complete".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let transport = MockGigaAMTransport(
            fileSystem: fileSystem,
            behavior: .waitForCancellation(Data("part".utf8))
        )
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        let task = Task {
            try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)
        }
        let started = await waitUntilStarted(transport)
        guard started else {
            task.cancel()
            _ = await task.result
            XCTFail("timed out waiting for mock download")
            return
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled download must not complete")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertNil(fileSystem.data(at: root.appendingPathComponent(asset.relativePath)))
        XCTAssertTrue(fileSystem.paths().contains { $0.hasSuffix("model.bin.partial") })
    }

    func testDiskFullFailsBeforeTransportOrMutation() async throws {
        let expected = Data("12345678".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem(capacity: 12)
        let transport = MockGigaAMTransport(fileSystem: fileSystem, behavior: .success(expected))
        let downloader = makeDownloader(
            asset: asset,
            fileSystem: fileSystem,
            transport: transport,
            headroom: 2
        )

        do {
            _ = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 3)
            XCTFail("disk preflight must fail")
        } catch let error as GigaAMAssetDownloadError {
            XCTAssertEqual(error, .insufficientDiskSpace(requiredBytes: 13, availableBytes: 12))
        }
        XCTAssertEqual(transport.callCount(), 0)
        XCTAssertNil(fileSystem.data(at: root.appendingPathComponent(asset.relativePath)))
    }

    func testSameSizeChecksumCorruptionIsQuarantined() async throws {
        let expected = Data("good".utf8)
        let corrupt = Data("evil".utf8)
        let asset = descriptor(data: expected)
        let fileSystem = MockGigaAMFileSystem()
        let transport = MockGigaAMTransport(fileSystem: fileSystem, behavior: .success(corrupt))
        let downloader = makeDownloader(asset: asset, fileSystem: fileSystem, transport: transport)

        do {
            _ = try await downloader.ensureAssets(in: root, additionalRequiredBytes: 0)
            XCTFail("checksum mismatch must fail")
        } catch let error as GigaAMAssetDownloadError {
            guard case .checksumMismatch(let path, let expectedHash, let actualHash) = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
            XCTAssertEqual(path, asset.relativePath)
            XCTAssertEqual(expectedHash, asset.expectedSHA256)
            XCTAssertNotEqual(actualHash, expectedHash)
        }
        XCTAssertNil(fileSystem.data(at: root.appendingPathComponent(asset.relativePath)))
        XCTAssertTrue(fileSystem.paths().contains { $0.hasSuffix("model.bin.partial") })
    }

    func testPlatformReadinessRejectsMacOS14AndAcceptsMacOS15() {
        XCTAssertFalse(GigaAMPlatformReadiness.isSupported(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 9, patchVersion: 9)
        ))
        XCTAssertTrue(GigaAMPlatformReadiness.isSupported(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        ))
        XCTAssertEqual(
            GigaAMAssetDownloadError.requiresMacOS15.localizedDescription,
            "GigaAM requires macOS 15 or later."
        )
    }

    func testCompiledCacheSealBindsSourceManifestAndCompiledBytes() throws {
        let compiledRoot = try makeCompiledCacheFixture()
        defer { try? FileManager.default.removeItem(at: compiledRoot.deletingLastPathComponent()) }

        try GigaAMCompiledCache.seal(compiledRoot: compiledRoot)

        XCTAssertTrue(GigaAMCompiledCache.isReady(compiledRoot: compiledRoot))
        let markerData = try Data(contentsOf: compiledRoot.appendingPathComponent(GigaAMCompiledCache.markerName))
        let marker = try JSONDecoder().decode(GigaAMCompiledCacheMarker.self, from: markerData)
        XCTAssertEqual(marker.sourceManifestSHA256, GigaAMCompiledCache.sourceManifestSHA256)
        let markerAttributes = try FileManager.default.attributesOfItem(
            atPath: compiledRoot.appendingPathComponent(GigaAMCompiledCache.markerName).path
        )
        XCTAssertEqual(
            (markerAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        try Data("tampered".utf8).write(
            to: compiledRoot.appendingPathComponent("GigaAMv3Encoder.mlmodelc/model.bin")
        )
        XCTAssertFalse(GigaAMCompiledCache.isReady(compiledRoot: compiledRoot))
    }

    func testCompiledCacheRejectsUnexpectedAndWritableTopology() throws {
        let compiledRoot = try makeCompiledCacheFixture()
        defer { try? FileManager.default.removeItem(at: compiledRoot.deletingLastPathComponent()) }
        try GigaAMCompiledCache.seal(compiledRoot: compiledRoot)

        FileManager.default.createFile(
            atPath: compiledRoot.appendingPathComponent("unexpected.bin").path,
            contents: Data()
        )
        XCTAssertFalse(GigaAMCompiledCache.isReady(compiledRoot: compiledRoot))
        try FileManager.default.removeItem(at: compiledRoot.appendingPathComponent("unexpected.bin"))

        let modelFile = compiledRoot.appendingPathComponent("GigaAMv3Encoder.mlmodelc/model.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: modelFile.path)
        XCTAssertFalse(GigaAMCompiledCache.isReady(compiledRoot: compiledRoot))
    }

    func testCompiledCacheRejectsSymlinkedPackageWithoutFollowingIt() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let compiledRoot = parent.appendingPathComponent("compiled")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: compiledRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for name in GigaAMCompiledCache.expectedPackageNames.dropFirst() {
            try FileManager.default.createDirectory(
                at: compiledRoot.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let symlinkName = GigaAMCompiledCache.expectedPackageNames.first!
        try FileManager.default.createSymbolicLink(
            at: compiledRoot.appendingPathComponent(symlinkName),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try GigaAMCompiledCache.seal(compiledRoot: compiledRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testInterprocessLockRejectsSymlinkedLockFile() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("model")
        let outside = parent.appendingPathComponent("outside-lock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        FileManager.default.createFile(atPath: outside.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".model.lock"),
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertThrowsError(try GigaAMInterprocessLock(modelRoot: root))
    }

    private func makeCompiledCacheFixture() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let compiledRoot = parent.appendingPathComponent("compiled")
        try FileManager.default.createDirectory(at: compiledRoot, withIntermediateDirectories: true)
        for name in GigaAMCompiledCache.expectedPackageNames {
            let package = compiledRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: package.appendingPathComponent("model.bin"))
        }
        return compiledRoot
    }
}
