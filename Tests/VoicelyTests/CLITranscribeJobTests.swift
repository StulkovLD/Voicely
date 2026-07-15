import AVFoundation
import XCTest
@testable import VoicelyCLI
@testable import VoicelyCore

private actor CLIURLDiarizer: FileDiarizing {
    private var requestedURLs: [URL] = []

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        requestedURLs.append(fileURL)
        return [SpeakerTurn(speakerIndex: 1, start: 0, end: 60)]
    }

    func urls() -> [URL] { requestedURLs }
}

/// Deliberately ignores task cancellation while its first inference is held.
/// TranscribeJob must notice cancellation immediately after the call returns
/// and must not decode or transcribe a second chunk.
private actor CancellationIgnoringCLITranscriber: SampleTranscribing {
    private var calls = 0
    private var started = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        calls += 1
        started = true
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return WhisperTranscription(
            text: "late result",
            segments: [WhisperSegment(start: 0, end: 1, text: "late result")],
            detectedLanguage: "en"
        )
    }

    func hasStarted() -> Bool { started }

    func release() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func callCount() -> Int { calls }
}

@MainActor
final class CLITranscribeJobTests: XCTestCase {
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

    private func writeToneWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-stream-\(UUID().uuidString).wav")
        let sampleRate = AudioExtractor.outputSampleRate
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
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
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(2 * .pi * 440 * Double(index) / sampleRate) * 0.25)
        }
        try file.write(from: buffer)
        return url
    }

    func testProcessFileStreamsBoundedChunksAndDiarizesOriginalURL() async throws {
        let url = try writeToneWav(seconds: 3.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriber = MockSampleTranscriber()
        let diarizer = CLIURLDiarizer()

        let execution = try await TranscribeJob.processFile(
            sourceURL: url,
            engine: transcriber,
            shouldDiarize: true,
            forcedLanguage: nil,
            modelName: "test-model",
            diarizer: diarizer,
            chunkSampleCount: 8_000
        )

        XCTAssertEqual(transcriber.calls.map(\.sampleCount), [
            8_000, 8_000, 8_000, 8_000, 8_000, 8_000, 3_200,
        ])
        XCTAssertEqual(execution.maximumBufferedSamples, 8_000)
        XCTAssertLessThanOrEqual(execution.maximumBufferedSamples, 8_000)
        let requestedURLs = await diarizer.urls()
        XCTAssertEqual(requestedURLs, [url])
        XCTAssertNotNil(execution.result.diarizedSegments)
    }

    func testCancellationAfterInferencePreventsNextChunkAndResult() async throws {
        let url = try writeToneWav(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let transcriber = CancellationIgnoringCLITranscriber()

        let task = Task { @MainActor in
            try await TranscribeJob.processFile(
                sourceURL: url,
                engine: transcriber,
                shouldDiarize: false,
                forcedLanguage: nil,
                modelName: "test-model",
                diarizer: nil,
                chunkSampleCount: 8_000
            )
        }

        let started = await waitUntil { await transcriber.hasStarted() }
        guard started else {
            task.cancel()
            await transcriber.release()
            _ = await task.result
            XCTFail("timed out waiting for the first inference")
            return
        }
        task.cancel()
        await transcriber.release()

        do {
            _ = try await task.value
            XCTFail("cancelled transcription must not return a publishable result")
        } catch is CancellationError {
            // Expected.
        }

        let callCount = await transcriber.callCount()
        XCTAssertEqual(callCount, 1, "cancellation must stop before the next chunk")
    }

    func testUnknownModelFailsBeforeRuntimeOrModelLoading() async {
        let job = TranscribeJob(
            fileURL: URL(fileURLWithPath: "/does/not/need/to/exist.wav"),
            diarize: false,
            forcedLanguage: nil,
            modelVariant: "invented-model"
        )

        do {
            _ = try await job.execute()
            XCTFail("unknown model must be rejected")
        } catch TranscribeJobError.unknownModelVariant(let variant) {
            XCTAssertEqual(variant, "invented-model")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnsupportedLanguageFailsBeforeRuntimeOrModelLoading() async {
        let job = TranscribeJob(
            fileURL: URL(fileURLWithPath: "/does/not/need/to/exist.wav"),
            diarize: false,
            forcedLanguage: "de",
            modelVariant: nil
        )

        do {
            _ = try await job.execute()
            XCTFail("unsupported language must be rejected")
        } catch TranscribeJobError.unsupportedLanguage(let language) {
            XCTAssertEqual(language, "de")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRuntimeRetainsOneSharedDiarizerInstance() {
        let diarizer = CLIURLDiarizer()
        let runtime = CLITranscriptionRuntime(diarizer: diarizer)
        let first = runtime.sharedDiarizer()
        let second = runtime.sharedDiarizer()

        XCTAssertTrue((first as AnyObject) === diarizer)
        XCTAssertTrue((second as AnyObject) === diarizer)
    }
}
