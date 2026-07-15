import AVFoundation
import XCTest
@testable import Voicely

@MainActor
final class DictationChunkLifecycleTests: XCTestCase {
    private actor SuspensionGate {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?

        func suspendTranscription() async {
            started = true
            waiter?.resume()
            waiter = nil
            await withCheckedContinuation { continuation in
                release = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }

        func finishTranscription() {
            release?.resume()
            release = nil
        }
    }

    func testCancelledInFlightChunkCommitsExactlyOnce() async {
        let gate = SuspensionGate()
        var committed: [String] = []
        let samples = [Float](repeating: 0.1, count: 300)

        let task = Task { @MainActor in
            await AppDelegate.transcribeAndCommitDictationChunk(
                samples: samples,
                sampleRate: 100,
                logPrefix: "cancelled in-flight test",
                transcribe: { _ in
                    await gate.suspendTranscription()
                    return "kept chunk"
                },
                commit: { committed.append(contentsOf: $0.fragments) }
            )
        }

        await gate.waitUntilStarted()
        task.cancel()
        await gate.finishTranscription()
        await task.value

        XCTAssertEqual(committed, ["kept chunk"])
    }

    func testDiscardedPendingChunkCannotFinalizeReplacementSession() {
        let discardedSession = UUID()
        let replacementSession = UUID()

        XCTAssertFalse(
            AppDelegate.dictationFinalizationOwnsSession(
                completingOwner: discardedSession,
                currentOwner: replacementSession
            )
        )
        XCTAssertTrue(
            AppDelegate.dictationFinalizationOwnsSession(
                completingOwner: replacementSession,
                currentOwner: replacementSession
            )
        )
        XCTAssertFalse(
            AppDelegate.dictationFinalizationOwnsSession(
                completingOwner: discardedSession,
                currentOwner: nil
            )
        )
    }

    func testRecorderStopFailuresPreserveCompletedTextAndForceRawRecovery() {
        let completed = DictationDecodeOutcome.recognized("kept chunk")

        for error in [RecorderError.noEngine, .formatError] {
            let outcome = AppDelegate.dictationOutcomeAfterRecorderStop(
                error,
                completedChunks: completed
            )

            XCTAssertEqual(outcome.fragments, ["kept chunk"])
            XCTAssertEqual(outcome.recognizedFragmentCount, 1)
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
    }

    func testNoSamplesAfterCompletedChunkIsACompleteDrainedTail() {
        let completed = DictationDecodeOutcome.recognized("complete chunk")
        let outcome = AppDelegate.dictationOutcomeAfterRecorderStop(
            .noSamples,
            completedChunks: completed
        )

        XCTAssertEqual(outcome, completed)
        XCTAssertFalse(outcome.requiresRecovery)
        XCTAssertEqual(
            AppDelegate.dictationRecoveryDisposition(
                for: outcome,
                transcriptSaveSucceeded: true,
                terminationInProgress: false
            ),
            .commit
        )
    }
}
