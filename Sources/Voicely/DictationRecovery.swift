import Darwin
import Foundation

enum DictationRecoveryState: String, Codable, Sendable {
    case recording
    case pending
    case committed
}

struct RecoveredDictationExport: Sendable, Equatable {
    let id: UUID
    let directoryURL: URL
    let audioURL: URL
    let manifestURL: URL
    let reason: String
}

struct DictationRecoveryExportReport: Sendable, Equatable {
    let exported: [RecoveredDictationExport]
    let retainedFailureCount: Int
}

enum DictationRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case unsafeRoot(String)
    case invalidManifest(String)
    case unsafeEntry(String)
    case invalidAudio(String)
    case alreadyClaimed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeRoot(detail):
            return "Unsafe dictation recovery root: \(detail)"
        case let .invalidManifest(detail):
            return "Invalid dictation recovery manifest: \(detail)"
        case let .unsafeEntry(detail):
            return "Unsafe dictation recovery entry: \(detail)"
        case let .invalidAudio(detail):
            return "Invalid dictation recovery audio: \(detail)"
        case .alreadyClaimed:
            return "The dictation recovery is already claimed."
        case let .operationFailed(detail):
            return "Dictation recovery operation failed: \(detail)"
        }
    }
}

fileprivate struct DictationRecoveryManifest: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: String
    let startedAt: Double
    let sourceApp: String?
    var state: DictationRecoveryState
    var reason: String
    let sampleRate: Double
    var sampleCount: Int
    var droppedSampleCount: Int
    var zeroFilledSampleCount: Int
    var writerFailure: String?
    var transcriptFileName: String?
}

/// A private, typed staging store for dictation audio. All recovery reads and
/// mutations are rooted at validated directory descriptors. JSON never chooses
/// a path, and a launch worker must atomically claim a UUID-bound directory
/// before it can publish or remove audio.
final class DictationRecoveryStore: @unchecked Sendable {
    static let audioFileName = "audio.wav"
    static let manifestFileName = "manifest.json"
    static let visibleDirectoryName = "recovered-dictations"

    private static let maximumManifestBytes = 64 * 1_024
    private static let wavHeaderByteCount = 44
    private static let maximumTextBytes = 4 * 1_024
    private static let validDirectoryStates = Set([
        "recording", "pending", "recovering", "committed",
    ])

    static var defaultRootURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Voicely", isDirectory: true)
            .appendingPathComponent("PendingDictations", isDirectory: true)
    }

    let rootURL: URL

    private let claimLock = NSLock()
    private var activeIDs: Set<UUID> = []

    init(rootURL: URL = DictationRecoveryStore.defaultRootURL) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              !rootURL.pathComponents.contains("."),
              !rootURL.pathComponents.contains("..") else {
            throw DictationRecoveryError.unsafeRoot(
                "root must be an absolute file URL without relative components"
            )
        }
        // Keep canonical spellings such as /private/var. standardizedFileURL
        // rewrites them through /var, which is itself a symlink on macOS.
        self.rootURL = rootURL.absoluteURL
        try Self.validatePathComponentsHaveNoSymlink(
            self.rootURL,
            allowMissingSuffix: true
        )
        try FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true
        )
        try Self.validatePathComponentsHaveNoSymlink(
            self.rootURL,
            allowMissingSuffix: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: self.rootURL.path
        )
        let rootFD = try Self.openDirectory(self.rootURL.path, description: "root")
        defer { Darwin.close(rootFD) }
        try Self.validateDescriptor(
            rootFD,
            kind: .directory,
            requireSingleLink: false,
            description: "root"
        )
    }

    func begin(
        startTime: Date,
        sourceApp: String?,
        sampleRate: Double
    ) throws -> DictationRecoverySession {
        guard startTime.timeIntervalSince1970.isFinite,
              startTime.timeIntervalSince1970 > 0,
              CallCaptureWAVWriter.isSupportedSampleRate(sampleRate),
              Self.isBoundedText(sourceApp) else {
            throw DictationRecoveryError.invalidManifest(
                "invalid start time, source application, or sample rate"
            )
        }

        let id = UUID()
        let name = directoryName(id: id, state: "recording")
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        guard mkdirat(rootFD, name, 0o700) == 0 else {
            throw operationError("create \(name)")
        }

        do {
            let directoryFD = try openDirectory(at: rootFD, name: name)
            var directoryLeaseTransferred = false
            defer {
                if !directoryLeaseTransferred {
                    _ = flock(directoryFD, LOCK_UN)
                    Darwin.close(directoryFD)
                }
            }
            guard fchmod(directoryFD, 0o700) == 0 else {
                throw operationError("secure \(name)")
            }
            guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else {
                throw operationError("lock live dictation recovery")
            }
            let audioFD = openat(
                directoryFD,
                Self.audioFileName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard audioFD >= 0 else {
                throw operationError("create private dictation audio")
            }
            let manifest = DictationRecoveryManifest(
                schemaVersion: DictationRecoveryManifest.schemaVersion,
                id: canonical(id),
                startedAt: startTime.timeIntervalSince1970,
                sourceApp: sourceApp,
                state: .recording,
                reason: "recording_interrupted",
                sampleRate: sampleRate,
                sampleCount: 0,
                droppedSampleCount: 0,
                zeroFilledSampleCount: 0,
                writerFailure: nil,
                transcriptFileName: nil
            )
            let session = try DictationRecoverySession(
                id: id,
                store: self,
                directoryName: name,
                manifest: manifest,
                ownedAudioFileDescriptor: audioFD,
                ownedDirectoryFileDescriptor: directoryFD
            )
            directoryLeaseTransferred = true
            guard fsync(directoryFD) == 0, fsync(rootFD) == 0 else {
                throw operationError("sync new dictation recovery")
            }
            return session
        } catch {
            try? removeUnclaimedDirectory(rootFD: rootFD, name: name)
            throw error
        }
    }

    /// Claims every valid private artifact and publishes it into a visible,
    /// owner-only directory under Documents/Voicely. The `.partial` -> UUID
    /// rename is the publication point. A crash after publication is idempotent:
    /// the next launch validates the existing UUID artifact and removes only the
    /// matching private claim.
    func exportPendingArtifacts(
        to visibleBaseURL: URL
    ) -> DictationRecoveryExportReport {
        let exportRootURL: URL
        let exportRootFD: Int32
        do {
            (exportRootURL, exportRootFD) = try prepareExportRoot(
                visibleBaseURL: visibleBaseURL
            )
        } catch {
            return DictationRecoveryExportReport(
                exported: [],
                retainedFailureCount: recoverableDirectoryNames().count
            )
        }
        defer { Darwin.close(exportRootFD) }

        var exports: [RecoveredDictationExport] = []
        var retainedFailures = 0
        for name in recoverableDirectoryNames() {
            let claim: DictationRecoveryClaim
            do {
                claim = try claimDirectory(named: name)
            } catch DictationRecoveryError.alreadyClaimed {
                // A live writer owns the directory lease. It is current work,
                // not a corrupt recovery, and must remain untouched.
                continue
            } catch {
                retainedFailures += 1
                continue
            }

            do {
                if claim.manifest.state == .committed || claim.sampleCount == 0 {
                    try cleanupClaim(claim)
                    continue
                }
                let exported = try publish(
                    claim: claim,
                    exportRootURL: exportRootURL,
                    exportRootFD: exportRootFD
                )
                exports.append(exported)
                do {
                    try cleanupClaim(claim)
                } catch {
                    // The user-visible transaction is already durable. Leave the
                    // private `.recovering` source for idempotent cleanup later.
                    retainedFailures += 1
                }
            } catch {
                retainedFailures += 1
            }
        }
        return DictationRecoveryExportReport(
            exported: exports.sorted { $0.id.uuidString < $1.id.uuidString },
            retainedFailureCount: retainedFailures
        )
    }

    // MARK: - Writer session operations

    fileprivate func audioURL(directoryName: String) -> URL {
        rootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(Self.audioFileName, isDirectory: false)
    }

    fileprivate func writeInitialManifest(
        _ manifest: DictationRecoveryManifest,
        directoryName: String
    ) throws {
        let parsed = try requireDirectoryName(directoryName, expectedID: nil)
        guard parsed.id.uuidString.lowercased() == manifest.id,
              parsed.state == "recording" else {
            throw DictationRecoveryError.invalidManifest("writer identity mismatch")
        }
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        let directoryFD = try openDirectory(at: rootFD, name: directoryName)
        defer { Darwin.close(directoryFD) }
        try validateManifest(manifest, expectedID: parsed.id)
        try writeManifest(manifest, directoryFD: directoryFD)
        guard fsync(directoryFD) == 0 else {
            throw operationError("sync initial manifest")
        }
    }

    fileprivate func persist(
        _ manifest: DictationRecoveryManifest,
        directoryName: String,
        publishState: String
    ) throws -> String {
        guard Self.validDirectoryStates.contains(publishState) else {
            throw DictationRecoveryError.unsafeEntry("invalid publication state")
        }
        let parsed = try requireDirectoryName(
            directoryName,
            expectedID: UUID(uuidString: manifest.id)
        )
        try validateManifest(manifest, expectedID: parsed.id)
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        let directoryFD = try openDirectory(at: rootFD, name: directoryName)
        defer { Darwin.close(directoryFD) }
        let audioFD = try openAudio(directoryFD: directoryFD, writable: false)
        defer { Darwin.close(audioFD) }
        _ = try validateWAV(fd: audioFD, manifest: manifest, repairHeader: false)
        try writeManifest(manifest, directoryFD: directoryFD)
        guard fsync(directoryFD) == 0 else {
            throw operationError("sync dictation recovery")
        }

        guard parsed.state != publishState else { return directoryName }
        let destination = self.directoryName(id: parsed.id, state: publishState)
        try renameDirectoryExclusive(
            rootFD: rootFD,
            from: directoryName,
            to: destination,
            operation: "publish \(publishState) dictation"
        )
        guard fsync(rootFD) == 0 else {
            throw operationError("sync dictation recovery root")
        }
        return destination
    }

    fileprivate func cleanupResolved(
        directoryName: String,
        id: UUID,
        requireEmptyAudio: Bool
    ) throws {
        let claim = try claimDirectory(named: directoryName, expectedID: id)
        if requireEmptyAudio, claim.sampleCount != 0 {
            throw DictationRecoveryError.invalidAudio(
                "refusing to discard non-empty dictation audio"
            )
        }
        try cleanupClaim(claim)
    }

    // MARK: - Claim and validation

    private func recoverableDirectoryNames() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: rootURL.path
        ) else { return [] }
        return names
            .filter { parseDirectoryName($0) != nil }
            .sorted { lhs, rhs in
                let lhsRecovering = lhs.hasSuffix(".recovering")
                let rhsRecovering = rhs.hasSuffix(".recovering")
                if lhsRecovering != rhsRecovering { return lhsRecovering }
                return lhs < rhs
            }
    }

    private func claimDirectory(
        named sourceName: String,
        expectedID: UUID? = nil
    ) throws -> DictationRecoveryClaim {
        try claimLock.withLock {
            let parsed = try requireDirectoryName(sourceName, expectedID: expectedID)
            guard !activeIDs.contains(parsed.id) else {
                throw DictationRecoveryError.alreadyClaimed
            }

            let rootFD = try openRoot()
            defer { Darwin.close(rootFD) }
            let directoryFD = try openDirectory(at: rootFD, name: sourceName)
            guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else {
                let lockError = errno
                Darwin.close(directoryFD)
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    throw DictationRecoveryError.alreadyClaimed
                }
                errno = lockError
                throw operationError("lock recovery claim")
            }
            do {
                let preclaimValidation = try validateRecoveryDirectory(
                    directoryFD: directoryFD,
                    id: parsed.id,
                    directoryState: parsed.state,
                    repairHeader: false
                )
                Darwin.close(preclaimValidation.audioFD)
                let recoveringName = directoryName(
                    id: parsed.id,
                    state: "recovering"
                )
                if sourceName != recoveringName {
                    try renameDirectoryExclusive(
                        rootFD: rootFD,
                        from: sourceName,
                        to: recoveringName,
                        operation: "claim \(sourceName)"
                    )
                    guard fsync(rootFD) == 0 else {
                        throw operationError("sync dictation claim")
                    }
                }
                let validated = try validateRecoveryDirectory(
                    directoryFD: directoryFD,
                    id: parsed.id,
                    directoryState: "recovering",
                    repairHeader: true
                )
                activeIDs.insert(parsed.id)
                return DictationRecoveryClaim(
                    id: parsed.id,
                    directoryName: recoveringName,
                    directoryFD: directoryFD,
                    audioFD: validated.audioFD,
                    manifest: validated.manifest,
                    sampleCount: validated.sampleCount,
                    fileIdentity: validated.fileIdentity,
                    store: self
                )
            } catch {
                _ = flock(directoryFD, LOCK_UN)
                Darwin.close(directoryFD)
                throw error
            }
        }
    }

    private struct ValidatedRecovery {
        var manifest: DictationRecoveryManifest
        let sampleCount: Int
        let audioFD: Int32
        let fileIdentity: FileIdentity
    }

    fileprivate struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let byteCount: off_t
    }

    private func validateRecoveryDirectory(
        directoryFD: Int32,
        id: UUID,
        directoryState: String,
        repairHeader: Bool
    ) throws -> ValidatedRecovery {
        try Self.validateDescriptor(
            directoryFD,
            kind: .directory,
            requireSingleLink: false,
            description: "dictation recovery directory"
        )
        var manifest = try readManifest(directoryFD: directoryFD)
        try validateManifest(manifest, expectedID: id)
        switch directoryState {
        case "recording":
            guard manifest.state == .recording || manifest.state == .pending else {
                throw DictationRecoveryError.invalidManifest(
                    "recording directory state mismatch"
                )
            }
        case "pending":
            guard manifest.state == .pending else {
                throw DictationRecoveryError.invalidManifest(
                    "pending directory state mismatch"
                )
            }
        case "committed":
            guard manifest.state == .committed else {
                throw DictationRecoveryError.invalidManifest(
                    "committed directory state mismatch"
                )
            }
        case "recovering":
            break
        default:
            throw DictationRecoveryError.unsafeEntry("unknown directory state")
        }

        let audioFD = try openAudio(
            directoryFD: directoryFD,
            writable: repairHeader
        )
        do {
            let header = try validateWAV(
                fd: audioFD,
                manifest: manifest,
                repairHeader: repairHeader
            )
            manifest.sampleCount = header.sampleCount
            if manifest.state == .recording {
                manifest.state = .pending
                if manifest.reason.isEmpty {
                    manifest.reason = "recording_interrupted"
                }
            }
            return ValidatedRecovery(
                manifest: manifest,
                sampleCount: header.sampleCount,
                audioFD: audioFD,
                fileIdentity: header.fileIdentity
            )
        } catch {
            Darwin.close(audioFD)
            throw error
        }
    }

    private struct ValidatedWAV {
        let sampleCount: Int
        let fileIdentity: FileIdentity
    }

    private func validateWAV(
        fd: Int32,
        manifest: DictationRecoveryManifest,
        repairHeader: Bool
    ) throws -> ValidatedWAV {
        try Self.validateDescriptor(
            fd,
            kind: .regularFile,
            requireSingleLink: true,
            description: Self.audioFileName
        )
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw operationError("stat \(Self.audioFileName)")
        }
        let maximumDataBytes = UInt64(UInt32.max) - 36
        guard info.st_size >= off_t(Self.wavHeaderByteCount),
              UInt64(info.st_size - off_t(Self.wavHeaderByteCount)) <= maximumDataBytes,
              (info.st_size - off_t(Self.wavHeaderByteCount)).isMultiple(of: 2) else {
            throw DictationRecoveryError.invalidAudio("invalid bounded WAV size")
        }

        var header = [UInt8](repeating: 0, count: Self.wavHeaderByteCount)
        let count = pread(fd, &header, header.count, 0)
        guard count == header.count,
              ascii(header, 0, 4) == "RIFF",
              ascii(header, 8, 4) == "WAVE",
              ascii(header, 12, 4) == "fmt ",
              littleUInt32(header, 16) == 16,
              littleUInt16(header, 20) == 1,
              littleUInt16(header, 22) == 1,
              ascii(header, 36, 4) == "data",
              littleUInt16(header, 32) == 2,
              littleUInt16(header, 34) == 16 else {
            throw DictationRecoveryError.invalidAudio(
                "audio.wav is not fixed-header PCM16 mono WAV"
            )
        }
        let sampleRate = littleUInt32(header, 24)
        let byteRate = littleUInt32(header, 28)
        guard sampleRate >= 8_000,
              sampleRate <= 384_000,
              byteRate == sampleRate * 2,
              abs(Double(sampleRate) - manifest.sampleRate) < 0.5 else {
            throw DictationRecoveryError.invalidAudio("inconsistent PCM parameters")
        }

        let actualDataBytes = UInt32(
            info.st_size - off_t(Self.wavHeaderByteCount)
        )
        let declaredRIFFBytes = littleUInt32(header, 4)
        let declaredDataBytes = littleUInt32(header, 40)
        let riffPayload = declaredRIFFBytes >= 36 ? declaredRIFFBytes - 36 : 0
        guard declaredDataBytes <= actualDataBytes,
              declaredDataBytes.isMultiple(of: 2),
              declaredRIFFBytes >= 36,
              riffPayload <= actualDataBytes,
              riffPayload.isMultiple(of: 2) else {
            throw DictationRecoveryError.invalidAudio("inconsistent RIFF lengths")
        }
        let sampleCount = Int(actualDataBytes / 2)
        if manifest.state == .recording {
            guard manifest.sampleCount <= sampleCount else {
                throw DictationRecoveryError.invalidManifest(
                    "recording sample count exceeds WAV"
                )
            }
        } else {
            guard manifest.sampleCount == sampleCount else {
                throw DictationRecoveryError.invalidManifest(
                    "sample count does not match WAV"
                )
            }
        }

        if repairHeader {
            let riff = littleEndianData(actualDataBytes + 36)
            let data = littleEndianData(actualDataBytes)
            guard riff.withUnsafeBytes({ pwrite(fd, $0.baseAddress, riff.count, 4) })
                    == riff.count,
                  data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, data.count, 40) })
                    == data.count,
                  fsync(fd) == 0 else {
                throw operationError("repair dictation WAV header")
            }
        }
        return ValidatedWAV(
            sampleCount: sampleCount,
            fileIdentity: FileIdentity(
                device: info.st_dev,
                inode: info.st_ino,
                byteCount: info.st_size
            )
        )
    }

    private func validateManifest(
        _ manifest: DictationRecoveryManifest,
        expectedID: UUID
    ) throws {
        guard manifest.schemaVersion == DictationRecoveryManifest.schemaVersion,
              manifest.id == canonical(expectedID),
              manifest.startedAt.isFinite,
              manifest.startedAt > 0,
              CallCaptureWAVWriter.isSupportedSampleRate(manifest.sampleRate),
              manifest.sampleCount >= 0,
              manifest.droppedSampleCount >= 0,
              manifest.zeroFilledSampleCount >= 0,
              manifest.zeroFilledSampleCount <= manifest.sampleCount,
              Self.isBoundedText(manifest.sourceApp),
              Self.isBoundedText(manifest.writerFailure),
              !manifest.reason.isEmpty,
              manifest.reason.utf8.count <= Self.maximumTextBytes,
              Self.isSafeFileName(manifest.transcriptFileName) else {
            throw DictationRecoveryError.invalidManifest(
                "identity, schema, count, or text bounds mismatch"
            )
        }
    }

    private func readManifest(directoryFD: Int32) throws -> DictationRecoveryManifest {
        let fd = openat(
            directoryFD,
            Self.manifestFileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw DictationRecoveryError.invalidManifest("missing manifest.json")
        }
        defer { Darwin.close(fd) }
        try Self.validateDescriptor(
            fd,
            kind: .regularFile,
            requireSingleLink: true,
            description: Self.manifestFileName
        )
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_size > 0,
              info.st_size <= off_t(Self.maximumManifestBytes) else {
            throw DictationRecoveryError.invalidManifest(
                "manifest exceeds the size limit"
            )
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, $0.count, 0)
        }
        guard count == data.count else {
            throw DictationRecoveryError.invalidManifest(
                "manifest could not be read atomically"
            )
        }
        try validateManifestShape(data)
        do {
            let manifest = try JSONDecoder().decode(
                DictationRecoveryManifest.self,
                from: data
            )
            guard let id = UUID(uuidString: manifest.id),
                  canonical(id) == manifest.id else {
                throw DictationRecoveryError.invalidManifest(
                    "id must be a canonical UUID"
                )
            }
            return manifest
        } catch let error as DictationRecoveryError {
            throw error
        } catch {
            throw DictationRecoveryError.invalidManifest(
                error.localizedDescription
            )
        }
    }

    private func validateManifestShape(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw DictationRecoveryError.invalidManifest(
                "top level must be an object"
            )
        }
        let required = Set([
            "schemaVersion", "id", "startedAt", "state", "reason",
            "sampleRate", "sampleCount", "droppedSampleCount",
            "zeroFilledSampleCount",
        ])
        let allowed = required.union([
            "sourceApp", "writerFailure", "transcriptFileName",
        ])
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: allowed) else {
            throw DictationRecoveryError.invalidManifest(
                "unexpected or missing manifest fields"
            )
        }
    }

    private func writeManifest(
        _ manifest: DictationRecoveryManifest,
        directoryFD: Int32
    ) throws {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumManifestBytes else {
            throw DictationRecoveryError.invalidManifest(
                "manifest exceeds the size limit"
            )
        }
        try writeAtomicFile(
            data,
            finalName: Self.manifestFileName,
            directoryFD: directoryFD
        )
    }

    // MARK: - User-visible publication

    private func prepareExportRoot(
        visibleBaseURL: URL
    ) throws -> (URL, Int32) {
        guard visibleBaseURL.isFileURL,
              visibleBaseURL.path.hasPrefix("/"),
              !visibleBaseURL.pathComponents.contains("."),
              !visibleBaseURL.pathComponents.contains("..") else {
            throw DictationRecoveryError.unsafeRoot(
                "visible root must be an absolute file URL"
            )
        }
        let exportRoot = visibleBaseURL.absoluteURL.appendingPathComponent(
            Self.visibleDirectoryName,
            isDirectory: true
        )
        try Self.validatePathComponentsHaveNoSymlink(
            exportRoot,
            allowMissingSuffix: true
        )
        try FileManager.default.createDirectory(
            at: exportRoot,
            withIntermediateDirectories: true
        )
        try Self.validatePathComponentsHaveNoSymlink(
            exportRoot,
            allowMissingSuffix: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: exportRoot.path
        )
        let fd = try Self.openDirectory(exportRoot.path, description: "export root")
        do {
            try Self.validateDescriptor(
                fd,
                kind: .directory,
                requireSingleLink: false,
                description: "export root"
            )
            return (exportRoot, fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func publish(
        claim: DictationRecoveryClaim,
        exportRootURL: URL,
        exportRootFD: Int32
    ) throws -> RecoveredDictationExport {
        let finalName = canonical(claim.id)
        if let existing = try validatedPublishedExport(
            matching: claim,
            name: finalName,
            exportRootURL: exportRootURL,
            exportRootFD: exportRootFD
        ) {
            return existing
        }

        let stagingName = ".\(finalName).partial"
        try removeStaleExportStaging(
            name: stagingName,
            exportRootFD: exportRootFD
        )
        guard mkdirat(exportRootFD, stagingName, 0o700) == 0 else {
            throw operationError("create export staging")
        }

        let stagingFD = try openDirectory(at: exportRootFD, name: stagingName)
        var published = false
        defer {
            Darwin.close(stagingFD)
            if !published {
                try? removeStaleExportStaging(
                    name: stagingName,
                    exportRootFD: exportRootFD
                )
            }
        }
        let destinationAudioFD = openat(
            stagingFD,
            Self.audioFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationAudioFD >= 0 else {
            throw operationError("create exported audio")
        }
        do {
            try copyFile(
                sourceFD: claim.audioFD,
                expectedIdentity: claim.fileIdentity,
                destinationFD: destinationAudioFD
            )
            guard fchmod(destinationAudioFD, 0o600) == 0,
                  fsync(destinationAudioFD) == 0 else {
                throw operationError("sync exported audio")
            }
            Darwin.close(destinationAudioFD)
        } catch {
            Darwin.close(destinationAudioFD)
            throw error
        }

        let exportedManifest = normalizedExportManifest(for: claim)
        let manifestData = try JSONEncoder().encode(exportedManifest)
        try writeExclusiveFile(
            manifestData,
            name: Self.manifestFileName,
            directoryFD: stagingFD
        )
        guard fsync(stagingFD) == 0 else {
            throw operationError("sync export staging")
        }

        do {
            try renameDirectoryExclusive(
                rootFD: exportRootFD,
                from: stagingName,
                to: finalName,
                operation: "publish recovered dictation"
            )
            guard fsync(exportRootFD) == 0 else {
                throw operationError("sync recovered dictation root")
            }
            published = true
        } catch where errno == EEXIST || errno == ENOTEMPTY {
            if let existing = try validatedPublishedExport(
                matching: claim,
                name: finalName,
                exportRootURL: exportRootURL,
                exportRootFD: exportRootFD
            ) {
                return existing
            }
            throw error
        }

        guard let result = try validatedPublishedExport(
            matching: claim,
            name: finalName,
            exportRootURL: exportRootURL,
            exportRootFD: exportRootFD
        ) else {
            throw DictationRecoveryError.operationFailed(
                "published export could not be validated"
            )
        }
        return result
    }

    private func validatedPublishedExport(
        matching claim: DictationRecoveryClaim,
        name: String,
        exportRootURL: URL,
        exportRootFD: Int32
    ) throws -> RecoveredDictationExport? {
        let directoryFD = openat(
            exportRootFD,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0, errno == ENOENT { return nil }
        guard directoryFD >= 0 else {
            throw operationError("open existing recovered dictation")
        }
        defer { Darwin.close(directoryFD) }
        try Self.validateDescriptor(
            directoryFD,
            kind: .directory,
            requireSingleLink: false,
            description: "published recovered dictation"
        )
        let manifest = try readManifest(directoryFD: directoryFD)
        try validateManifest(manifest, expectedID: claim.id)
        guard manifest == normalizedExportManifest(for: claim) else {
            throw DictationRecoveryError.invalidManifest(
                "published artifact does not match the private recovery claim"
            )
        }
        let audioFD = try openAudio(directoryFD: directoryFD, writable: false)
        defer { Darwin.close(audioFD) }
        let destinationWAV = try validateWAV(
            fd: audioFD,
            manifest: manifest,
            repairHeader: false
        )
        guard try filesAreIdentical(
            sourceFD: claim.audioFD,
            expectedSourceIdentity: claim.fileIdentity,
            destinationFD: audioFD,
            expectedDestinationIdentity: destinationWAV.fileIdentity
        ) else {
            throw DictationRecoveryError.invalidAudio(
                "published audio does not match the private recovery claim"
            )
        }

        let directoryURL = exportRootURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        return RecoveredDictationExport(
            id: claim.id,
            directoryURL: directoryURL,
            audioURL: directoryURL.appendingPathComponent(Self.audioFileName),
            manifestURL: directoryURL.appendingPathComponent(Self.manifestFileName),
            reason: manifest.reason
        )
    }

    private func normalizedExportManifest(
        for claim: DictationRecoveryClaim
    ) -> DictationRecoveryManifest {
        var manifest = claim.manifest
        manifest.state = .pending
        manifest.sampleCount = claim.sampleCount
        manifest.transcriptFileName = nil
        return manifest
    }

    // MARK: - Cleanup and descriptor helpers

    private func cleanupClaim(_ claim: DictationRecoveryClaim) throws {
        guard claim.store === self else {
            throw DictationRecoveryError.unsafeEntry("foreign recovery claim")
        }
        let allowed = Set([Self.audioFileName, Self.manifestFileName])
        let entries = try directoryEntryNames(fd: claim.directoryFD)
        guard Set(entries).isSubset(of: allowed) else {
            throw DictationRecoveryError.unsafeEntry(
                "recovery directory contains unexpected entries"
            )
        }
        for name in entries {
            if unlinkat(claim.directoryFD, name, 0) != 0, errno != ENOENT {
                throw operationError("remove private \(name)")
            }
        }
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        try requireDirectoryEntry(
            parentFD: rootFD,
            name: claim.directoryName,
            matches: claim.directoryFD
        )
        guard unlinkat(
            rootFD,
            claim.directoryName,
            AT_REMOVEDIR
        ) == 0 else {
            throw operationError("remove private dictation directory")
        }
        guard fsync(rootFD) == 0 else {
            throw operationError("sync private dictation cleanup")
        }
    }

    private func removeUnclaimedDirectory(rootFD: Int32, name: String) throws {
        let directoryFD = try openDirectory(at: rootFD, name: name)
        defer { Darwin.close(directoryFD) }
        let allowed = Set([Self.audioFileName, Self.manifestFileName])
        guard Set(try directoryEntryNames(fd: directoryFD)).isSubset(of: allowed) else {
            throw DictationRecoveryError.unsafeEntry(
                "failed-start directory contains unexpected entries"
            )
        }
        for entry in [Self.audioFileName, Self.manifestFileName] {
            if unlinkat(directoryFD, entry, 0) != 0, errno != ENOENT {
                throw operationError("remove failed-start \(entry)")
            }
        }
        try requireDirectoryEntry(
            parentFD: rootFD,
            name: name,
            matches: directoryFD
        )
        guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0 else {
            throw operationError("remove failed-start directory")
        }
    }

    private func removeStaleExportStaging(
        name: String,
        exportRootFD: Int32
    ) throws {
        let directoryFD = openat(
            exportRootFD,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directoryFD < 0, errno == ENOENT { return }
        guard directoryFD >= 0 else {
            throw operationError("open stale export staging")
        }
        defer { Darwin.close(directoryFD) }
        try Self.validateDescriptor(
            directoryFD,
            kind: .directory,
            requireSingleLink: false,
            description: "export staging"
        )
        let allowed = Set([Self.audioFileName, Self.manifestFileName])
        guard Set(try directoryEntryNames(fd: directoryFD)).isSubset(of: allowed) else {
            throw DictationRecoveryError.unsafeEntry(
                "export staging contains unexpected entries"
            )
        }
        for entry in [Self.audioFileName, Self.manifestFileName] {
            if unlinkat(directoryFD, entry, 0) != 0, errno != ENOENT {
                throw operationError("remove stale export \(entry)")
            }
        }
        try requireDirectoryEntry(
            parentFD: exportRootFD,
            name: name,
            matches: directoryFD
        )
        guard unlinkat(exportRootFD, name, AT_REMOVEDIR) == 0 else {
            throw operationError("remove stale export staging")
        }
    }

    private func writeAtomicFile(
        _ data: Data,
        finalName: String,
        directoryFD: Int32
    ) throws {
        let temporaryName = ".\(finalName).\(canonical(UUID())).partial"
        let fd = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { throw operationError("create temporary manifest") }
        var succeeded = false
        defer {
            Darwin.close(fd)
            if !succeeded { _ = unlinkat(directoryFD, temporaryName, 0) }
        }
        try writeAll(data, fd: fd)
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            throw operationError("sync manifest")
        }
        guard renameat(directoryFD, temporaryName, directoryFD, finalName) == 0,
              fsync(directoryFD) == 0 else {
            throw operationError("publish manifest")
        }
        succeeded = true
    }

    private func writeExclusiveFile(
        _ data: Data,
        name: String,
        directoryFD: Int32
    ) throws {
        guard data.count <= Self.maximumManifestBytes else {
            throw DictationRecoveryError.invalidManifest(
                "export manifest exceeds the size limit"
            )
        }
        let fd = openat(
            directoryFD,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else { throw operationError("create \(name)") }
        defer { Darwin.close(fd) }
        try writeAll(data, fd: fd)
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            throw operationError("sync \(name)")
        }
    }

    private func copyFile(
        sourceFD: Int32,
        expectedIdentity: FileIdentity,
        destinationFD: Int32
    ) throws {
        var before = stat()
        guard fstat(sourceFD, &before) == 0,
              FileIdentity(
                device: before.st_dev,
                inode: before.st_ino,
                byteCount: before.st_size
              ) == expectedIdentity else {
            throw DictationRecoveryError.invalidAudio(
                "private audio changed after validation"
            )
        }
        var offset: off_t = 0
        var remaining = expectedIdentity.byteCount
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            let requested = min(buffer.count, Int(remaining))
            let count = pread(sourceFD, &buffer, requested, offset)
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw DictationRecoveryError.invalidAudio(
                    "private audio ended before the validated boundary"
                )
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationFD,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw operationError("write recovered dictation audio")
                }
                written += result
            }
            offset += off_t(count)
            remaining -= off_t(count)
        }
        var after = stat()
        var destination = stat()
        guard fstat(sourceFD, &after) == 0,
              fstat(destinationFD, &destination) == 0,
              FileIdentity(
                device: after.st_dev,
                inode: after.st_ino,
                byteCount: after.st_size
              ) == expectedIdentity,
              destination.st_size == expectedIdentity.byteCount else {
            throw DictationRecoveryError.invalidAudio(
                "audio size or inode drifted during recovery copy"
            )
        }
    }

    private func filesAreIdentical(
        sourceFD: Int32,
        expectedSourceIdentity: FileIdentity,
        destinationFD: Int32,
        expectedDestinationIdentity: FileIdentity
    ) throws -> Bool {
        let sourceBefore = try fileIdentity(
            fd: sourceFD,
            description: "private dictation audio"
        )
        let destinationBefore = try fileIdentity(
            fd: destinationFD,
            description: "published dictation audio"
        )
        guard sourceBefore == expectedSourceIdentity else {
            throw DictationRecoveryError.invalidAudio(
                "private audio changed after validation"
            )
        }
        guard destinationBefore == expectedDestinationIdentity,
              destinationBefore.byteCount == sourceBefore.byteCount else {
            return false
        }

        var sourceBuffer = [UInt8](repeating: 0, count: 1_048_576)
        var destinationBuffer = [UInt8](repeating: 0, count: 1_048_576)
        var offset: off_t = 0
        while offset < sourceBefore.byteCount {
            let count = min(
                sourceBuffer.count,
                Int(sourceBefore.byteCount - offset)
            )
            try readExactly(
                fd: sourceFD,
                into: &sourceBuffer,
                count: count,
                offset: offset
            )
            try readExactly(
                fd: destinationFD,
                into: &destinationBuffer,
                count: count,
                offset: offset
            )
            guard sourceBuffer[..<count].elementsEqual(
                destinationBuffer[..<count]
            ) else { return false }
            offset += off_t(count)
        }

        let sourceAfter = try fileIdentity(
            fd: sourceFD,
            description: "private dictation audio"
        )
        let destinationAfter = try fileIdentity(
            fd: destinationFD,
            description: "published dictation audio"
        )
        guard sourceAfter == expectedSourceIdentity else {
            throw DictationRecoveryError.invalidAudio(
                "private audio drifted during idempotency validation"
            )
        }
        return destinationAfter == expectedDestinationIdentity
    }

    private func readExactly(
        fd: Int32,
        into buffer: inout [UInt8],
        count: Int,
        offset: off_t
    ) throws {
        var completed = 0
        while completed < count {
            let result = buffer.withUnsafeMutableBytes { bytes in
                pread(
                    fd,
                    bytes.baseAddress!.advanced(by: completed),
                    count - completed,
                    offset + off_t(completed)
                )
            }
            guard result > 0 else {
                if result < 0, errno == EINTR { continue }
                throw DictationRecoveryError.invalidAudio(
                    "audio ended before the validated comparison boundary"
                )
            }
            completed += result
        }
    }

    private func fileIdentity(
        fd: Int32,
        description: String
    ) throws -> FileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw operationError("stat \(description)")
        }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            byteCount: info.st_size
        )
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw operationError("write file")
            }
            offset += count
        }
    }

    private func directoryEntryNames(fd: Int32) throws -> [String] {
        let scanFD = dup(fd)
        guard scanFD >= 0 else {
            throw operationError("duplicate directory descriptor")
        }
        guard let stream = fdopendir(scanFD) else {
            Darwin.close(scanFD)
            throw operationError("open directory stream")
        }
        defer { closedir(stream) }

        var names: [String] = []
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) { tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func requireDirectoryEntry(
        parentFD: Int32,
        name: String,
        matches directoryFD: Int32
    ) throws {
        var expected = stat()
        var actual = stat()
        guard fstat(directoryFD, &expected) == 0,
              fstatat(
                parentFD,
                name,
                &actual,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino else {
            throw DictationRecoveryError.unsafeEntry(
                "directory identity changed before cleanup"
            )
        }
    }

    private enum DescriptorKind { case directory, regularFile }

    private static func validateDescriptor(
        _ fd: Int32,
        kind: DescriptorKind,
        requireSingleLink: Bool,
        description: String
    ) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw DictationRecoveryError.unsafeEntry(
                "could not stat \(description)"
            )
        }
        let expected: mode_t = kind == .directory
            ? mode_t(S_IFDIR)
            : mode_t(S_IFREG)
        guard info.st_mode & mode_t(S_IFMT) == expected,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              !requireSingleLink || info.st_nlink == 1 else {
            throw DictationRecoveryError.unsafeEntry(
                "\(description) must be owner-only, owner-matched, and non-linked"
            )
        }
    }

    private static func validatePathComponentsHaveNoSymlink(
        _ url: URL,
        allowMissingSuffix: Bool
    ) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            let result = lstat(current.path, &info)
            if result != 0, allowMissingSuffix, errno == ENOENT { return }
            guard result == 0 else {
                throw DictationRecoveryError.unsafeRoot(
                    "cannot inspect \(current.path)"
                )
            }
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw DictationRecoveryError.unsafeRoot(
                    "symlink component \(current.path)"
                )
            }
        }
    }

    private func openRoot() throws -> Int32 {
        let fd = try Self.openDirectory(rootURL.path, description: "root")
        do {
            try Self.validateDescriptor(
                fd,
                kind: .directory,
                requireSingleLink: false,
                description: "root"
            )
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func openDirectory(
        _ path: String,
        description: String
    ) throws -> Int32 {
        let fd = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw DictationRecoveryError.unsafeRoot(
                "cannot open \(description): \(String(cString: strerror(errno)))"
            )
        }
        return fd
    }

    private func openDirectory(at parentFD: Int32, name: String) throws -> Int32 {
        guard isSinglePathComponent(name) else {
            throw DictationRecoveryError.unsafeEntry(
                "invalid directory component"
            )
        }
        let fd = openat(
            parentFD,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw operationError("open \(name)") }
        do {
            try Self.validateDescriptor(
                fd,
                kind: .directory,
                requireSingleLink: false,
                description: name
            )
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func openAudio(
        directoryFD: Int32,
        writable: Bool
    ) throws -> Int32 {
        let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
        let fd = openat(directoryFD, Self.audioFileName, flags)
        guard fd >= 0 else {
            throw DictationRecoveryError.unsafeEntry(
                "cannot open audio.wav: \(String(cString: strerror(errno)))"
            )
        }
        return fd
    }

    private func parseDirectoryName(_ name: String) -> (id: UUID, state: String)? {
        guard isSinglePathComponent(name),
              let separator = name.lastIndex(of: ".") else { return nil }
        let idText = String(name[..<separator])
        let state = String(name[name.index(after: separator)...])
        guard Self.validDirectoryStates.contains(state),
              let id = UUID(uuidString: idText),
              canonical(id) == idText else { return nil }
        return (id, state)
    }

    private func requireDirectoryName(
        _ name: String,
        expectedID: UUID?
    ) throws -> (id: UUID, state: String) {
        guard let parsed = parseDirectoryName(name),
              expectedID == nil || expectedID == parsed.id else {
            throw DictationRecoveryError.unsafeEntry(
                "invalid or mismatched recovery directory name"
            )
        }
        return parsed
    }

    private func directoryName(id: UUID, state: String) -> String {
        "\(canonical(id)).\(state)"
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains(":")
            && !value.contains("%") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isBoundedText(_ value: String?) -> Bool {
        (value?.utf8.count ?? 0) <= maximumTextBytes
    }

    private static func isSafeFileName(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= 255
            && value != "." && value != ".."
            && !value.contains("/") && !value.contains(":")
            && !value.contains("%") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func operationError(_ operation: String) -> DictationRecoveryError {
        .operationFailed(
            "\(operation): \(String(cString: strerror(errno)))"
        )
    }

    private func renameDirectoryExclusive(
        rootFD: Int32,
        from source: String,
        to destination: String,
        operation: String
    ) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameatx_np(
                    rootFD,
                    sourcePointer,
                    rootFD,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw operationError(operation) }
    }

    private func ascii(
        _ bytes: [UInt8],
        _ offset: Int,
        _ count: Int
    ) -> String {
        String(
            bytes: bytes[offset..<(offset + count)],
            encoding: .ascii
        ) ?? ""
    }

    private func littleUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func littleUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
    }

    fileprivate func releaseClaim(_ id: UUID) {
        claimLock.withLock { _ = activeIDs.remove(id) }
    }
}

private final class DictationRecoveryClaim: @unchecked Sendable {
    let id: UUID
    let directoryName: String
    let directoryFD: Int32
    let audioFD: Int32
    let manifest: DictationRecoveryManifest
    let sampleCount: Int
    let fileIdentity: DictationRecoveryStore.FileIdentity
    let store: DictationRecoveryStore

    init(
        id: UUID,
        directoryName: String,
        directoryFD: Int32,
        audioFD: Int32,
        manifest: DictationRecoveryManifest,
        sampleCount: Int,
        fileIdentity: DictationRecoveryStore.FileIdentity,
        store: DictationRecoveryStore
    ) {
        self.id = id
        self.directoryName = directoryName
        self.directoryFD = directoryFD
        self.audioFD = audioFD
        self.manifest = manifest
        self.sampleCount = sampleCount
        self.fileIdentity = fileIdentity
        self.store = store
    }

    deinit {
        Darwin.close(audioFD)
        _ = flock(directoryFD, LOCK_UN)
        Darwin.close(directoryFD)
        store.releaseClaim(id)
    }
}

/// Owns one recording writer and its state transitions. A successful preserve
/// or commit resolves the session exactly once; failed durable writes remain
/// retryable by the termination timeout path.
final class DictationRecoverySession: @unchecked Sendable {
    let id: UUID

    private let store: DictationRecoveryStore
    private let lock = NSLock()
    private let writer: CallCaptureWAVWriter
    private var directoryName: String
    private var manifest: DictationRecoveryManifest
    private var snapshot: CallCaptureWAVWriter.Snapshot?
    private var directoryLeaseFD: Int32?
    private var resolved = false

    fileprivate init(
        id: UUID,
        store: DictationRecoveryStore,
        directoryName: String,
        manifest: DictationRecoveryManifest,
        ownedAudioFileDescriptor: Int32,
        ownedDirectoryFileDescriptor: Int32
    ) throws {
        self.id = id
        self.store = store
        self.directoryName = directoryName
        self.manifest = manifest
        self.directoryLeaseFD = ownedDirectoryFileDescriptor
        self.writer = try CallCaptureWAVWriter(
            url: store.audioURL(directoryName: directoryName),
            sampleRate: manifest.sampleRate,
            ownedFileDescriptor: ownedAudioFileDescriptor,
            pendingBufferCount: 64
        )
        try store.writeInitialManifest(
            manifest,
            directoryName: directoryName
        )
    }

    deinit {
        _ = writer.finish()
        releaseDirectoryLease()
    }

    func append(_ samples: [Float]) {
        _ = writer.enqueue(samples)
    }

    @discardableResult
    func finishCapture(reason: String) -> CallCaptureWAVWriter.Snapshot {
        lock.withLock {
            let result = finishWriter()
            apply(result)
            manifest.state = .pending
            manifest.reason = boundedReason(reason)
            if let published = try? store.persist(
                manifest,
                directoryName: directoryName,
                publishState: "pending"
            ) {
                directoryName = published
            }
            return result
        }
    }

    @discardableResult
    func preserve(reason: String) -> Bool {
        lock.withLock {
            guard !resolved else { return false }
            let result = finishWriter()
            apply(result)
            manifest.state = .pending
            manifest.reason = boundedReason(reason)
            do {
                directoryName = try store.persist(
                    manifest,
                    directoryName: directoryName,
                    publishState: "pending"
                )
                resolved = true
                releaseDirectoryLease()
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func complete(transcriptURL: URL?) -> Bool {
        lock.withLock {
            guard !resolved else { return false }
            let result = finishWriter()
            apply(result)
            manifest.state = .committed
            manifest.reason = "transcript_committed"
            manifest.transcriptFileName = transcriptURL?.lastPathComponent
            do {
                directoryName = try store.persist(
                    manifest,
                    directoryName: directoryName,
                    publishState: "committed"
                )
                resolved = true
                releaseDirectoryLease()
                do {
                    try store.cleanupResolved(
                        directoryName: directoryName,
                        id: id,
                        requireEmptyAudio: false
                    )
                } catch {
                    NSLog(
                        "[Voicely] Dictation recovery cleanup failed: %@",
                        error.localizedDescription
                    )
                }
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    func discardEmptyStart() -> Bool {
        lock.withLock {
            guard !resolved else { return false }
            let result = finishWriter()
            apply(result)
            guard result.sampleCount == 0 else {
                manifest.state = .pending
                manifest.reason = "start_failed_after_audio"
                if let published = try? store.persist(
                    manifest,
                    directoryName: directoryName,
                    publishState: "pending"
                ) {
                    directoryName = published
                    resolved = true
                    releaseDirectoryLease()
                }
                return false
            }

            manifest.state = .committed
            manifest.reason = "empty_start_discarded"
            do {
                directoryName = try store.persist(
                    manifest,
                    directoryName: directoryName,
                    publishState: "committed"
                )
                resolved = true
                releaseDirectoryLease()
                do {
                    try store.cleanupResolved(
                        directoryName: directoryName,
                        id: id,
                        requireEmptyAudio: true
                    )
                } catch {
                    NSLog(
                        "[Voicely] Empty dictation recovery cleanup failed: %@",
                        error.localizedDescription
                    )
                }
                return true
            } catch {
                return false
            }
        }
    }

    private func finishWriter() -> CallCaptureWAVWriter.Snapshot {
        if let snapshot { return snapshot }
        let result = writer.finish()
        snapshot = result
        return result
    }

    private func releaseDirectoryLease() {
        guard let directoryLeaseFD else { return }
        self.directoryLeaseFD = nil
        _ = flock(directoryLeaseFD, LOCK_UN)
        Darwin.close(directoryLeaseFD)
    }

    private func apply(_ snapshot: CallCaptureWAVWriter.Snapshot) {
        manifest.sampleCount = snapshot.sampleCount
        manifest.droppedSampleCount = snapshot.droppedSampleCount
        manifest.zeroFilledSampleCount = snapshot.zeroFilledSampleCount
        manifest.writerFailure = (snapshot.failure ?? snapshot.timelineIssue).map {
            String($0.prefix(1_024))
        }
    }

    private func boundedReason(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 4 * 1_024 else {
            return "dictation_recovery_reason_invalid"
        }
        return value
    }
}

/// Resolves commit vs recovery exactly once across graceful completion and the
/// AppKit termination timeout callback.
final class DictationTerminationGate: @unchecked Sendable {
    enum Resolution: Sendable, Equatable {
        case pending
        case committed
        case recovered(String)
    }

    private let lock = NSLock()
    private var resolution: Resolution = .pending

    func reset() {
        lock.withLock { resolution = .pending }
    }

    var current: Resolution { lock.withLock { resolution } }

    func commit(_ action: () -> Bool) -> Bool {
        resolve(.committed, action: action)
    }

    func recover(reason: String, _ action: () -> Bool) -> Bool {
        resolve(.recovered(reason), action: action)
    }

    private func resolve(_ target: Resolution, action: () -> Bool) -> Bool {
        lock.withLock {
            guard resolution == .pending else { return false }
            guard action() else { return false }
            resolution = target
            return true
        }
    }
}
