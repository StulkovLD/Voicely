import Darwin
import Foundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

final class PendingCallRecoverySecurityTests: XCTestCase {
    func testCanonicalRootIsNotRewrittenThroughSystemSymlinkAlias() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try PendingCallRecoveryStore(rootURL: root)

        XCTAssertEqual(store.rootURL.path, root.path)
    }

    func testSymlinkRootIsRejectedBeforeTargetMutation() throws {
        let parent = try makeRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let linkedRoot = parent.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)

        XCTAssertThrowsError(try PendingCallRecoveryStore(rootURL: linkedRoot))
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testManifestRejectsTraversalAbsoluteAndEncodedCallIDs() throws {
        for maliciousID in [
            "../outside",
            "/tmp/outside",
            "..%2foutside",
            "folder/name",
            "folder\\name",
        ] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try PendingCallRecoveryStore(rootURL: root)
            try createManualCandidate(root: root, manifestCallID: maliciousID)

            XCTAssertTrue(store.claimRecoverableCaptures().isEmpty, maliciousID)
        }
    }

    func testManifestRejectsCallerControlledPathField() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let id = UUID()
        let directory = try createManualCandidate(root: root, id: id)
        let marker = directory.appendingPathComponent("recovery.json")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]
        )
        object["micPath"] = "../../outside.wav"
        try writePrivateJSON(object, to: marker)

        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
    }

    func testSymlinkDirectoryAndAudioFileAreRejectedWithoutTouchingTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let store = try PendingCallRecoveryStore(rootURL: root)

        let directoryID = UUID()
        let outsideDirectory = try createManualCandidate(root: outside, id: directoryID)
        let linkedDirectory = root.appendingPathComponent(
            "\(canonical(directoryID)).captured",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: outsideDirectory
        )

        let fileID = UUID()
        let fileCandidate = try createManualCandidate(root: root, id: fileID)
        let outsideWAV = outside.appendingPathComponent("outside.wav")
        let original = pcm16WAV(samples: [1, -1, 2, -2])
        try writePrivate(original, to: outsideWAV)
        try FileManager.default.createSymbolicLink(
            at: fileCandidate.appendingPathComponent("mic.wav"),
            withDestinationURL: outsideWAV
        )

        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
        XCTAssertEqual(try Data(contentsOf: outsideWAV), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }

    func testChannelWriterCreationRefusesExistingFileWithoutReplacingIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let handle = try store.createCapture(startTime: Date())
        let existing = Data("existing-channel".utf8)
        try writePrivate(existing, to: handle.micFileURL)

        XCTAssertThrowsError(
            try store.createChannelFileDescriptor(handle, channel: .mic)
        )
        XCTAssertEqual(try Data(contentsOf: handle.micFileURL), existing)
    }

    func testChannelWriterCreationRefusesSymlinkWithoutTouchingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("target.wav")
        let original = Data("outside-target".utf8)
        try writePrivate(original, to: target)
        let store = try PendingCallRecoveryStore(rootURL: root)
        let handle = try store.createCapture(startTime: Date())
        try FileManager.default.createSymbolicLink(
            at: handle.systemFileURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try store.createChannelFileDescriptor(handle, channel: .system)
        )
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testPreopenedChannelWriterStaysPinnedWhenPathIsReplaced() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let capture = try store.createCapture(startTime: Date())
        let descriptor = try store.createChannelFileDescriptor(
            capture,
            channel: .mic
        )
        let pinnedURL = capture.micFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("pinned.wav")
        try FileManager.default.moveItem(at: capture.micFileURL, to: pinnedURL)

        let target = outside.appendingPathComponent("target.wav")
        let original = Data("outside-target".utf8)
        try writePrivate(original, to: target)
        try FileManager.default.createSymbolicLink(
            at: capture.micFileURL,
            withDestinationURL: target
        )

        let writer = try CallCaptureWAVWriter(
            url: capture.micFileURL,
            sampleRate: 16_000,
            ownedFileDescriptor: descriptor
        )
        _ = writer.enqueue([0.25, -0.25])
        let snapshot = writer.finish()

        XCTAssertEqual(snapshot.sampleCount, 2)
        XCTAssertEqual(try Data(contentsOf: target), original)
        let pinned = try Data(contentsOf: pinnedURL)
        XCTAssertEqual(String(decoding: pinned.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(pinned.count, 48)
    }

    func testHardLinkedAudioIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let directory = try createManualCandidate(root: root)
        let source = root.appendingPathComponent("shared.wav")
        try writePrivate(pcm16WAV(samples: [1, 2, 3, 4]), to: source)
        let destination = directory.appendingPathComponent("mic.wav")
        XCTAssertEqual(Darwin.link(source.path, destination.path), 0)

        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
    }

    func testWrongMagicFormatAndTruncatedWAVAreRejected() throws {
        var wrongMagic = pcm16WAV(samples: [1, 2])
        wrongMagic.replaceSubrange(0..<4, with: Data("NOPE".utf8))
        var wrongFormat = pcm16WAV(samples: [1, 2])
        wrongFormat.replaceSubrange(20..<22, with: littleEndianData(UInt16(3)))
        let cases = [Data([0x52, 0x49, 0x46]), wrongMagic, wrongFormat]

        for data in cases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try PendingCallRecoveryStore(rootURL: root)
            let directory = try createManualCandidate(root: root)
            try writePrivate(data, to: directory.appendingPathComponent("mic.wav"))

            XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
        }
    }

    func testValidatedStaleHeaderIsRepairedOnlyAfterAtomicClaim() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let directory = try createManualCandidate(root: root, state: "recording")
        let wavURL = directory.appendingPathComponent("mic.wav")
        var wav = pcm16WAV(samples: [1, 2, 3, 4])
        wav.replaceSubrange(4..<8, with: littleEndianData(UInt32(0)))
        wav.replaceSubrange(40..<44, with: littleEndianData(UInt32(0)))
        try writePrivate(wav, to: wavURL)

        let claim = try XCTUnwrap(store.claimRecoverableCaptures().first)
        let repaired = try Data(contentsOf: XCTUnwrap(claim.micFileURL))
        XCTAssertEqual(readUInt32(repaired, at: 4), 44)
        XCTAssertEqual(readUInt32(repaired, at: 40), 8)
    }

    func testTwoSimultaneousStoresYieldOneClaim() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = try PendingCallRecoveryStore(rootURL: root)
        let secondStore = try PendingCallRecoveryStore(rootURL: root)
        let handle = try firstStore.createCapture(startTime: Date())
        try writePrivate(pcm16WAV(samples: [1, 2, 3, 4]), to: handle.micFileURL)
        try firstStore.markCaptured(handle, mic: metadata(sampleCount: 4), system: nil)

        let box = ClaimBox()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let store = index == 0 ? firstStore : secondStore
            if let claim = store.claimRecoverableCaptures().first {
                box.append(claim)
            }
        }

        XCTAssertEqual(box.count, 1)
    }

    @MainActor
    func testConfiguredButMissingChannelDoesNotBlockRecoveredAudioCleanup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root.appendingPathComponent("pending"))
        let handle = try store.createCapture(startTime: Date())
        try writePrivate(pcm16WAV(samples: [1, 2, 3, 4]), to: handle.micFileURL)
        try store.markCaptured(handle, mic: metadata(sampleCount: 4), system: nil)
        let claim = try store.claim(handle)
        let storage = TranscriptStorage(baseDir: root.appendingPathComponent("library"))

        let result = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )

        XCTAssertEqual(result.system, .notExpected)
        XCTAssertEqual(claim.configuredChannels, [.mic, .system])
        XCTAssertEqual(claim.capturedChannels, [.mic])
        XCTAssertTrue(result.isFullyFinalized)
    }

    func testDiscardEmptyUsesTypedHandleAndRefusesCapturedAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root)
        let empty = try store.createCapture(startTime: Date())
        try writePrivate(pcm16WAV(samples: []), to: empty.micFileURL)
        try writePrivate(pcm16WAV(samples: []), to: empty.systemFileURL)
        try store.markCaptured(
            empty,
            mic: metadata(sampleCount: 0),
            system: metadata(sampleCount: 0)
        )

        XCTAssertEqual(try store.discardEmpty(empty), .cleaned)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)

        let nonempty = try store.createCapture(startTime: Date())
        try writePrivate(pcm16WAV(samples: [1, 2]), to: nonempty.micFileURL)
        XCTAssertThrowsError(try store.discardEmpty(nonempty))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor
    func testDestinationCollisionRetainsClaimedSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root.appendingPathComponent("pending"))
        let claim = try makeClaim(store: store)
        let library = root.appendingPathComponent("library")
        let storage = TranscriptStorage(baseDir: library)
        let collision = library
            .appendingPathComponent("calls", isDirectory: true)
            .appendingPathComponent(canonical(claim.callID), isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: collision.path
        )

        let result = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.sourceCleanup, .retained)
        XCTAssertNotNil(claim.micFileURL)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
                .contains { $0.hasSuffix(".recovering") }
        )
    }

    @MainActor
    func testCleanupFailureIsIndependentAndRetainsRetiredSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PendingCallRecoveryStore(rootURL: root.appendingPathComponent("pending"))
        let claim = try makeClaim(store: store, expectedChannels: [.mic])
        let sourceDirectory = try XCTUnwrap(claim.micFileURL).deletingLastPathComponent()
        try writePrivate(Data("forensic note".utf8), to: sourceDirectory.appendingPathComponent("unexpected"))
        let storage = TranscriptStorage(baseDir: root.appendingPathComponent("library"))

        let result = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )

        XCTAssertTrue(result.isComplete)
        guard case .failed = result.sourceCleanup else {
            return XCTFail("Cleanup failure must be surfaced independently")
        }
        XCTAssertFalse(result.isFullyFinalized)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
                .contains { $0.hasSuffix(".retired") }
        )
        let retiredName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
                .first { $0.hasSuffix(".retired") }
        )
        let retainedUnexpected = store.rootURL
            .appendingPathComponent(retiredName, isDirectory: true)
            .appendingPathComponent("unexpected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedUnexpected.path))
        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
    }

    @MainActor
    func testSuccessfulRecoveryIsIdempotentAndCannotDeleteOutsideRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let store = try PendingCallRecoveryStore(rootURL: root.appendingPathComponent("pending"))
        let claim = try makeClaim(store: store, expectedChannels: [.mic])
        let storage = TranscriptStorage(baseDir: root.appendingPathComponent("library"))

        let first = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )
        let second = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )

        XCTAssertTrue(first.isFullyFinalized)
        XCTAssertTrue(second.isFullyFinalized)
        XCTAssertEqual(first.directoryURL?.path, second.directoryURL?.path)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertTrue(store.claimRecoverableCaptures().isEmpty)
    }

    // MARK: - Fixtures

    private func makeClaim(
        store: PendingCallRecoveryStore,
        expectedChannels: Set<PendingCallChannel> = [.mic, .system]
    ) throws -> PendingCallClaim {
        let handle = try store.createCapture(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            expectedChannels: expectedChannels
        )
        try writePrivate(pcm16WAV(samples: [1, 2, 3, 4]), to: handle.micFileURL)
        if expectedChannels.contains(.system) {
            try writePrivate(pcm16WAV(samples: [-1, -2, -3, -4]), to: handle.systemFileURL)
        }
        try store.markCaptured(
            handle,
            mic: metadata(sampleCount: 4),
            system: expectedChannels.contains(.system) ? metadata(sampleCount: 4) : nil
        )
        return try store.claim(handle)
    }

    @discardableResult
    private func createManualCandidate(
        root: URL,
        id: UUID = UUID(),
        state: String = "captured",
        manifestCallID: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(
            "\(canonical(id)).\(state)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let object: [String: Any] = [
            "schemaVersion": 2,
            "callID": manifestCallID ?? canonical(id),
            "startedAt": 1_700_000_000.0,
            "state": state == "recording" ? "recording" : "captured",
            "expectedChannels": ["mic"],
        ]
        try writePrivateJSON(
            object,
            to: directory.appendingPathComponent("recovery.json")
        )
        return directory
    }

    private func metadata(sampleCount: Int) -> PendingCallChannelMetadata {
        PendingCallChannelMetadata(
            sampleRate: 48_000,
            sampleCount: sampleCount,
            droppedSampleCount: 0,
            isDegraded: false
        )
    }

    private func pcm16WAV(samples: [Int16], sampleRate: UInt32 = 48_000) -> Data {
        let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data("RIFF".utf8)
        data.append(littleEndianData(UInt32(36) + dataByteCount))
        data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndianData(UInt32(16)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(sampleRate))
        data.append(littleEndianData(sampleRate * 2))
        data.append(littleEndianData(UInt16(2)))
        data.append(littleEndianData(UInt16(16)))
        data.append(Data("data".utf8))
        data.append(littleEndianData(dataByteCount))
        for sample in samples { data.append(littleEndianData(sample)) }
        return data
    }

    private func writePrivateJSON(_ object: [String: Any], to url: URL) throws {
        try writePrivate(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: url
        )
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func makeRoot() throws -> URL {
        let canonicalTemporaryDirectory = try canonicalDirectory(
            FileManager.default.temporaryDirectory
        )
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("voicely-pending-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertEqual(try canonicalDirectory(root).path, root.path)
        return root
    }

    private func canonicalDirectory(_ url: URL) throws -> URL {
        let pointer = url.path.withCString { realpath($0, nil) }
        guard let pointer else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer { free(pointer) }
        return URL(
            fileURLWithPath: String(cString: pointer),
            isDirectory: true
        )
    }

    private func canonical(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private final class ClaimBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: [PendingCallClaim] = []

    var count: Int { lock.withLock { claims.count } }

    func append(_ claim: PendingCallClaim) {
        lock.withLock { claims.append(claim) }
    }
}
