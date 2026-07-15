import AVFoundation
import Foundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

final class CallRecorderLifecycleTests: XCTestCase {
    func testRecorderIsNotHealthyBeforeBothCapturePathsStart() {
        XCTAssertFalse(CallRecorder().isFullyRunning)
    }

    func testActiveCaptureStatesDeferApplicationTermination() {
        XCTAssertTrue(AppDelegate.shouldDeferTermination(for: .callStarting))
        XCTAssertTrue(AppDelegate.shouldDeferTermination(for: .callRecording))
        XCTAssertTrue(AppDelegate.shouldDeferTermination(for: .callTranscribing))
        XCTAssertFalse(AppDelegate.shouldDeferTermination(for: .idle))
        XCTAssertTrue(AppDelegate.shouldDeferTermination(for: .recording))
        XCTAssertTrue(AppDelegate.shouldDeferTermination(for: .transcribing))
    }

    func testDurationLimitUsesActualSampleRate() {
        XCTAssertEqual(
            CallRecorder.sampleLimit(maxHours: 1, sampleRate: 44_100),
            158_760_000
        )
        XCTAssertEqual(
            CallRecorder.sampleLimit(maxHours: 1, sampleRate: 48_000),
            172_800_000
        )
    }

    func testDurationWarningAndRemainingSecondsUseActualSampleRate() {
        let warning = CallRecorder.warningSampleThreshold(
            maxHours: 1,
            sampleRate: 44_100,
            warningLeadSeconds: 300
        )

        XCTAssertEqual(warning, 145_530_000)
        XCTAssertEqual(
            CallRecorder.remainingSeconds(
                maxHours: 1,
                sampleCount: warning,
                sampleRate: 44_100
            ),
            300
        )
    }

    func testDurationLimitNeverExceedsClassicPCM16WAVCapacity() {
        let limit = CallRecorder.sampleLimit(maxHours: 8, sampleRate: 96_000)

        XCTAssertEqual(limit, CallCaptureWAVWriter.maximumPCM16SampleCount)
        XCTAssertEqual(
            CallRecorder.remainingSeconds(
                maxHours: 8,
                sampleCount: limit,
                sampleRate: 96_000
            ),
            0
        )
    }

    func testDiskWriterRejectsNonFiniteAndUnsupportedSampleRates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try CallCaptureWAVWriter(
            url: root.appendingPathComponent("nan.wav"),
            sampleRate: .nan
        ))
        XCTAssertThrowsError(try CallCaptureWAVWriter(
            url: root.appendingPathComponent("too-low.wav"),
            sampleRate: 1_000
        ))
        XCTAssertThrowsError(try CallCaptureWAVWriter(
            url: root.appendingPathComponent("too-high.wav"),
            sampleRate: 500_000
        ))
    }

    func testStreamErrorGateCanFireOnlyOncePerRecording() {
        let gate = CallRecorderStreamErrorGate()

        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
        gate.reset()
        XCTAssertTrue(gate.claim())
    }

    func testInterruptionBeforeStartHandoffPreventsRecordingPublicationAndSurvivesStop() async {
        let lifecycle = CallRecorderLifecycleState()
        let reason = "Screen recording stream stopped: connection invalid"

        XCTAssertTrue(lifecycle.beginStart())
        let publication = lifecycle.publishRunningIfHealthy()
        XCTAssertTrue(publication.healthy)
        XCTAssertNil(publication.pendingInterruption)
        XCTAssertTrue(lifecycle.recordInterruption(reason))
        XCTAssertFalse(
            lifecycle.recordInterruption("later duplicate"),
            "the first runtime reason is authoritative"
        )
        let handoff = lifecycle.startHandoffStatus()
        XCTAssertEqual(handoff, .interrupted(reason))
        XCTAssertNotEqual(
            handoff,
            .healthy,
            "the app must not publish .callRecording after a latched interruption"
        )
        XCTAssertTrue(
            lifecycle.beginStreamDeathCleanup(),
            "producer death must retain truth for the later async finalize"
        )

        let stopReason = await Task.detached {
            lifecycle.beginStop()
        }.value

        XCTAssertEqual(stopReason, reason)
        XCTAssertFalse(lifecycle.isRunning)
        lifecycle.finishStop()
        XCTAssertTrue(lifecycle.beginStart(), "finalize must release the next session")
    }

    func testHealthyStartHandoffThenLaterInterruptionStillReachesStop() async {
        let lifecycle = CallRecorderLifecycleState()
        let reason = "Microphone configuration changed during call recording"

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.publishRunningIfHealthy().healthy)
        XCTAssertEqual(
            lifecycle.startHandoffStatus(),
            .healthy,
            "a healthy snapshot lets AppDelegate publish .callRecording synchronously"
        )

        XCTAssertTrue(lifecycle.recordInterruption(reason))
        XCTAssertTrue(
            lifecycle.beginStreamDeathCleanup(),
            "the queued app callback must be able to finalize after UI publication"
        )

        let stopReason = await Task.detached {
            lifecycle.beginStop()
        }.value

        XCTAssertEqual(stopReason, reason)
        lifecycle.finishStop()
    }

    func testStartupInterruptionStillForcesRollbackWithoutRuntimeCaptureReason() {
        let lifecycle = CallRecorderLifecycleState()
        let reason = "stream failed before both producers were healthy"

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertFalse(lifecycle.recordInterruption(reason))
        let publication = lifecycle.publishRunningIfHealthy()

        XCTAssertFalse(publication.healthy)
        XCTAssertEqual(publication.pendingInterruption, reason)
        XCTAssertNil(lifecycle.beginStop())
        lifecycle.finishStop()
    }

    func testDiskWriterDrainsToReadableWAVWithBoundedQueue() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("system.wav")
        let writer = try CallCaptureWAVWriter(
            url: url,
            sampleRate: 48_000,
            pendingBufferCount: 64
        )
        let chunk = [Float](repeating: 0.25, count: 4_096)

        for _ in 0..<10 {
            _ = writer.enqueue(chunk)
        }
        let snapshot = writer.finish()

        XCTAssertEqual(snapshot.sampleCount, 40_960)
        XCTAssertEqual(snapshot.droppedSampleCount, 0)
        XCTAssertLessThanOrEqual(snapshot.peakQueuedBufferCount, 64)
        XCTAssertLessThanOrEqual(snapshot.peakQueuedSampleCount, 64 * 4_096)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(Int(file.length), snapshot.sampleCount)
    }

    func testDiskWriterBackpressureDropsInsteadOfGrowingPastFixedRing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CallCaptureWAVWriter(
            url: root.appendingPathComponent("mic.wav"),
            sampleRate: 48_000,
            pendingBufferCount: 2,
            artificialWriteDelay: 0.03
        )
        let chunk = [Float](repeating: 0.1, count: 4_096)
        let offeredSamples = 20 * chunk.count

        for _ in 0..<20 {
            _ = writer.enqueue(chunk)
        }
        let snapshot = writer.finish()

        XCTAssertGreaterThan(snapshot.droppedSampleCount, 0)
        XCTAssertTrue(snapshot.isDegraded)
        XCTAssertEqual(snapshot.sampleCount, offeredSamples,
                       "dropped payload must be zero-filled without compressing time")
        XCTAssertGreaterThanOrEqual(
            snapshot.zeroFilledSampleCount,
            snapshot.droppedSampleCount
        )
        XCTAssertEqual(snapshot.ringSampleCapacity, 2 * 4_096)
        XCTAssertLessThanOrEqual(snapshot.peakQueuedBufferCount, 2)
        XCTAssertLessThanOrEqual(snapshot.peakQueuedSampleCount, 2 * 4_096)
    }

    func testDiskWriterPreservesTimestampGapWithSilence() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("system.wav")
        let writer = try CallCaptureWAVWriter(
            url: url,
            sampleRate: 48_000,
            timelineOriginSeconds: 100
        )
        let tenMilliseconds = [Float](repeating: 0.25, count: 480)

        _ = writer.enqueue(
            tenMilliseconds,
            presentationTimeSeconds: 100
        )
        _ = writer.enqueue(
            tenMilliseconds,
            presentationTimeSeconds: 100.2
        )
        let snapshot = writer.finish()

        XCTAssertEqual(snapshot.sampleCount, 10_080)
        XCTAssertEqual(snapshot.zeroFilledSampleCount, 9_120)
        XCTAssertEqual(snapshot.discontinuityCount, 1)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 10_080)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(data[479], 0.25, accuracy: 0.001)
        XCTAssertEqual(data[480], 0, accuracy: 0.001)
        XCTAssertEqual(data[9_599], 0, accuracy: 0.001)
        XCTAssertEqual(data[9_600], 0.25, accuracy: 0.001)
    }

    func testDiskWriterPreservesLeadingOriginOffset() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let writer = try CallCaptureWAVWriter(
            url: url,
            sampleRate: 48_000,
            timelineOriginSeconds: 200
        )

        _ = writer.enqueue(
            [Float](repeating: 0.1, count: 480),
            presentationTimeSeconds: 200.1
        )
        let snapshot = writer.finish()

        XCTAssertEqual(snapshot.timelineOriginOffsetSeconds, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.zeroFilledSampleCount, 4_800)
        XCTAssertEqual(snapshot.sampleCount, 5_280)
    }

    func testDiskWriterClampsPathologicalTimestampToBoundedTimeline() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CallCaptureWAVWriter(
            url: root.appendingPathComponent("system.wav"),
            sampleRate: 48_000
        )

        _ = writer.enqueue(
            [Float](repeating: 0.1, count: 10),
            maximumTotalSamples: 1_000,
            presentationTimeSeconds: -Double.greatestFiniteMagnitude
        )
        let result = writer.enqueue(
            [Float](repeating: 0.1, count: 10),
            maximumTotalSamples: 1_000,
            presentationTimeSeconds: Double.greatestFiniteMagnitude
        )
        let snapshot = writer.finish()

        XCTAssertEqual(result.timelineSampleCount, 1_000)
        XCTAssertEqual(snapshot.sampleCount, 1_000)
        XCTAssertTrue(snapshot.isDegraded)
    }

    func testDiskWriterSanitizesNonFiniteSamples() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CallCaptureWAVWriter(
            url: root.appendingPathComponent("mic.wav"),
            sampleRate: 48_000
        )

        _ = writer.enqueue([0.25, .nan, .infinity, -0.25])
        let snapshot = writer.finish()

        XCTAssertEqual(snapshot.sampleCount, 4)
        XCTAssertEqual(snapshot.droppedSampleCount, 2)
        XCTAssertEqual(snapshot.zeroFilledSampleCount, 2)
        XCTAssertTrue(snapshot.isDegraded)
    }

    func testDiskWriterReportsDegradationOffAudioCallbackQueue() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let callbackQueue = DispatchQueue(label: "test.audio-callback")
        let callbackKey = DispatchSpecificKey<Bool>()
        callbackQueue.setSpecific(key: callbackKey, value: true)
        let reported = expectation(description: "degradation reported")
        let writer = try CallCaptureWAVWriter(
            url: root.appendingPathComponent("system.wav"),
            sampleRate: 48_000,
            pendingBufferCount: 1,
            artificialWriteDelay: 0.05,
            onDegraded: { _ in
                XCTAssertNil(DispatchQueue.getSpecific(key: callbackKey))
                reported.fulfill()
            }
        )
        let chunk = [Float](repeating: 0.1, count: 4_096)

        callbackQueue.sync {
            for _ in 0..<10 { _ = writer.enqueue(chunk) }
        }
        wait(for: [reported], timeout: 2)
        _ = writer.finish()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-call-recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
