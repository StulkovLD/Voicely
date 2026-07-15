import AVFoundation
import Darwin
import XCTest
@testable import VoicelyCore

final class CallArtifactStorageTests: XCTestCase {
    @MainActor
    func testDetailedSaveReportsAndManifestsEveryArtifact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TranscriptStorage(baseDir: root)
        let audio = try makeBuffer(samples: [0.1, -0.1, 0.2, -0.2])
        let result = storage.saveCallDetailed(
            mic: audio,
            system: audio,
            segments: [
                DialogueSegment(
                    speaker: .you,
                    start: 0,
                    end: 1,
                    text: "hello",
                    language: "en"
                )
            ],
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceApp: "Tests"
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.mic.wasSaved)
        XCTAssertTrue(result.system.wasSaved)
        XCTAssertTrue(result.transcript.wasSaved)
        XCTAssertTrue(result.jsonl.wasSaved)
        XCTAssertTrue(result.manifest.wasSaved)
        XCTAssertEqual(result.failedArtifactNames, [])

        let directory = try XCTUnwrap(result.directoryURL)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        let artifacts = try XCTUnwrap(object["artifacts"] as? [String: [String: String]])
        XCTAssertEqual(artifacts["mic.wav"]?["state"], "saved")
        XCTAssertEqual(artifacts["system.wav"]?["state"], "saved")

        for name in ["mic.wav", "system.wav", "transcript.md", "transcript.jsonl", "manifest.json"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    @MainActor
    func testDetailedSavePersistsCaptureInterruptionReasonInManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TranscriptStorage(baseDir: root)
        let audio = try makeBuffer(samples: [0.1, -0.1, 0.2, -0.2])
        let reason = "Microphone configuration changed during call recording"
        let metadata = CallTranscriptCaptureMetadata(
            state: .partial,
            partialReason: "capture_interrupted",
            interruptionReason: reason,
            note: "Call capture was interrupted: \(reason).",
            micDurationSeconds: 120,
            systemDurationSeconds: 120,
            channelEndGapSeconds: 0
        )

        let result = storage.saveCallDetailed(
            mic: audio,
            system: audio,
            segments: [],
            startTime: Date(timeIntervalSince1970: 1_700_000_050),
            sourceApp: "Tests",
            captureMetadata: metadata
        )

        let directory = try XCTUnwrap(result.directoryURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let capture = try XCTUnwrap(object["capture"] as? [String: Any])
        XCTAssertEqual(capture["state"] as? String, "partial")
        XCTAssertEqual(capture["reason"] as? String, "capture_interrupted")
        XCTAssertEqual(capture["interruption_reason"] as? String, reason)
        XCTAssertTrue((capture["note"] as? String)?.contains(reason) == true)
        XCTAssertEqual(capture["channel_end_gap_seconds"] as? Double, 0)
    }

    @MainActor
    func testDetailedSaveDoesNotHideAudioWriteFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = TranscriptStorage(baseDir: root)
        let audio = try makeBuffer(samples: [0.1, -0.1])
        let start = Date(timeIntervalSince1970: 1_700_000_100)

        let first = storage.saveCallDetailed(
            mic: audio,
            system: nil,
            segments: [],
            startTime: start,
            sourceApp: nil
        )
        let directory = try XCTUnwrap(first.directoryURL)
        let micURL = directory.appendingPathComponent("mic.wav")
        try FileManager.default.removeItem(at: micURL)
        try FileManager.default.createDirectory(at: micURL, withIntermediateDirectories: false)

        let second = storage.saveCallDetailed(
            mic: audio,
            system: nil,
            segments: [],
            startTime: start,
            sourceApp: nil
        )

        guard case .failed = second.mic else {
            return XCTFail("mic.wav must expose its write failure")
        }
        XCTAssertFalse(second.isComplete)
        XCTAssertTrue(second.transcriptWasSaved)
        XCTAssertTrue(second.failedArtifactNames.contains("mic.wav"))
    }

    @MainActor
    func testFileBackedSavePublishesWAVsThenRemovesConfirmedStaging() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let store = try PendingCallRecoveryStore(rootURL: pendingRoot)
        let claim = try makeClaim(
            store: store,
            micSamples: [1, 2, 3],
            systemSamples: [-1, -2, -3, -4]
        )
        let storage = TranscriptStorage(baseDir: root.appendingPathComponent("library"))

        let result = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: "Tests"
        )

        XCTAssertTrue(result.isFullyFinalized)
        XCTAssertEqual(result.sourceCleanup, .cleaned)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: pendingRoot.path).isEmpty)
        let directory = try XCTUnwrap(result.directoryURL)
        XCTAssertEqual(
            try AVAudioFile(forReading: directory.appendingPathComponent("mic.wav")).length,
            3
        )
        XCTAssertEqual(
            try AVAudioFile(forReading: directory.appendingPathComponent("system.wav")).length,
            4
        )
    }

    @MainActor
    func testFileBackedSaveRetainsRecoverySourceWhenDestinationOwnershipFails() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let store = try PendingCallRecoveryStore(rootURL: pendingRoot)
        let claim = try makeClaim(
            store: store,
            micSamples: [1, 2],
            systemSamples: [3, 4]
        )
        let library = root.appendingPathComponent("library")
        let storage = TranscriptStorage(baseDir: library)
        let callDirectory = library
            .appendingPathComponent("calls", isDirectory: true)
            .appendingPathComponent(claim.callID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: callDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: callDirectory.path
        )
        let ownerURL = callDirectory.appendingPathComponent(".call-id")
        try writePrivate(
            Data((UUID().uuidString.lowercased() + "\n").utf8),
            to: ownerURL
        )

        let result = storage.saveCallDetailed(
            sourceCapture: claim,
            segments: [],
            sourceApp: nil
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.sourceCleanup, .retained)
        XCTAssertTrue(result.failedArtifactNames.contains("call directory"))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: pendingRoot.path)
                .contains { $0.hasSuffix(".recovering") },
            "recovery staging must survive every partial save"
        )
        XCTAssertNotNil(claim.micFileURL)
        XCTAssertNotNil(claim.systemFileURL)
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let destination = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            destination.initialize(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func makeClaim(
        store: PendingCallRecoveryStore,
        micSamples: [Int16],
        systemSamples: [Int16]
    ) throws -> PendingCallClaim {
        let handle = try store.createCapture(
            startTime: Date(timeIntervalSince1970: 1_700_000_200),
            expectedChannels: [.mic, .system]
        )
        try writePrivate(pcm16WAV(samples: micSamples), to: handle.micFileURL)
        try writePrivate(pcm16WAV(samples: systemSamples), to: handle.systemFileURL)
        try store.markCaptured(
            handle,
            mic: captureMetadata(sampleCount: micSamples.count),
            system: captureMetadata(sampleCount: systemSamples.count)
        )
        return try store.claim(handle)
    }

    private func captureMetadata(sampleCount: Int) -> PendingCallChannelMetadata {
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

    private func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
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
            .appendingPathComponent("voicely-call-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
}
