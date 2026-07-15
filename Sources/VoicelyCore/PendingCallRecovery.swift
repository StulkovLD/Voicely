import Darwin
import Foundation

/// The only channel names accepted by the pending-call format. Audio paths are
/// derived from these cases; they are never read from recovery JSON.
public enum PendingCallChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case mic
    case system

    var fileName: String { "\(rawValue).wav" }
}

public struct PendingCallChannelMetadata: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let sampleCount: Int
    public let droppedSampleCount: Int
    public let zeroFilledSampleCount: Int
    public let timelineOriginOffsetSeconds: Double
    public let maxClockDriftSeconds: Double
    public let discontinuityCount: Int
    public let isDegraded: Bool
    public let failure: String?

    public init(
        sampleRate: Double,
        sampleCount: Int,
        droppedSampleCount: Int,
        zeroFilledSampleCount: Int = 0,
        timelineOriginOffsetSeconds: Double = 0,
        maxClockDriftSeconds: Double = 0,
        discontinuityCount: Int = 0,
        isDegraded: Bool,
        failure: String? = nil
    ) {
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.droppedSampleCount = droppedSampleCount
        self.zeroFilledSampleCount = zeroFilledSampleCount
        self.timelineOriginOffsetSeconds = timelineOriginOffsetSeconds
        self.maxClockDriftSeconds = maxClockDriftSeconds
        self.discontinuityCount = discontinuityCount
        self.isDegraded = isDegraded
        self.failure = failure
    }
}

public enum PendingCallRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case unsafeRoot(String)
    case invalidHandle
    case invalidManifest(String)
    case unsafeEntry(String)
    case invalidAudio(String)
    case alreadyClaimed
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeRoot(detail):
            return "Unsafe pending-call root: \(detail)"
        case .invalidHandle:
            return "The pending-call handle does not belong to this recovery store."
        case let .invalidManifest(detail):
            return "Invalid pending-call manifest: \(detail)"
        case let .unsafeEntry(detail):
            return "Unsafe pending-call entry: \(detail)"
        case let .invalidAudio(detail):
            return "Invalid pending-call audio: \(detail)"
        case .alreadyClaimed:
            return "The pending call is already claimed by another recovery worker."
        case let .operationFailed(detail):
            return "Pending-call operation failed: \(detail)"
        }
    }
}

public enum PendingCallCleanupStatus: Sendable, Equatable {
    case notApplicable
    case retained
    case cleaned
    case failed(String)

    public var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum PendingCallManifestState: String, Codable {
    case recording
    case captured
}

private struct PendingCallManifest: Codable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let callID: String
    let startedAt: Double
    var state: PendingCallManifestState
    let expectedChannels: [PendingCallChannel]
    var mic: PendingCallChannelMetadata?
    var system: PendingCallChannelMetadata?
}

/// A writer-facing capability. It exposes the two fixed WAV locations but no
/// directory or deletion API. Only the store can turn it into a recovery claim.
public final class PendingCallCaptureHandle: @unchecked Sendable {
    public let callID: UUID
    public let startTime: Date
    public let expectedChannels: Set<PendingCallChannel>

    private let lock = NSLock()
    private var currentDirectoryName: String
    let store: PendingCallRecoveryStore

    fileprivate init(
        callID: UUID,
        startTime: Date,
        expectedChannels: Set<PendingCallChannel>,
        directoryName: String,
        store: PendingCallRecoveryStore
    ) {
        self.callID = callID
        self.startTime = startTime
        self.expectedChannels = expectedChannels
        self.currentDirectoryName = directoryName
        self.store = store
    }

    public var micFileURL: URL { fileURL(for: .mic) }
    public var systemFileURL: URL { fileURL(for: .system) }

    private func fileURL(for channel: PendingCallChannel) -> URL {
        store.rootURL
            .appendingPathComponent(directoryName(), isDirectory: true)
            .appendingPathComponent(channel.fileName, isDirectory: false)
    }

    fileprivate func directoryName() -> String {
        lock.withLock { currentDirectoryName }
    }

    fileprivate func updateDirectoryName(_ value: String) {
        lock.withLock { currentDirectoryName = value }
    }
}

/// An exclusive, validated recovery capability. The open descriptors pin the
/// exact directory and channel inodes that passed validation.
public final class PendingCallClaim: @unchecked Sendable {
    public let callID: UUID
    public let startTime: Date
    public let configuredChannels: Set<PendingCallChannel>
    public let capturedChannels: Set<PendingCallChannel>
    public let micMetadata: PendingCallChannelMetadata?
    public let systemMetadata: PendingCallChannelMetadata?

    private let lock = NSLock()
    private var currentDirectoryName: String
    private var isRetired = false
    private var cleanupComplete = false
    fileprivate let directoryFD: Int32
    fileprivate let channelFDs: [PendingCallChannel: Int32]
    let store: PendingCallRecoveryStore

    fileprivate init(
        callID: UUID,
        startTime: Date,
        configuredChannels: Set<PendingCallChannel>,
        capturedChannels: Set<PendingCallChannel>,
        micMetadata: PendingCallChannelMetadata?,
        systemMetadata: PendingCallChannelMetadata?,
        directoryName: String,
        directoryFD: Int32,
        channelFDs: [PendingCallChannel: Int32],
        store: PendingCallRecoveryStore
    ) {
        self.callID = callID
        self.startTime = startTime
        self.configuredChannels = configuredChannels
        self.capturedChannels = capturedChannels
        self.micMetadata = micMetadata
        self.systemMetadata = systemMetadata
        self.currentDirectoryName = directoryName
        self.directoryFD = directoryFD
        self.channelFDs = channelFDs
        self.store = store
    }

    deinit {
        for fd in channelFDs.values { Darwin.close(fd) }
        _ = flock(directoryFD, LOCK_UN)
        Darwin.close(directoryFD)
        store.releaseActiveClaim(callID)
    }

    public var micFileURL: URL? { fileURL(for: .mic) }
    public var systemFileURL: URL? { fileURL(for: .system) }
    public var hasAudio: Bool { !capturedChannels.isEmpty }

    /// Artifact completeness follows channels that passed descriptor and WAV
    /// validation. Configured-but-missing channels belong in capture honesty,
    /// not in a save condition that can never succeed.
    public var expectedChannels: Set<PendingCallChannel> { capturedChannels }

    public func metadata(for channel: PendingCallChannel) -> PendingCallChannelMetadata? {
        switch channel {
        case .mic: micMetadata
        case .system: systemMetadata
        }
    }

    private func fileURL(for channel: PendingCallChannel) -> URL? {
        guard channelFDs[channel] != nil else { return nil }
        return store.rootURL
            .appendingPathComponent(directoryName(), isDirectory: true)
            .appendingPathComponent(channel.fileName, isDirectory: false)
    }

    fileprivate func directoryName() -> String {
        lock.withLock { currentDirectoryName }
    }

    fileprivate func retirementState() -> (directoryName: String, isRetired: Bool, cleanupComplete: Bool) {
        lock.withLock { (currentDirectoryName, isRetired, cleanupComplete) }
    }

    fileprivate func markRetired(directoryName: String) {
        lock.withLock {
            isRetired = true
            currentDirectoryName = directoryName
        }
    }

    fileprivate func markCleanupComplete() {
        lock.withLock { cleanupComplete = true }
    }

    func copyChannel(_ channel: PendingCallChannel, to destinationFD: Int32) throws {
        guard let sourceFD = channelFDs[channel] else {
            throw PendingCallRecoveryError.invalidAudio("missing \(channel.fileName)")
        }
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = pread(sourceFD, &buffer, buffer.count, offset)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw PendingCallRecoveryError.operationFailed(
                    "read \(channel.fileName): \(Self.errnoDescription())"
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
                    throw PendingCallRecoveryError.operationFailed(
                        "write \(channel.fileName): \(Self.errnoDescription())"
                    )
                }
                written += result
            }
            offset += off_t(count)
        }
        guard fsync(destinationFD) == 0 else {
            throw PendingCallRecoveryError.operationFailed(
                "sync \(channel.fileName): \(Self.errnoDescription())"
            )
        }
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}

/// Owns creation, validation, atomic claiming, and retirement of pending calls.
/// Every filesystem mutation is rooted at a validated private directory FD.
public final class PendingCallRecoveryStore: @unchecked Sendable {
    static let markerFileName = "recovery.json"
    static let retiredFileName = "retired.json"
    private static let maximumManifestBytes = 64 * 1_024
    private static let headerByteCount = 44

    public let rootURL: URL
    private let claimLock = NSLock()
    private var activeCallIDs: Set<UUID> = []

    public static var defaultRootURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Voicely", isDirectory: true)
            .appendingPathComponent("PendingCalls", isDirectory: true)
    }

    public init(rootURL: URL = PendingCallRecoveryStore.defaultRootURL) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              !rootURL.pathComponents.contains("."),
              !rootURL.pathComponents.contains("..") else {
            throw PendingCallRecoveryError.unsafeRoot(
                "root must be an absolute file URL without relative components"
            )
        }
        // `standardizedFileURL` rewrites canonical `/private/var/...` back to
        // the `/var` symlink alias on macOS. Preserve the caller's absolute
        // spelling so the component-level no-follow check sees the real path.
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
        let fd = try Self.openDirectory(self.rootURL.path, description: "root")
        defer { Darwin.close(fd) }
        try Self.validateDescriptor(
            fd,
            kind: .directory,
            requireSingleLink: false,
            description: "root"
        )
    }

    public func createCapture(
        startTime: Date,
        expectedChannels: Set<PendingCallChannel> = Set(PendingCallChannel.allCases)
    ) throws -> PendingCallCaptureHandle {
        guard startTime.timeIntervalSince1970.isFinite,
              !expectedChannels.isEmpty else {
            throw PendingCallRecoveryError.invalidManifest("invalid start time or empty channel set")
        }
        let callID = UUID()
        let name = directoryName(callID: callID, state: "recording")
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        guard mkdirat(rootFD, name, 0o700) == 0 else {
            throw operationError("create \(name)")
        }
        do {
            let directoryFD = try openDirectory(at: rootFD, name: name)
            defer { Darwin.close(directoryFD) }
            guard fchmod(directoryFD, 0o700) == 0 else {
                throw operationError("secure \(name)")
            }
            let manifest = PendingCallManifest(
                schemaVersion: PendingCallManifest.schemaVersion,
                callID: canonical(callID),
                startedAt: startTime.timeIntervalSince1970,
                state: .recording,
                expectedChannels: expectedChannels.sorted { $0.rawValue < $1.rawValue },
                mic: nil,
                system: nil
            )
            try writeManifest(manifest, directoryFD: directoryFD)
            guard fsync(rootFD) == 0 else {
                throw operationError("sync new pending-call capture")
            }
        } catch {
            _ = unlinkat(rootFD, name, AT_REMOVEDIR)
            throw error
        }
        return PendingCallCaptureHandle(
            callID: callID,
            startTime: startTime,
            expectedChannels: expectedChannels,
            directoryName: name,
            store: self
        )
    }

    /// Creates one fixed capture channel beneath the descriptor-pinned recording
    /// directory. The returned descriptor is owner-only, non-linked, and owned
    /// by the caller, which must either transfer it to the WAV writer or close it.
    /// Existing files and symlinks are refused instead of opened or replaced.
    public func createChannelFileDescriptor(
        _ handle: PendingCallCaptureHandle,
        channel: PendingCallChannel
    ) throws -> Int32 {
        guard handle.store === self,
              handle.expectedChannels.contains(channel) else {
            throw PendingCallRecoveryError.invalidHandle
        }
        let directoryName = handle.directoryName()
        guard let parsed = parseDirectoryName(directoryName),
              parsed.id == handle.callID,
              parsed.state == "recording" else {
            throw PendingCallRecoveryError.invalidHandle
        }

        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        let directoryFD = try openDirectory(at: rootFD, name: directoryName)
        defer { Darwin.close(directoryFD) }
        let manifest = try readManifest(directoryFD: directoryFD)
        guard manifest.callID == canonical(handle.callID),
              manifest.state == .recording,
              manifest.expectedChannels.contains(channel) else {
            throw PendingCallRecoveryError.invalidHandle
        }

        let fd = openat(
            directoryFD,
            channel.fileName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else {
            if errno == EEXIST || errno == ELOOP {
                throw PendingCallRecoveryError.unsafeEntry(
                    "refusing existing or linked \(channel.fileName)"
                )
            }
            throw operationError("create \(channel.fileName)")
        }

        do {
            try Self.validateDescriptor(
                fd,
                kind: .regularFile,
                requireSingleLink: true,
                description: channel.fileName
            )
            guard fchmod(fd, 0o600) == 0,
                  fsync(directoryFD) == 0 else {
                throw operationError("secure \(channel.fileName)")
            }
            return fd
        } catch {
            Darwin.close(fd)
            _ = unlinkat(directoryFD, channel.fileName, 0)
            throw error
        }
    }

    public func markCaptured(
        _ handle: PendingCallCaptureHandle,
        mic: PendingCallChannelMetadata?,
        system: PendingCallChannelMetadata?
    ) throws {
        guard handle.store === self else {
            throw PendingCallRecoveryError.invalidHandle
        }
        try validateMetadata(mic, channel: .mic)
        try validateMetadata(system, channel: .system)
        let oldName = handle.directoryName()
        let rootFD = try openRoot()
        defer { Darwin.close(rootFD) }
        let directoryFD = try openDirectory(at: rootFD, name: oldName)
        defer { Darwin.close(directoryFD) }
        var manifest = try readManifest(directoryFD: directoryFD)
        guard manifest.callID == canonical(handle.callID) else {
            throw PendingCallRecoveryError.invalidHandle
        }
        manifest.state = .captured
        manifest.mic = mic
        manifest.system = system
        try writeManifest(manifest, directoryFD: directoryFD)
        guard fsync(directoryFD) == 0 else { throw operationError("sync capture directory") }

        let newName = directoryName(callID: handle.callID, state: "captured")
        try renameDirectoryExclusive(
            rootFD: rootFD,
            from: oldName,
            to: newName,
            operation: "publish captured call"
        )
        guard fsync(rootFD) == 0 else { throw operationError("sync pending-call root") }
        handle.updateDirectoryName(newName)
    }

    public func claim(_ handle: PendingCallCaptureHandle) throws -> PendingCallClaim {
        guard handle.store === self else {
            throw PendingCallRecoveryError.invalidHandle
        }
        return try claimDirectory(named: handle.directoryName(), expectedID: handle.callID)
    }

    /// Claims every valid recording/captured call, plus a `.recovering` call
    /// whose prior owner exited and released its descriptor lock.
    public func claimRecoverableCaptures() -> [PendingCallClaim] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
                .filter { parseDirectoryName($0) != nil }
                .sorted()
        } catch {
            return []
        }
        var claims: [PendingCallClaim] = []
        for name in names {
            guard let claim = try? claimDirectory(named: name, expectedID: nil) else {
                continue
            }
            if claim.hasAudio {
                claims.append(claim)
            } else {
                _ = retireAndCleanup(claim)
            }
        }
        return claims
    }

    /// Removes a writer session that never captured a validated audio frame.
    /// The handle is claimed first, so this cannot target an arbitrary URL.
    @discardableResult
    public func discardEmpty(_ handle: PendingCallCaptureHandle) throws -> PendingCallCleanupStatus {
        let claim = try claim(handle)
        guard !claim.hasAudio else {
            throw PendingCallRecoveryError.operationFailed(
                "refusing to discard a capture that contains audio"
            )
        }
        return retireAndCleanup(claim)
    }

    func retireAndCleanup(_ claim: PendingCallClaim) -> PendingCallCleanupStatus {
        guard claim.store === self else {
            return .failed(PendingCallRecoveryError.invalidHandle.localizedDescription)
        }
        do {
            let rootFD = try openRoot()
            defer { Darwin.close(rootFD) }
            let state = claim.retirementState()
            if state.cleanupComplete { return .cleaned }
            let retiredName = directoryName(callID: claim.callID, state: "retired")
            if !state.isRetired {
                try writeRetirementMarker(claim: claim)
                try renameDirectoryExclusive(
                    rootFD: rootFD,
                    from: state.directoryName,
                    to: retiredName,
                    operation: "retire claimed call"
                )
                guard fsync(rootFD) == 0 else { throw operationError("sync retired call") }
                claim.markRetired(directoryName: retiredName)
            }

            let allowed = Set([
                Self.markerFileName,
                Self.retiredFileName,
                PendingCallChannel.mic.fileName,
                PendingCallChannel.system.fileName,
            ])
            let actual = try FileManager.default.contentsOfDirectory(
                atPath: rootURL.appendingPathComponent(retiredName).path
            )
            let unexpected = actual.filter { !allowed.contains($0) }
            guard unexpected.isEmpty else {
                throw PendingCallRecoveryError.unsafeEntry(
                    "retired directory contains unexpected entries: \(unexpected.sorted().joined(separator: ", "))"
                )
            }
            for name in actual {
                if unlinkat(claim.directoryFD, name, 0) != 0, errno != ENOENT {
                    throw operationError("remove retired \(name)")
                }
            }
            guard unlinkat(rootFD, retiredName, AT_REMOVEDIR) == 0 else {
                throw operationError("remove retired directory")
            }
            guard fsync(rootFD) == 0 else { throw operationError("sync cleanup") }
            claim.markCleanupComplete()
            return .cleaned
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    fileprivate func releaseActiveClaim(_ id: UUID) {
        claimLock.withLock { _ = activeCallIDs.remove(id) }
    }

    // MARK: - Claim validation

    private func claimDirectory(
        named sourceName: String,
        expectedID: UUID?
    ) throws -> PendingCallClaim {
        try claimLock.withLock {
            guard let parsed = parseDirectoryName(sourceName),
                  parsed.state == "recording" || parsed.state == "captured" || parsed.state == "recovering" else {
                throw PendingCallRecoveryError.unsafeEntry("invalid recovery directory name")
            }
            if let expectedID, expectedID != parsed.id {
                throw PendingCallRecoveryError.invalidHandle
            }
            guard !activeCallIDs.contains(parsed.id) else {
                throw PendingCallRecoveryError.alreadyClaimed
            }

            let rootFD = try openRoot()
            defer { Darwin.close(rootFD) }
            let preclaimFD = try openDirectory(at: rootFD, name: sourceName)
            do {
                _ = try validateCaptureDirectory(
                    directoryFD: preclaimFD,
                    callID: parsed.id,
                    repairAudioHeaders: false
                )
            } catch {
                Darwin.close(preclaimFD)
                throw error
            }
            Darwin.close(preclaimFD)

            let recoveringName = directoryName(callID: parsed.id, state: "recovering")
            if sourceName != recoveringName {
                do {
                    try renameDirectoryExclusive(
                        rootFD: rootFD,
                        from: sourceName,
                        to: recoveringName,
                        operation: "claim \(sourceName)"
                    )
                } catch where errno == EEXIST || errno == ENOTEMPTY || errno == ENOENT {
                    throw PendingCallRecoveryError.alreadyClaimed
                }
                guard fsync(rootFD) == 0 else { throw operationError("sync recovery claim") }
            }

            let directoryFD = try openDirectory(at: rootFD, name: recoveringName)
            guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(directoryFD)
                throw PendingCallRecoveryError.alreadyClaimed
            }
            do {
                let validated = try validateCaptureDirectory(
                    directoryFD: directoryFD,
                    callID: parsed.id,
                    repairAudioHeaders: true
                )
                guard !activeCallIDs.contains(parsed.id) else {
                    throw PendingCallRecoveryError.alreadyClaimed
                }
                activeCallIDs.insert(parsed.id)
                return PendingCallClaim(
                    callID: parsed.id,
                    startTime: validated.startTime,
                    configuredChannels: validated.configuredChannels,
                    capturedChannels: validated.capturedChannels,
                    micMetadata: validated.metadata[.mic],
                    systemMetadata: validated.metadata[.system],
                    directoryName: recoveringName,
                    directoryFD: directoryFD,
                    channelFDs: validated.channelFDs,
                    store: self
                )
            } catch {
                _ = flock(directoryFD, LOCK_UN)
                Darwin.close(directoryFD)
                throw error
            }
        }
    }

    private struct ValidatedCapture {
        let startTime: Date
        let configuredChannels: Set<PendingCallChannel>
        let capturedChannels: Set<PendingCallChannel>
        let metadata: [PendingCallChannel: PendingCallChannelMetadata]
        let channelFDs: [PendingCallChannel: Int32]
    }

    private func validateCaptureDirectory(
        directoryFD: Int32,
        callID: UUID,
        repairAudioHeaders: Bool
    ) throws -> ValidatedCapture {
        try Self.validateDescriptor(
            directoryFD,
            kind: .directory,
            requireSingleLink: false,
            description: "capture directory"
        )
        let manifest = try readManifest(directoryFD: directoryFD)
        guard manifest.schemaVersion == PendingCallManifest.schemaVersion,
              manifest.callID == canonical(callID),
              manifest.startedAt.isFinite,
              manifest.startedAt > 0 else {
            throw PendingCallRecoveryError.invalidManifest("identity or schema mismatch")
        }
        let expected = Set(manifest.expectedChannels)
        guard !expected.isEmpty,
              expected.count == manifest.expectedChannels.count else {
            throw PendingCallRecoveryError.invalidManifest("empty or duplicate expected_channels")
        }
        try validateMetadata(manifest.mic, channel: .mic)
        try validateMetadata(manifest.system, channel: .system)

        var descriptors: [PendingCallChannel: Int32] = [:]
        var metadata: [PendingCallChannel: PendingCallChannelMetadata] = [:]
        do {
            for channel in PendingCallChannel.allCases {
                let declared = channel == .mic ? manifest.mic : manifest.system
                guard let fd = try openOptionalAudio(
                    directoryFD: directoryFD,
                    channel: channel,
                    writable: repairAudioHeaders
                ) else {
                    continue
                }
                do {
                    let header = try validateWAV(fd: fd, channel: channel)
                    // A writer creates the fixed WAV header before the first
                    // audio callback. Treat that header-only file as empty, not
                    // as a captured artifact; otherwise a failed start cannot
                    // use the typed empty-capture cleanup path.
                    if header.sampleCount == 0 {
                        if let declared, declared.sampleCount != 0 {
                            throw PendingCallRecoveryError.invalidManifest(
                                "\(channel.rawValue) metadata does not match empty WAV"
                            )
                        }
                        Darwin.close(fd)
                        continue
                    }
                    if let declared {
                        guard abs(declared.sampleRate - header.sampleRate) < 0.5,
                              declared.sampleCount >= 0,
                              UInt64(declared.sampleCount) <= header.sampleCount else {
                            throw PendingCallRecoveryError.invalidManifest(
                                "\(channel.rawValue) metadata does not match WAV"
                            )
                        }
                        metadata[channel] = declared
                    } else {
                        metadata[channel] = PendingCallChannelMetadata(
                            sampleRate: header.sampleRate,
                            sampleCount: Int(header.sampleCount),
                            droppedSampleCount: 0,
                            isDegraded: manifest.state == .recording,
                            failure: manifest.state == .recording
                                ? "Capture ended before final channel metadata was committed."
                                : nil
                        )
                    }
                    if repairAudioHeaders {
                        try repairWAVHeader(fd: fd, header: header)
                        descriptors[channel] = fd
                    } else {
                        Darwin.close(fd)
                    }
                } catch {
                    Darwin.close(fd)
                    throw error
                }
            }
        } catch {
            for fd in descriptors.values { Darwin.close(fd) }
            throw error
        }
        let actualChannels = Set(metadata.keys)
        guard actualChannels.isSubset(of: expected) else {
            for fd in descriptors.values { Darwin.close(fd) }
            throw PendingCallRecoveryError.invalidManifest(
                "captured channel was not declared in expected_channels"
            )
        }
        return ValidatedCapture(
            startTime: Date(timeIntervalSince1970: manifest.startedAt),
            configuredChannels: expected,
            capturedChannels: actualChannels,
            metadata: metadata,
            channelFDs: descriptors
        )
    }

    private func validateMetadata(
        _ metadata: PendingCallChannelMetadata?,
        channel: PendingCallChannel
    ) throws {
        guard let metadata else { return }
        guard metadata.sampleRate.isFinite,
              metadata.sampleRate >= 8_000,
              metadata.sampleRate <= 384_000,
              metadata.sampleCount >= 0,
              metadata.droppedSampleCount >= 0,
              metadata.zeroFilledSampleCount >= 0,
              metadata.zeroFilledSampleCount <= metadata.sampleCount,
              metadata.timelineOriginOffsetSeconds.isFinite,
              metadata.timelineOriginOffsetSeconds >= 0,
              metadata.maxClockDriftSeconds.isFinite,
              metadata.maxClockDriftSeconds >= 0,
              metadata.discontinuityCount >= 0,
              (metadata.failure?.utf8.count ?? 0) <= 4_096 else {
            throw PendingCallRecoveryError.invalidManifest(
                "invalid \(channel.rawValue) channel metadata"
            )
        }
    }

    private struct ValidatedWAVHeader {
        let sampleRate: Double
        let sampleCount: UInt64
        let dataByteCount: UInt64
        let fileByteCount: UInt64
    }

    /// Reads exactly the fixed PCM16 header. No chunk scanning or allocation is
    /// allowed before the format and bounded file size are established.
    private func validateWAV(fd: Int32, channel: PendingCallChannel) throws -> ValidatedWAVHeader {
        try Self.validateDescriptor(
            fd,
            kind: .regularFile,
            requireSingleLink: true,
            description: channel.fileName
        )
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw operationError("stat \(channel.fileName)") }
        let fileSize = info.st_size
        guard fileSize >= off_t(Self.headerByteCount),
              UInt64(fileSize) <= UInt64(UInt32.max) + UInt64(Self.headerByteCount) else {
            throw PendingCallRecoveryError.invalidAudio("\(channel.fileName) has an invalid bounded size")
        }
        var header = [UInt8](repeating: 0, count: Self.headerByteCount)
        let bytesRead = pread(fd, &header, header.count, 0)
        guard bytesRead == header.count,
              ascii(header, 0, 4) == "RIFF",
              ascii(header, 8, 4) == "WAVE",
              ascii(header, 12, 4) == "fmt ",
              littleUInt32(header, 16) == 16,
              littleUInt16(header, 20) == 1,
              littleUInt16(header, 22) == 1,
              ascii(header, 36, 4) == "data",
              littleUInt16(header, 32) == 2,
              littleUInt16(header, 34) == 16 else {
            throw PendingCallRecoveryError.invalidAudio("\(channel.fileName) is not fixed-header PCM16 mono WAV")
        }
        let sampleRate = littleUInt32(header, 24)
        let byteRate = littleUInt32(header, 28)
        guard sampleRate >= 8_000,
              sampleRate <= 384_000,
              byteRate == sampleRate * 2 else {
            throw PendingCallRecoveryError.invalidAudio("\(channel.fileName) has inconsistent PCM parameters")
        }
        let actualDataBytes = UInt64(fileSize - off_t(Self.headerByteCount)) & ~UInt64(1)
        let declaredRIFFBytes = UInt64(littleUInt32(header, 4))
        let declaredDataBytes = UInt64(littleUInt32(header, 40))
        let declaredRIFFDataBytes = declaredRIFFBytes >= 36
            ? declaredRIFFBytes - 36
            : 0
        guard declaredDataBytes <= actualDataBytes,
              declaredDataBytes.isMultiple(of: 2),
              declaredRIFFBytes == 0 || (
                declaredRIFFBytes >= 36
                    && declaredRIFFDataBytes <= actualDataBytes
                    && declaredRIFFDataBytes.isMultiple(of: 2)
              ) else {
            throw PendingCallRecoveryError.invalidAudio("\(channel.fileName) has inconsistent RIFF lengths")
        }
        return ValidatedWAVHeader(
            sampleRate: Double(sampleRate),
            sampleCount: actualDataBytes / 2,
            dataByteCount: actualDataBytes,
            fileByteCount: UInt64(Self.headerByteCount) + actualDataBytes
        )
    }

    private func repairWAVHeader(fd: Int32, header: ValidatedWAVHeader) throws {
        let riff = littleEndianData(UInt32(header.dataByteCount + 36))
        let data = littleEndianData(UInt32(header.dataByteCount))
        guard riff.withUnsafeBytes({ pwrite(fd, $0.baseAddress, riff.count, 4) }) == riff.count,
              data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, data.count, 40) }) == data.count,
              ftruncate(fd, off_t(header.fileByteCount)) == 0,
              fsync(fd) == 0 else {
            throw operationError("repair validated WAV header")
        }
    }

    // MARK: - Manifest and retirement

    private func readManifest(directoryFD: Int32) throws -> PendingCallManifest {
        let fd = openat(directoryFD, Self.markerFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw PendingCallRecoveryError.invalidManifest("missing recovery.json")
        }
        defer { Darwin.close(fd) }
        try Self.validateDescriptor(
            fd,
            kind: .regularFile,
            requireSingleLink: true,
            description: Self.markerFileName
        )
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_size > 0,
              info.st_size <= off_t(Self.maximumManifestBytes) else {
            throw PendingCallRecoveryError.invalidManifest("manifest exceeds the size limit")
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, $0.count, 0)
        }
        guard count == data.count else {
            throw PendingCallRecoveryError.invalidManifest("manifest could not be read atomically")
        }
        try validateManifestShape(data)
        do {
            let manifest = try JSONDecoder().decode(PendingCallManifest.self, from: data)
            guard let id = UUID(uuidString: manifest.callID),
                  canonical(id) == manifest.callID else {
                throw PendingCallRecoveryError.invalidManifest("call_id must be a canonical UUID")
            }
            return manifest
        } catch let error as PendingCallRecoveryError {
            throw error
        } catch {
            throw PendingCallRecoveryError.invalidManifest(error.localizedDescription)
        }
    }

    private func validateManifestShape(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PendingCallRecoveryError.invalidManifest("top level must be an object")
        }
        let required = Set([
            "schemaVersion", "callID", "startedAt", "state", "expectedChannels",
        ])
        let allowed = required.union(["mic", "system"])
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: allowed) else {
            throw PendingCallRecoveryError.invalidManifest("unexpected or missing manifest fields")
        }
        let requiredChannelFields = Set([
            "sampleRate", "sampleCount", "droppedSampleCount",
            "zeroFilledSampleCount", "timelineOriginOffsetSeconds",
            "maxClockDriftSeconds", "discontinuityCount", "isDegraded",
        ])
        for name in ["mic", "system"] {
            guard let raw = object[name] else { continue }
            if raw is NSNull { continue }
            guard let channel = object[name] as? [String: Any],
                  requiredChannelFields.isSubset(of: Set(channel.keys)),
                  Set(channel.keys).isSubset(of: requiredChannelFields.union(["failure"])) else {
                throw PendingCallRecoveryError.invalidManifest("invalid \(name) metadata shape")
            }
        }
    }

    private func writeManifest(_ manifest: PendingCallManifest, directoryFD: Int32) throws {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumManifestBytes else {
            throw PendingCallRecoveryError.invalidManifest("manifest exceeds the size limit")
        }
        try writeAtomicFile(
            data,
            finalName: Self.markerFileName,
            directoryFD: directoryFD
        )
    }

    private func writeRetirementMarker(claim: PendingCallClaim) throws {
        let object: [String: Any] = [
            "schema_version": 1,
            "call_id": canonical(claim.callID),
            "retired_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let fd = openat(
            claim.directoryFD,
            Self.retiredFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        if fd < 0, errno == EEXIST {
            let existing = openat(
                claim.directoryFD,
                Self.retiredFileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard existing >= 0 else { throw operationError("open retirement marker") }
            defer { Darwin.close(existing) }
            try Self.validateDescriptor(
                existing,
                kind: .regularFile,
                requireSingleLink: true,
                description: Self.retiredFileName
            )
            return
        }
        guard fd >= 0 else { throw operationError("create retirement marker") }
        defer { Darwin.close(fd) }
        try writeAll(data, fd: fd)
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
            throw operationError("sync retirement marker")
        }
        guard fsync(claim.directoryFD) == 0 else {
            throw operationError("sync retirement directory")
        }
    }

    private func writeAtomicFile(_ data: Data, finalName: String, directoryFD: Int32) throws {
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
        guard renameat(directoryFD, temporaryName, directoryFD, finalName) == 0 else {
            throw operationError("publish manifest")
        }
        guard fsync(directoryFD) == 0 else { throw operationError("sync manifest directory") }
        succeeded = true
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw operationError("write file")
            }
            offset += count
        }
    }

    // MARK: - Descriptor helpers

    private enum DescriptorKind { case directory, regularFile }

    private static func validateDescriptor(
        _ fd: Int32,
        kind: DescriptorKind,
        requireSingleLink: Bool,
        description: String
    ) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw PendingCallRecoveryError.unsafeEntry("could not stat \(description)")
        }
        let expectedType: mode_t = kind == .directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard info.st_mode & mode_t(S_IFMT) == expectedType,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              !requireSingleLink || info.st_nlink == 1 else {
            throw PendingCallRecoveryError.unsafeEntry(
                "\(description) must be owner-only, owner-matched, non-linked \(kind == .directory ? "directory" : "file")"
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
            if result != 0, allowMissingSuffix, errno == ENOENT {
                return
            }
            guard result == 0 else {
                throw PendingCallRecoveryError.unsafeRoot("cannot inspect \(current.path)")
            }
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw PendingCallRecoveryError.unsafeRoot("symlink component \(current.path)")
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

    private static func openDirectory(_ path: String, description: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw PendingCallRecoveryError.unsafeRoot(
                "cannot open \(description): \(String(cString: strerror(errno)))"
            )
        }
        return fd
    }

    private func openDirectory(at parentFD: Int32, name: String) throws -> Int32 {
        guard isSinglePathComponent(name) else {
            throw PendingCallRecoveryError.unsafeEntry("invalid directory component")
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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

    private func openOptionalAudio(
        directoryFD: Int32,
        channel: PendingCallChannel,
        writable: Bool
    ) throws -> Int32? {
        let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
        let fd = openat(directoryFD, channel.fileName, flags)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else {
            throw PendingCallRecoveryError.unsafeEntry(
                "cannot open \(channel.fileName): \(String(cString: strerror(errno)))"
            )
        }
        return fd
    }

    private func parseDirectoryName(_ name: String) -> (id: UUID, state: String)? {
        guard isSinglePathComponent(name),
              let separator = name.lastIndex(of: ".") else { return nil }
        let idText = String(name[..<separator])
        let state = String(name[name.index(after: separator)...])
        guard ["recording", "captured", "recovering"].contains(state),
              let id = UUID(uuidString: idText),
              canonical(id) == idText else { return nil }
        return (id, state)
    }

    private func directoryName(callID: UUID, state: String) -> String {
        "\(canonical(callID)).\(state)"
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains(":") && !value.contains("%")
            && !value.contains("\\") && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func operationError(_ operation: String) -> PendingCallRecoveryError {
        .operationFailed("\(operation): \(String(cString: strerror(errno)))")
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

    private func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        String(bytes: bytes[offset..<(offset + count)], encoding: .ascii) ?? ""
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
}
