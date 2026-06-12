import XCTest
import AVFoundation
@testable import VoicelyCore

final class AudioExtractorTests: XCTestCase {

    /// Generates a 16 kHz mono wav file at a temp location containing `seconds`
    /// worth of a 440 Hz sine wave. Returns its URL.
    private func generateToneWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioext-tone-\(UUID().uuidString).wav")
        let sampleRate: Double = 16000
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
        let ptr = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            ptr[i] = Float(sin(2 * .pi * 440 * t) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    /// Generates a 44.1 kHz stereo wav of silence. Used to verify
    /// AudioExtractor resamples to 16 kHz + downmixes to mono.
    private func generateStereoSilenceWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioext-silence-\(UUID().uuidString).wav")
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(seconds * sampleRate)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Buffer is zero-initialized (silence)
        try file.write(from: buffer)
        return url
    }

    func testExtractsToneWavToFloats() async throws {
        let url = try generateToneWav(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try await AudioExtractor.extractPCM(from: url) { _ in }
        // 2 seconds at 16 kHz = ~32000 samples. Allow ±100 for header/boundary.
        XCTAssertGreaterThan(samples.count, 31000)
        XCTAssertLessThan(samples.count, 33000)
        // Non-zero content (it's a sine wave)
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = sqrt(sumSquares / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.1, "tone should have energy")
    }

    func testResamplesTo16kHzAndDownmixesToMono() async throws {
        let url = try generateStereoSilenceWav(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try await AudioExtractor.extractPCM(from: url) { _ in }
        // 1 second at 16 kHz = ~16000 mono samples regardless of input being 44.1 kHz stereo.
        XCTAssertGreaterThan(samples.count, 15500)
        XCTAssertLessThan(samples.count, 16500)
    }

    func testReportsProgress() async throws {
        let url = try generateToneWav(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }

        actor ProgressCollector {
            var values: [Double] = []
            func add(_ v: Double) { values.append(v) }
            func snapshot() -> [Double] { values }
        }
        let collector = ProgressCollector()

        _ = try await AudioExtractor.extractPCM(from: url) { p in
            Task { await collector.add(p) }
        }

        // Give the collector tasks a moment to drain
        try await Task.sleep(for: .milliseconds(300))
        let values = await collector.snapshot()
        XCTAssertGreaterThan(values.count, 0,
            "progress callback must fire at least once")
        XCTAssertLessThanOrEqual(values.last ?? 0, 1.0)
        XCTAssertGreaterThanOrEqual(values.first ?? 1, 0.0)
    }

    func testThrowsOnMissingFile() async {
        let bogus = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        do {
            _ = try await AudioExtractor.extractPCM(from: bogus) { _ in }
            XCTFail("expected error for missing file")
        } catch {
            // expected
        }
    }
}
