import Foundation
@preconcurrency import AVFoundation

public enum AudioExtractionError: Error, LocalizedError {
    case noAudioTrack
    case unsupportedFormat(String)
    case readerFailed(String)
    case missingSampleData
    case malformedPCMData(byteCount: Int)
    case blockBufferReadFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file doesn't contain an audio track."
        case .unsupportedFormat(let detail):
            return "Unsupported audio format: \(detail)"
        case .readerFailed(let detail):
            return "Could not decode audio: \(detail)"
        case .missingSampleData:
            return "Could not decode audio: an audio sample had no data buffer."
        case .malformedPCMData(let byteCount):
            return "Could not decode audio: PCM byte count \(byteCount) is not aligned to Float32 samples."
        case .blockBufferReadFailed(let status):
            return "Could not decode audio: CMBlockBuffer copy failed with status \(status)."
        }
    }
}

/// Decodes any AVFoundation-supported audio/video file into 16 kHz mono
/// Float32 PCM samples suitable for WhisperKit.
///
/// Uses `AVAssetReader` with an output configured to resample + downmix
/// inside AVFoundation, so we get clean 16 kHz mono samples without
/// separate resampling passes. For video files, the first audio track
/// is used.
public enum AudioExtractor {

    /// Copies a possibly segmented CoreMedia block buffer through a small,
    /// aligned scratch window. `CMBlockBufferGetDataPointer` only promises that
    /// `lengthAtOffset` bytes are contiguous; treating its pointer as if
    /// `totalLength` bytes followed can read beyond the first memory block.
    ///
    /// Internal for focused tests that construct genuinely non-contiguous
    /// `CMBlockBuffer` instances. The returned array owns its aligned memory;
    /// callers can safely retain it across an `await` before requesting the next
    /// bounded copy window.
    static func copyPCMFloatChunk(
        in blockBuffer: CMBlockBuffer,
        byteOffset: Int,
        maximumSamplesPerCopy requestedMaximum: Int = 4_096
    ) throws -> (samples: [Float], nextByteOffset: Int)? {
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let floatSize = MemoryLayout<Float>.size
        guard byteCount.isMultiple(of: floatSize) else {
            throw AudioExtractionError.malformedPCMData(byteCount: byteCount)
        }
        guard byteOffset >= 0,
              byteOffset <= byteCount,
              byteOffset.isMultiple(of: floatSize) else {
            throw AudioExtractionError.malformedPCMData(byteCount: byteCount)
        }
        guard byteOffset < byteCount else { return nil }

        let maximumSamplesPerCopy = max(1, requestedMaximum)
        let bytesToCopy = min(
            maximumSamplesPerCopy * floatSize,
            byteCount - byteOffset
        )
        var samples = [Float](
            repeating: 0,
            count: bytesToCopy / floatSize
        )
        let status = samples.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: byteOffset,
                dataLength: bytesToCopy,
                destination: destination.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AudioExtractionError.blockBufferReadFailed(status: status)
        }
        return (samples, byteOffset + bytesToCopy)
    }

    private actor PCMCollector {
        private var samples: [Float] = []

        func append(_ chunk: PCMChunk) {
            samples.append(contentsOf: chunk.samples)
        }

        func value() -> [Float] {
            samples
        }
    }

    public static let outputSampleRate: Double = 16_000

    public struct PCMChunk: Sendable {
        public let samples: [Float]
        public let startSample: Int
        public let estimatedTotalSamples: Int

        public init(samples: [Float], startSample: Int, estimatedTotalSamples: Int) {
            self.samples = samples
            self.startSample = startSample
            self.estimatedTotalSamples = estimatedTotalSamples
        }

        public var progress: Double {
            guard estimatedTotalSamples > 0 else { return 0 }
            return min(
                1,
                Double(startSample + samples.count) / Double(estimatedTotalSamples)
            )
        }
    }

    public struct PCMStreamSummary: Sendable, Equatable {
        public let totalSamples: Int
        public let chunkCount: Int
        public let maxBufferedSamples: Int
        public let estimatedTotalSamples: Int

        public init(
            totalSamples: Int,
            chunkCount: Int,
            maxBufferedSamples: Int,
            estimatedTotalSamples: Int
        ) {
            self.totalSamples = totalSamples
            self.chunkCount = chunkCount
            self.maxBufferedSamples = maxBufferedSamples
            self.estimatedTotalSamples = estimatedTotalSamples
        }
    }

    /// Compatibility API for callers that explicitly need the complete PCM.
    /// File transcription should use `streamPCM` so decoded audio stays bounded.
    public static func extractPCM(
        from url: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [Float] {
        let collector = PCMCollector()
        _ = try await streamPCM(
            from: url,
            chunkSampleCount: Int(outputSampleRate * 30),
            onProgress: onProgress
        ) { chunk in
            await collector.append(chunk)
        }
        return await collector.value()
    }

    /// Decode and deliver fixed-size 16 kHz mono chunks with backpressure.
    ///
    /// The next AVFoundation buffer is not requested until `onChunk` returns, so
    /// decoded PCM stays bounded to one caller-sized chunk plus the reader's
    /// current decoder buffer. The final chunk may be shorter. Chunks are
    /// delivered serially and never overlap.
    @discardableResult
    public static func streamPCM(
        from url: URL,
        chunkSampleCount requestedChunkSampleCount: Int,
        onProgress: @Sendable @escaping (Double) -> Void,
        onChunk: @Sendable @escaping (PCMChunk) async throws -> Void
    ) async throws -> PCMStreamSummary {
        let asset = AVURLAsset(url: url)

        // Load duration + tracks async (iOS-style async APIs work on macOS 14+)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        guard let track = tracks.first else {
            throw AudioExtractionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractionError.readerFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw AudioExtractionError.unsupportedFormat(
                "AVAssetReader rejected the LPCM output configuration")
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw AudioExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "unknown reader error")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let durationSeconds = duration.seconds
        let totalSeconds = durationSeconds.isFinite && durationSeconds > 0
            ? durationSeconds
            : 0.001
        let estimatedSampleValue = durationSeconds * outputSampleRate
        let estimatedTotalSamples: Int
        if estimatedSampleValue.isFinite, estimatedSampleValue > 0 {
            estimatedTotalSamples = estimatedSampleValue < Double(Int.max)
                ? Int(estimatedSampleValue.rounded(.up))
                : Int.max
        } else {
            estimatedTotalSamples = 0
        }

        let chunkSampleCount = max(1, requestedChunkSampleCount)
        var bufferedSamples: [Float] = []
        bufferedSamples.reserveCapacity(chunkSampleCount)
        var emittedSampleCount = 0
        var emittedChunkCount = 0
        var maxBufferedSamples = 0

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw AudioExtractionError.missingSampleData
            }
            var blockByteOffset = 0
            while let copied = try copyPCMFloatChunk(
                in: blockBuffer,
                byteOffset: blockByteOffset,
                maximumSamplesPerCopy: min(4_096, chunkSampleCount)
            ) {
                let floatSamples = copied.samples
                var sourceOffset = 0
                while sourceOffset < floatSamples.count {
                    try Task.checkCancellation()
                    let remainingCapacity = chunkSampleCount - bufferedSamples.count
                    let copyCount = min(
                        remainingCapacity,
                        floatSamples.count - sourceOffset
                    )
                    bufferedSamples.append(contentsOf: floatSamples[
                        sourceOffset..<(sourceOffset + copyCount)
                    ])
                    sourceOffset += copyCount
                    maxBufferedSamples = max(maxBufferedSamples, bufferedSamples.count)

                    if bufferedSamples.count == chunkSampleCount {
                        var readySamples: [Float] = []
                        swap(&readySamples, &bufferedSamples)
                        let readyCount = readySamples.count
                        try await onChunk(PCMChunk(
                            samples: readySamples,
                            startSample: emittedSampleCount,
                            estimatedTotalSamples: estimatedTotalSamples
                        ))
                        emittedSampleCount += readyCount
                        emittedChunkCount += 1

                        // Reuse the delivered chunk's allocation after the
                        // callback releases its value.
                        readySamples.removeAll(keepingCapacity: true)
                        swap(&readySamples, &bufferedSamples)
                    }
                }
                blockByteOffset = copied.nextByteOffset
            }

            // Progress = presentation time / total duration
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if pts.isFinite {
                let progress = min(1.0, max(0.0, pts / totalSeconds))
                onProgress(progress)
            }
        }

        if reader.status == .failed {
            throw AudioExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "reader failed")
        }

        if !bufferedSamples.isEmpty {
            let finalCount = bufferedSamples.count
            try await onChunk(PCMChunk(
                samples: bufferedSamples,
                startSample: emittedSampleCount,
                estimatedTotalSamples: estimatedTotalSamples
            ))
            emittedSampleCount += finalCount
            emittedChunkCount += 1
        }

        // Ensure we end at 1.0 so UI doesn't hang on 0.98
        onProgress(1.0)

        return PCMStreamSummary(
            totalSamples: emittedSampleCount,
            chunkCount: emittedChunkCount,
            maxBufferedSamples: maxBufferedSamples,
            estimatedTotalSamples: estimatedTotalSamples
        )
    }
}
