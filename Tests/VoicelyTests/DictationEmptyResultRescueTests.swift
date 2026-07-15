import AVFoundation
import XCTest
@testable import Voicely

@MainActor
final class DictationEmptyResultRescueTests: XCTestCase {

    private enum TestFailure: Error {
        case decode
    }

    private final class ScriptedBufferTranscriber {
        private let responses: [Result<String, Error>]
        private let defaultResponse: Result<String, Error>
        private var idx = 0
        private var frameLengths: [Int] = []

        init(
            responses: [Result<String, Error>],
            defaultResponse: Result<String, Error> = .success("")
        ) {
            self.responses = responses
            self.defaultResponse = defaultResponse
        }

        func transcribe(_ buffer: AVAudioPCMBuffer) throws -> String {
            frameLengths.append(Int(buffer.frameLength))
            let response = idx < responses.count ? responses[idx] : defaultResponse
            idx += 1
            return try response.get()
        }

        func recordedFrameLengths() -> [Int] {
            frameLengths
        }
    }

    private func makeSamples(seconds: Double, sampleRate: Double = 100, amplitude: Float) -> [Float] {
        let count = Int(seconds * sampleRate)
        return [Float](repeating: amplitude, count: count)
    }

    private func makeBuffer(samples: [Float], sampleRate: Double = 100) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { source in
            channel.initialize(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    func testEmptyNonSilentChunkSplitsIntoSmallerRescueWindows() async {
        let script = ScriptedBufferTranscriber(
            responses: [
                .success(""),
                .success("alpha"),
                .success("beta"),
                .success("gamma"),
            ],
            defaultResponse: .success("unexpected")
        )

        let outcome = await AppDelegate.transcribeWithEmptyResultRescue(
            samples: makeSamples(seconds: 30, amplitude: 0.1),
            sampleRate: 100,
            logPrefix: "test chunk"
        ) { buffer in
            try script.transcribe(buffer)
        }

        XCTAssertEqual(outcome.fragments, ["alpha", "beta", "gamma"])
        XCTAssertFalse(outcome.requiresRecovery)
        XCTAssertEqual(script.recordedFrameLengths(), [3000, 1000, 1000, 1000])
    }

    func testEmptySilentAudioDoesNotTriggerRescueOrMarker() async {
        let script = ScriptedBufferTranscriber(
            responses: [.success("")],
            defaultResponse: .success("should-not-run")
        )

        let outcome = await AppDelegate.transcribeWithEmptyResultRescue(
            samples: makeSamples(seconds: 30, amplitude: 0),
            sampleRate: 100,
            logPrefix: "silent chunk"
        ) { buffer in
            try script.transcribe(buffer)
        }

        XCTAssertEqual(outcome.fragments, [])
        XCTAssertFalse(outcome.hadTranscriptionFailure)
        XCTAssertFalse(outcome.isIncomplete)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: nil,
                terminationInProgress: false
            ),
            .commit
        )
        XCTAssertEqual(script.recordedFrameLengths(), [3000])
    }

    func testMarkerAppearsOnlyWhenEmptyRescueStillFindsNothing() async {
        let script = ScriptedBufferTranscriber(
            responses: [.success("")],
            defaultResponse: .success("")
        )

        let outcome = await AppDelegate.transcribeWithEmptyResultRescue(
            samples: makeSamples(seconds: 30, amplitude: 0.1),
            sampleRate: 100,
            logPrefix: "marker chunk"
        ) { buffer in
            try script.transcribe(buffer)
        }

        XCTAssertEqual(outcome.fragments, [AppDelegate.dictationGapMarker])
        XCTAssertFalse(outcome.hadTranscriptionFailure)
        XCTAssertTrue(outcome.isIncomplete)
        XCTAssertGreaterThan(script.recordedFrameLengths().count, 1)
    }

    func testTranscribeWindowedAppliesSameEmptyResultRescueToRemainderWindows() async throws {
        let script = ScriptedBufferTranscriber(
            responses: [
                .success(""),
                .success("alpha"),
                .success("beta"),
                .success("gamma"),
                .success("tail"),
            ],
            defaultResponse: .success("unexpected")
        )
        let buffer = try makeBuffer(samples: makeSamples(seconds: 40, amplitude: 0.1))

        let outcome = await AppDelegate.transcribeWindowed(
            buffer: buffer,
            logPrefix: "windowed test"
        ) { slice in
            try script.transcribe(slice)
        }

        XCTAssertEqual(outcome.fragments.joined(separator: " "), "alpha beta gamma tail")
        XCTAssertFalse(outcome.requiresRecovery)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: true,
                terminationInProgress: false
            ),
            .commit
        )
        XCTAssertEqual(script.recordedFrameLengths(), [3000, 1000, 1000, 1000, 1000])
    }

    func testAllFailedDecodePreservesAudioEvenWhenMarkerTranscriptWasSaved() async {
        let script = ScriptedBufferTranscriber(
            responses: [.failure(TestFailure.decode), .failure(TestFailure.decode)],
            defaultResponse: .failure(TestFailure.decode)
        )

        let outcome = await AppDelegate.transcribeWithEmptyResultRescue(
            samples: makeSamples(seconds: 30, amplitude: 0.1),
            sampleRate: 100,
            logPrefix: "all failed"
        ) { buffer in
            try script.transcribe(buffer)
        }

        XCTAssertEqual(outcome.fragments, [AppDelegate.dictationGapMarker])
        XCTAssertTrue(outcome.hadTranscriptionFailure)
        XCTAssertTrue(outcome.isIncomplete)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: true,
                terminationInProgress: true
            ),
            .preserve(reason: AppDelegate.dictationIncompleteRecoveryReason)
        )
    }

    func testMixedTextAndFailedWindowSavesPartialTextButPreservesAudio() async throws {
        let script = ScriptedBufferTranscriber(
            responses: [
                .success("kept text"),
                .failure(TestFailure.decode),
                .failure(TestFailure.decode),
            ],
            defaultResponse: .failure(TestFailure.decode)
        )
        let buffer = try makeBuffer(
            samples: makeSamples(seconds: 40, amplitude: 0.1)
        )

        let outcome = await AppDelegate.transcribeWindowed(
            buffer: buffer,
            logPrefix: "mixed failure"
        ) { slice in
            try script.transcribe(slice)
        }

        XCTAssertEqual(
            outcome.fragments,
            ["kept text", AppDelegate.dictationGapMarker]
        )
        XCTAssertEqual(outcome.recognizedFragmentCount, 1)
        XCTAssertTrue(outcome.hadTranscriptionFailure)
        XCTAssertTrue(outcome.isIncomplete)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: true,
                terminationInProgress: false
            ),
            .preserve(reason: AppDelegate.dictationIncompleteRecoveryReason)
        )
    }

    func testCancelledDecodeCannotSelectRecoveryCommit() {
        let outcome = DictationDecodeOutcome.cancelled

        XCTAssertTrue(outcome.isIncomplete)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: nil,
                terminationInProgress: true
            ),
            .preserve(reason: AppDelegate.dictationIncompleteRecoveryReason)
        )
    }
}
