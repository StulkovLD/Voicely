import XCTest
import AVFoundation
@testable import VoicelyCore

private actor MockFileDiarizer: FileDiarizing {
    private var requestedURLs: [URL] = []

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        requestedURLs.append(fileURL)
        return [SpeakerTurn(speakerIndex: 1, start: 0, end: 60)]
    }

    func urls() -> [URL] {
        requestedURLs
    }
}

/// Holds the first inference even after its task is cancelled. This models
/// CoreML/provider calls that only return at an internal boundary.
private actor CancellationIgnoringFileTranscriber: SampleTranscribing {
    private var calls = 0
    private var firstCallStarted = false
    private var firstCallReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        calls += 1
        let call = calls
        if call == 1 {
            firstCallStarted = true
            if !firstCallReleased {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }
        return WhisperTranscription(
            text: "call\(call)",
            segments: [WhisperSegment(start: 0, end: 1, text: "call\(call)")],
            detectedLanguage: "en"
        )
    }

    func hasStartedFirstCall() -> Bool { firstCallStarted }
    func callCount() -> Int { calls }

    func releaseFirstCall() {
        firstCallReleased = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class FileTranscriptionQueueTests: XCTestCase {

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func makeQueue(
        mock: MockSampleTranscriber = MockSampleTranscriber(),
        diarizer: (any FileDiarizing)? = nil
    ) -> FileTranscriptionQueue {
        FileTranscriptionQueue(
            transcriber: mock,
            modelName: "test-model",
            centralRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ftq-\(UUID().uuidString)/files"),
            // 16000 samples per second × 0.5 s = 8000 samples per fake chunk
            // so tests can build multi-chunk inputs cheaply.
            chunkSampleCount: 8000,
            diarizer: diarizer
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

    func testEachQueuedFileKeepsItsLanguageAndTranslationSnapshot() async throws {
        let mock = MockSampleTranscriber()
        mock.delayPerCall = .milliseconds(40)
        let queue = makeQueue(mock: mock)
        let first = try writeSilenceWav(seconds: 0.2)
        let second = try writeSilenceWav(seconds: 0.2)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let done = expectation(description: "settings snapshots complete")
        queue.onStateChange = { state, _ in
            if case .idle = state { done.fulfill() }
        }
        let options = FileTranscriptionOptions(content: .plain, format: .markdown)
        queue.enqueue(
            [first],
            options: options,
            requestSettings: .init(
                modelName: "snapshot-model",
                translateToEnglish: false,
                preferredLanguage: "ru"
            )
        )
        queue.enqueue(
            [second],
            options: options,
            requestSettings: .init(
                modelName: "snapshot-model",
                translateToEnglish: true,
                preferredLanguage: nil
            )
        )

        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertFalse(mock.calls[0].translate)
        XCTAssertEqual(mock.calls[0].language, "ru")
        XCTAssertTrue(mock.calls[1].translate)
        XCTAssertNil(mock.calls[1].language)
        XCTAssertEqual(queue.jobs.map(\.requestSettings), [
            .init(
                modelName: "snapshot-model",
                translateToEnglish: false,
                preferredLanguage: "ru"
            ),
            .init(
                modelName: "snapshot-model",
                translateToEnglish: true,
                preferredLanguage: nil
            ),
        ])
        let centralURLs = try queue.jobs.map { job -> URL in
            guard case let .completed(_, centralURL) = job.status else {
                return try XCTUnwrap(Optional<URL>.none, "job did not complete")
            }
            return centralURL
        }
        let firstTranscript = try String(contentsOf: centralURLs[0], encoding: .utf8)
        let secondTranscript = try String(contentsOf: centralURLs[1], encoding: .utf8)
        XCTAssertTrue(firstTranscript.contains("language: ru"))
        XCTAssertTrue(secondTranscript.contains("language: en"))
        XCTAssertTrue(firstTranscript.contains("model: snapshot-model"))
        XCTAssertTrue(secondTranscript.contains("model: snapshot-model"))
    }

    func testSecondBatchDoesNotReprocessCompleted() async throws {
        let mock = MockSampleTranscriber()
        let queue = makeQueue(mock: mock)
        let f1 = try writeSilenceWav(seconds: 0.6)
        let f2 = try writeSilenceWav(seconds: 0.6)
        defer {
            try? FileManager.default.removeItem(at: f1)
            try? FileManager.default.removeItem(at: f2)
        }
        let opts = FileTranscriptionOptions(content: .plain, format: .plainText)

        // Batch 1: one file, run to idle.
        let idle1 = expectation(description: "batch 1 idle")
        queue.onStateChange = { state, _ in if case .idle = state { idle1.fulfill() } }
        queue.enqueue([f1], options: opts)
        await fulfillment(of: [idle1], timeout: 10)
        let callsAfterBatch1 = mock.calls.count
        XCTAssertGreaterThanOrEqual(callsAfterBatch1, 1)

        // Batch 2: a different file. The completed f1 must be pruned, NOT re-run.
        let idle2 = expectation(description: "batch 2 idle")
        queue.onStateChange = { state, _ in if case .idle = state { idle2.fulfill() } }
        queue.enqueue([f2], options: opts)
        await fulfillment(of: [idle2], timeout: 10)

        XCTAssertEqual(queue.jobs.count, 1,
            "the completed batch-1 job must be pruned; only the new file remains")
        let batch2Calls = mock.calls.count - callsAfterBatch1
        XCTAssertEqual(batch2Calls, callsAfterBatch1,
            "batch 2 must transcribe only the new file (same size), not re-run f1")
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

    func testMultiChunkFileKeepsDecodedPCMAtOneConfiguredWindow() async throws {
        let mock = MockSampleTranscriber()
        let queue = makeQueue(mock: mock)
        let url = try writeSilenceWav(seconds: 3.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "queue idle")
        queue.onStateChange = { state, _ in
            if case .idle = state { done.fulfill() }
        }
        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain,
            format: .plainText
        ))

        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(mock.calls.map(\.sampleCount), [
            8_000, 8_000, 8_000, 8_000, 8_000, 8_000, 3_200,
        ])
        XCTAssertEqual(queue.maximumBufferedSamplesObserved, 8_000)
        XCTAssertLessThanOrEqual(
            queue.maximumBufferedSamplesObserved,
            8_000,
            "decoded PCM must stay bounded to one configured transcription window"
        )
    }

    func testDiarizationUsesOriginalFileURLInsteadOfRetainedPCM() async throws {
        let mock = MockSampleTranscriber()
        let diarizer = MockFileDiarizer()
        let queue = makeQueue(mock: mock, diarizer: diarizer)
        let url = try writeSilenceWav(seconds: 0.6)
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "queue idle")
        queue.onStateChange = { state, _ in
            if case .idle = state { done.fulfill() }
        }
        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain,
            format: .plainText,
            diarize: true
        ))

        await fulfillment(of: [done], timeout: 10)
        let diarizedURLs = await diarizer.urls()
        XCTAssertEqual(diarizedURLs, [url])
        XCTAssertLessThanOrEqual(queue.maximumBufferedSamplesObserved, 8_000)
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

    func testCancelledGenerationRetainsOwnershipUntilIgnoringEngineReturns() async throws {
        let transcriber = CancellationIgnoringFileTranscriber()
        let queue = FileTranscriptionQueue(
            transcriber: transcriber,
            modelName: "test-model",
            centralRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("ftq-generation-\(UUID().uuidString)/files"),
            chunkSampleCount: 8_000
        )
        let cancelledURL = try writeSilenceWav(seconds: 0.4)
        let replacementURL = try writeSilenceWav(seconds: 0.4)
        defer {
            try? FileManager.default.removeItem(at: cancelledURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }

        var idleObserved = false
        let finalIdle = expectation(description: "replacement batch idle")
        queue.onStateChange = { state, _ in
            if case .idle = state {
                idleObserved = true
                finalIdle.fulfill()
            }
        }

        let options = FileTranscriptionOptions(content: .plain, format: .plainText)
        queue.enqueue([cancelledURL], options: options)
        let started = await waitUntil { await transcriber.hasStartedFirstCall() }
        guard started else {
            queue.cancelAll()
            await transcriber.releaseFirstCall()
            XCTFail("timed out waiting for first inference")
            return
        }

        queue.cancelAll()
        queue.enqueue([replacementURL], options: options)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(idleObserved, "cancel must not publish idle before the backend exits")
        let callsBeforeRelease = await transcriber.callCount()
        XCTAssertEqual(
            callsBeforeRelease, 1,
            "replacement work must not overlap the cancelled generation"
        )

        await transcriber.releaseFirstCall()
        await fulfillment(of: [finalIdle], timeout: 5)

        let finalCallCount = await transcriber.callCount()
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(queue.jobs.count, 1)
        guard let replacement = queue.jobs.first else { return }
        XCTAssertEqual(replacement.sourceURL, replacementURL)
        if case .completed = replacement.status {} else {
            XCTFail("replacement job should complete, got \(replacement.status)")
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

    func testQueueWritesParagraphShapedTranscriptFromSegments() async throws {
        let mock = MockSampleTranscriber()
        mock.resultProvider = { _ in
            WhisperTranscription(
                text: "First sentence. Second sentence. Third sentence.",
                segments: [
                    WhisperSegment(start: 0.0, end: 1.0, text: "First sentence."),
                    WhisperSegment(start: 1.05, end: 2.0, text: "Second sentence."),
                    WhisperSegment(start: 4.4, end: 5.2, text: "Third sentence."),
                ],
                detectedLanguage: "en"
            )
        }
        let queue = makeQueue(mock: mock)
        let url = try writeSilenceWav(seconds: 0.4) // one fake chunk
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("txt"))
        }

        let done = expectation(description: "queue idle")
        queue.onStateChange = { state, _ in
            if case .idle = state { done.fulfill() }
        }
        queue.enqueue([url], options: FileTranscriptionOptions(
            content: .plain, format: .plainText))

        await fulfillment(of: [done], timeout: 10)

        let transcriptURL = url.deletingPathExtension().appendingPathExtension("txt")
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(
            text.contains("First sentence. Second sentence.\n\nThird sentence."),
            "expected paragraph-shaped transcript, got: \(text)"
        )
        XCTAssertFalse(
            text.contains("First sentence. Second sentence. Third sentence."),
            "queue should persist the writer's paragraph composition, not the flat transport join"
        )
    }
}
