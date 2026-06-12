import XCTest
import AVFoundation
@testable import VoicelyCore

@MainActor
final class FileTranscriptionQueueTests: XCTestCase {

    private func makeQueue(
        mock: MockSampleTranscriber = MockSampleTranscriber()
    ) -> FileTranscriptionQueue {
        FileTranscriptionQueue(
            transcriber: mock,
            modelName: "test-model",
            centralRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ftq-\(UUID().uuidString)/files"),
            // 16000 samples per second × 0.5 s = 8000 samples per fake chunk
            // so tests can build multi-chunk inputs cheaply.
            chunkSampleCount: 8000
        )
    }

    /// Build a real wav on disk with non-silent content so AudioExtractor + the
    /// silence gate (RMS > 0.005) both pass.
    private func writeSilenceWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftq-wav-\(UUID().uuidString).wav")
        let sampleRate: Double = 16000
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Non-silent: fill with 0.1 so RMS > silence threshold
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { ptr[i] = 0.1 }
        try file.write(from: buffer)
        return url
    }

    func testEnqueueThreeFilesProcessesAll() async throws {
        let mock = MockSampleTranscriber()
        let queue = makeQueue(mock: mock)
        let urls = try [
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let doneExpectation = expectation(description: "queue idle")
        queue.onStateChange = { state, _ in
            if case .idle = state { doneExpectation.fulfill() }
        }
        queue.enqueue(urls, options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        await fulfillment(of: [doneExpectation], timeout: 10)
        XCTAssertGreaterThanOrEqual(mock.calls.count, 3,
            "expected at least one transcribe call per file")
    }

    func testFailedFileDoesNotStopQueue() async throws {
        let mock = MockSampleTranscriber()
        mock.throwOnCallIndex = 0 // break the first file
        let queue = makeQueue(mock: mock)
        let urls = try [
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let done = expectation(description: "queue idle")
        var finalJobs: [FileTranscriptionQueue.Job] = []
        queue.onStateChange = { state, jobs in
            if case .idle = state {
                finalJobs = jobs
                done.fulfill()
            }
        }
        queue.enqueue(urls, options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(finalJobs.count, 2)
        guard finalJobs.count == 2 else { return }
        if case .failed = finalJobs[0].status {} else {
            XCTFail("expected first job failed, got \(finalJobs[0].status)")
        }
        if case .completed = finalJobs[1].status {} else {
            XCTFail("expected second job completed, got \(finalJobs[1].status)")
        }
    }

    func testSilentChunkIsSkippedNotFailed() async throws {
        let mock = MockSampleTranscriber()
        mock.errorToThrow = TranscriberError.silentAudio
        mock.throwOnCallIndex = 0 // first chunk of first file throws silentAudio
        let queue = makeQueue(mock: mock)
        let url = try writeSilenceWav(seconds: 1.2)  // 2 chunks at 0.5 s
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "queue idle")
        var finalJobs: [FileTranscriptionQueue.Job] = []
        queue.onStateChange = { state, jobs in
            if case .idle = state {
                finalJobs = jobs
                done.fulfill()
            }
        }
        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        await fulfillment(of: [done], timeout: 10)
        guard finalJobs.count == 1 else {
            XCTFail("expected 1 job, got \(finalJobs.count)")
            return
        }
        if case .completed = finalJobs[0].status {} else {
            XCTFail("silentAudio must not fail the job, got \(finalJobs[0].status)")
        }
    }

    func testCancelAllStopsQueue() async throws {
        let mock = MockSampleTranscriber()
        mock.delayPerCall = .milliseconds(500)
        let queue = makeQueue(mock: mock)
        let urls = try [
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        queue.enqueue(urls, options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        // Let the first call begin
        try await Task.sleep(for: .milliseconds(100))
        queue.cancelAll()

        // Give the queue up to 2 seconds to settle
        try await Task.sleep(for: .seconds(2))

        // At most the first call should have happened (maybe second started).
        // The assertion we care about: queue did not process all 3 files.
        XCTAssertLessThan(mock.calls.count, 3,
            "cancelAll should stop the queue before finishing")
    }

    func testCancelAllMarksJobsCancelledNotFailed() async throws {
        let mock = MockSampleTranscriber()
        mock.delayPerCall = .milliseconds(400)
        let queue = makeQueue(mock: mock)
        let urls = try [
            writeSilenceWav(seconds: 0.6),
            writeSilenceWav(seconds: 0.6),
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Capture the last non-idle jobs snapshot that still has status
        // information. cancelAll() emits .idle with the jobs populated,
        // then internally clears them.
        var capturedJobs: [FileTranscriptionQueue.Job] = []
        let done = expectation(description: "queue idle")
        queue.onStateChange = { state, jobs in
            if case .idle = state {
                capturedJobs = jobs
                done.fulfill()
            }
        }
        queue.enqueue(urls, options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        try await Task.sleep(for: .milliseconds(100))
        queue.cancelAll()

        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(capturedJobs.isEmpty,
            "cancelAll should fire .idle with jobs populated before clearing")
        for job in capturedJobs {
            switch job.status {
            case .cancelled, .completed:
                continue
            default:
                XCTFail("expected .cancelled or .completed, got \(job.status)")
            }
        }
    }

    func testAwaitPausedBlocksUntilEngineIdle() async throws {
        let mock = MockSampleTranscriber()
        mock.delayPerCall = .milliseconds(400)
        let queue = makeQueue(mock: mock)
        let url = try writeSilenceWav(seconds: 1.5) // 3 chunks
        defer { try? FileManager.default.removeItem(at: url) }

        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        // Let the first chunk start
        try await Task.sleep(for: .milliseconds(100))
        queue.pause()

        let start = ContinuousClock.now
        let paused = await queue.awaitPaused()
        let elapsed = ContinuousClock.now - start

        XCTAssertTrue(paused, "awaitPaused should return true within timeout")
        // Should return shortly after the in-flight chunk (400 ms) finishes.
        XCTAssertLessThan(elapsed, .milliseconds(800),
            "awaitPaused should return soon after chunk completes")

        queue.cancelAll()
    }

    func testPauseBlocksNextChunk() async throws {
        let mock = MockSampleTranscriber()
        mock.delayPerCall = .milliseconds(200)
        let queue = makeQueue(mock: mock)
        let url = try writeSilenceWav(seconds: 1.5) // 3 × 0.5s chunks
        defer { try? FileManager.default.removeItem(at: url) }

        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        // Wait long enough for the first chunk to start + finish (~300 ms)
        try await Task.sleep(for: .milliseconds(350))
        queue.pause()

        // Now wait to confirm no more chunks fire
        let callsAtPause = mock.calls.count
        try await Task.sleep(for: .milliseconds(600))
        let callsAfterPause = mock.calls.count
        XCTAssertEqual(callsAfterPause, callsAtPause,
            "no new chunks should be processed while paused")

        // Resume and let the queue finish
        queue.resume()
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(mock.calls.count, callsAfterPause,
            "resume should let the remaining chunks through")
    }
}
