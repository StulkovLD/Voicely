import Foundation
@preconcurrency import AVFoundation

public enum AudioExtractionError: Error, LocalizedError {
    case noAudioTrack
    case unsupportedFormat(String)
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The file doesn't contain an audio track."
        case .unsupportedFormat(let detail):
            return "Unsupported audio format: \(detail)"
        case .readerFailed(let detail):
            return "Could not decode audio: \(detail)"
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

    public static func extractPCM(
        from url: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> [Float] {
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
            AVSampleRateKey: 16000.0,
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

        let totalSeconds = max(duration.seconds, 0.001)
        var samples: [Float] = []
        // Preallocate roughly: duration × 16000
        samples.reserveCapacity(Int(totalSeconds * 16000) + 1024)

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer else {
                continue
            }
            let floatCount = totalLength / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPtr in
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: floatPtr, count: floatCount))
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
        // Ensure we end at 1.0 so UI doesn't hang on 0.98
        onProgress(1.0)

        return samples
    }
}
