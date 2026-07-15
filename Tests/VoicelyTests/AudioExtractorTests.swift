import XCTest
import AVFoundation
@testable import VoicelyCore

final class AudioExtractorTests: XCTestCase {

    private func allocatedBytes<T>(for values: [T]) -> (
        pointer: UnsafeMutableRawPointer,
        byteCount: Int
    ) {
        let byteCount = values.count * MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, byteCount),
            alignment: MemoryLayout<T>.alignment
        )
        values.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress, byteCount > 0 {
                pointer.copyMemory(from: baseAddress, byteCount: byteCount)
            }
        }
        return (pointer, byteCount)
    }

    private func appendMemory(
        _ memory: (pointer: UnsafeMutableRawPointer, byteCount: Int),
        to blockBuffer: CMBlockBuffer
    ) throws {
        let status = CMBlockBufferAppendMemoryBlock(
            blockBuffer,
            memoryBlock: memory.pointer,
            length: memory.byteCount,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: memory.byteCount,
            flags: 0
        )
        XCTAssertEqual(status, kCMBlockBufferNoErr)
        if status != kCMBlockBufferNoErr {
            throw AudioExtractionError.blockBufferReadFailed(status: status)
        }
    }

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

    func testStreamPCMDeliversMultipleBoundedChunks() async throws {
        let url = try generateToneWav(seconds: 1.2)
        defer { try? FileManager.default.removeItem(at: url) }

        actor ChunkCollector {
            var counts: [Int] = []
            var starts: [Int] = []

            func add(_ chunk: AudioExtractor.PCMChunk) {
                counts.append(chunk.samples.count)
                starts.append(chunk.startSample)
            }

            func snapshot() -> (counts: [Int], starts: [Int]) {
                (counts, starts)
            }
        }
        let collector = ChunkCollector()

        let summary = try await AudioExtractor.streamPCM(
            from: url,
            chunkSampleCount: 8_000,
            onProgress: { _ in }
        ) { chunk in
            await collector.add(chunk)
        }

        let snapshot = await collector.snapshot()
        XCTAssertEqual(snapshot.counts, [8_000, 8_000, 3_200])
        XCTAssertEqual(snapshot.starts, [0, 8_000, 16_000])
        XCTAssertEqual(summary.totalSamples, snapshot.counts.reduce(0, +))
        XCTAssertEqual(summary.chunkCount, 3)
        XCTAssertEqual(summary.maxBufferedSamples, 8_000)
        XCTAssertLessThanOrEqual(summary.maxBufferedSamples, 8_000)
    }

    func testStreamPCMStopsWhenChunkConsumerCancels() async throws {
        let url = try generateToneWav(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        actor CallCounter {
            var value = 0
            func increment() { value += 1 }
        }
        let counter = CallCounter()

        do {
            _ = try await AudioExtractor.streamPCM(
                from: url,
                chunkSampleCount: 8_000,
                onProgress: { _ in }
            ) { _ in
                await counter.increment()
                throw CancellationError()
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: AVAssetReader is cancelled by streamPCM's defer.
        }

        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
    }

    func testSegmentedCMBlockBufferCopiesEveryFloatInOrder() throws {
        let first = allocatedBytes(for: [Float](arrayLiteral: 0.25, -0.5, 0.75))
        let second = allocatedBytes(for: [Float](arrayLiteral: 1.0, -1.25, 1.5))
        defer {
            first.pointer.deallocate()
            second.pointer.deallocate()
        }

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateEmpty(
                allocator: kCFAllocatorDefault,
                capacity: 2,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let buffer = try XCTUnwrap(blockBuffer)
        try appendMemory(first, to: buffer)
        try appendMemory(second, to: buffer)

        var copied: [Float] = []
        var byteOffset = 0
        while let chunk = try AudioExtractor.copyPCMFloatChunk(
            in: buffer,
            byteOffset: byteOffset,
            maximumSamplesPerCopy: 2
        ) {
            copied.append(contentsOf: chunk.samples)
            byteOffset = chunk.nextByteOffset
        }

        XCTAssertEqual(copied, [0.25, -0.5, 0.75, 1.0, -1.25, 1.5])
    }

    func testMisalignedCMBlockBufferReturnsTypedError() throws {
        let bytes = allocatedBytes(for: [UInt8](repeating: 0xA5, count: 5))
        defer { bytes.pointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateEmpty(
                allocator: kCFAllocatorDefault,
                capacity: 1,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let buffer = try XCTUnwrap(blockBuffer)
        try appendMemory(bytes, to: buffer)

        do {
            _ = try AudioExtractor.copyPCMFloatChunk(
                in: buffer,
                byteOffset: 0
            )
            XCTFail("expected malformed PCM error")
        } catch AudioExtractionError.malformedPCMData(let byteCount) {
            XCTAssertEqual(byteCount, 5)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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
