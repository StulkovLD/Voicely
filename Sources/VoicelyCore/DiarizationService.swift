import AVFoundation
import Foundation
@preconcurrency import FluidAudio

// MARK: - Diarization Service
//
// Thin wrapper over FluidAudio's offline-capable `DiarizerManager`
// (Pyannote powerset segmentation + WeSpeaker embeddings, running on CoreML /
// the Apple Neural Engine). Produces "who spoke when" speaker turns and maps
// them back onto ASR `DialogueSegment`s.
//
// This service is intentionally GENERIC: it knows nothing about `CallSpeaker`
// (you/other). N2b (calls) and N2c (file queue) are the only consumers; they
// read the per-segment `speakerID` it assigns. Speaker indices are 1-based and
// STABLE within a single `diarize(...)` pass (a global one-pass numbering keyed
// by first appearance of each FluidAudio speaker identity, so the index does
// not depend on FluidAudio's internal id string format which differs between
// the streaming "1"/"2" and offline "S1"/"S2" conventions).
//
// MODEL WEIGHTS / ATTRIBUTION (CC-BY-4.0):
// FluidAudio's diarization models are CoreML conversions of:
//   - Pyannote (segmentation):  https://github.com/pyannote/pyannote-audio
//   - WeSpeaker (embeddings):   https://github.com/wenet-e2e/wespeaker
// The pyannote/WeSpeaker model weights are distributed under CC-BY-4.0, which
// requires attribution. The "About" window MUST credit pyannote and WeSpeaker.
// The FluidAudio SDK itself is Apache-2.0.
//
// Models are downloaded at RUNTIME on first `diarize(...)` call (cached under
// the user's app-support directory by FluidAudio) — never at build time.

/// One contiguous stretch of speech attributed to a single speaker.
/// `speakerIndex` is 1-based and stable within the producing `diarize(...)`
/// pass. Timestamps are seconds from the start of the audio passed to
/// `diarize(...)`.
public struct SpeakerTurn: Sendable, Equatable {
    public let speakerIndex: Int
    public let start: Double
    public let end: Double

    public init(speakerIndex: Int, start: Double, end: Double) {
        self.speakerIndex = speakerIndex
        self.start = start
        self.end = end
    }
}

/// Errors surfaced by `DiarizationService`. `LocalizedError` so the UI can show
/// a sensible message; the underlying FluidAudio error (if any) is attached.
public enum DiarizationError: Error, LocalizedError {
    /// FluidAudio could not download / compile its CoreML models.
    case modelsUnavailable(String)
    /// The diarization pass itself failed inside FluidAudio.
    case diarizationFailed(String)
    /// The provided WAV file could not be read into Float samples.
    case audioReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelsUnavailable(let detail):
            return "Speaker models unavailable. \(detail)"
        case .diarizationFailed(let detail):
            return "Speaker separation failed. \(detail)"
        case .audioReadFailed(let detail):
            return "Could not read audio for speaker separation. \(detail)"
        }
    }
}

/// Actor-isolated wrapper so the non-`Sendable` `DiarizerManager` and its
/// downloaded models never cross an isolation boundary. All FluidAudio calls
/// run inside the actor; the inference itself is offloaded to the ANE by
/// FluidAudio, so holding the actor for the duration of a pass is acceptable.
public actor DiarizationService {
    /// FluidAudio's diarizer. Lazily created on first `diarize(...)`.
    private var manager: DiarizerManager?

    /// FluidAudio expects 16 kHz mono Float32. Callers that already resampled
    /// (the call path resamples per-channel) should pass `sampleRate: 16000`.
    public static let requiredSampleRate: Double = 16000

    public init() {}

    // MARK: - Lazy model init

    /// Download (first run) / load FluidAudio's diarization models and build the
    /// manager. Idempotent: once a manager exists this is a no-op. Models are
    /// fetched from FluidAudio's HuggingFace mirror on first use and cached on
    /// disk by FluidAudio for subsequent launches.
    private func ensureManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let models: DiarizerModels
        do {
            models = try await DiarizerModels.downloadIfNeeded()
        } catch {
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
        let m = DiarizerManager()
        m.initialize(models: models)
        manager = m
        return m
    }

    // MARK: - Diarize (samples)

    /// Diarize 16 kHz mono Float32 samples into 1-based stable speaker turns.
    ///
    /// `sampleRate` is forwarded to FluidAudio. FluidAudio's models are trained
    /// for 16 kHz; pass already-resampled audio at `requiredSampleRate` for best
    /// results. Empty input returns `[]` without touching the model.
    public func diarize(samples: [Float], sampleRate: Double) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let manager = try await ensureManager()

        let result: DiarizationResult
        do {
            // `performCompleteDiarization` is synchronous (throws). It is generic
            // over RandomAccessCollection<Float> with Int index — a plain [Float]
            // satisfies that. Runs inside the actor; FluidAudio offloads to ANE.
            result = try manager.performCompleteDiarization(
                samples,
                sampleRate: Int(sampleRate.rounded())
            )
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }

        return Self.makeStableTurns(from: result.segments)
    }

    // MARK: - Diarize (WAV file URL)

    /// Convenience overload for the call path: read a WAV file (e.g. the call's
    /// `system.wav`) into 16 kHz mono Float32 and diarize it. FluidAudio's stable
    /// `DiarizerManager` has no native URL entry point, so we decode + resample
    /// here via AVFoundation and delegate to `diarize(samples:sampleRate:)`.
    ///
    /// Returned turn timestamps are seconds from the start of the file.
    public func diarize(wavURL: URL) async throws -> [SpeakerTurn] {
        let samples = try Self.readMono16k(from: wavURL)
        return try await diarize(samples: samples, sampleRate: Self.requiredSampleRate)
    }

    // MARK: - Assign speakers to ASR segments

    /// Stamp each `DialogueSegment` with the `speakerIndex` of the `SpeakerTurn`
    /// it overlaps most (by intersection length on the `[start, end]` axis).
    /// Segments with no overlapping turn keep `speakerID == nil`. Pure and order-
    /// preserving; safe to call off the actor.
    ///
    /// Both inputs must share the same timeline (seconds from the same origin).
    public nonisolated static func assignSpeakers(
        to segments: [DialogueSegment],
        turns: [SpeakerTurn]
    ) -> [DialogueSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            var best: (index: Int, overlap: Double)? = nil
            for turn in turns {
                let lo = max(seg.start, turn.start)
                let hi = min(seg.end, turn.end)
                let overlap = hi - lo
                guard overlap > 0 else { continue }
                if best == nil || overlap > best!.overlap {
                    best = (turn.speakerIndex, overlap)
                }
            }
            guard let best else { return seg }
            var copy = seg
            copy.speakerID = best.index
            return copy
        }
    }

    // MARK: - Internal helpers

    /// Map FluidAudio's opaque `speakerId` strings ("1"/"2" streaming, "S1"/"S2"
    /// offline) to 1-based indices by ORDER OF FIRST APPEARANCE across the
    /// segment list. This makes the numbering stable within one pass and
    /// independent of FluidAudio's id-string format. Segments are kept in their
    /// original chronological order. Empty `speakerId`s are skipped.
    nonisolated static func makeStableTurns(
        from segments: [TimedSpeakerSegment]
    ) -> [SpeakerTurn] {
        var indexFor: [String: Int] = [:]
        var next = 1
        var turns: [SpeakerTurn] = []
        turns.reserveCapacity(segments.count)
        for seg in segments {
            let id = seg.speakerId
            guard !id.isEmpty else { continue }
            let idx: Int
            if let existing = indexFor[id] {
                idx = existing
            } else {
                idx = next
                indexFor[id] = next
                next += 1
            }
            turns.append(SpeakerTurn(
                speakerIndex: idx,
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds)
            ))
        }
        return turns
    }

    /// Decode an audio file at `url` into 16 kHz mono Float32 samples via
    /// AVFoundation. Handles arbitrary input sample rates / channel counts by
    /// converting through `AVAudioConverter`. Used by the WAV-URL overload.
    nonisolated static func readMono16k(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DiarizationError.audioReadFailed(error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: requiredSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw DiarizationError.audioReadFailed("Could not create 16 kHz mono format")
        }

        // Fast path: already 16 kHz mono Float32 — read straight through.
        if abs(srcFormat.sampleRate - requiredSampleRate) < 1,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32 {
            return try readAllFloat(file: file, format: srcFormat)
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw DiarizationError.audioReadFailed("Could not create audio converter")
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw DiarizationError.audioReadFailed("Could not allocate input buffer")
        }
        do {
            try file.read(into: inBuf)
        } catch {
            throw DiarizationError.audioReadFailed(error.localizedDescription)
        }

        let ratio = requiredSampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(ceil(Double(inBuf.frameLength) * ratio)) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
            throw DiarizationError.audioReadFailed("Could not allocate output buffer")
        }

        var convError: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let convError {
            throw DiarizationError.audioReadFailed("Resample failed: \(convError.localizedDescription)")
        }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    /// Read an entire (already mono Float32) file into a `[Float]`.
    private nonisolated static func readAllFloat(
        file: AVAudioFile,
        format: AVAudioFormat
    ) throws -> [Float] {
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw DiarizationError.audioReadFailed("Could not allocate read buffer")
        }
        do {
            try file.read(into: buf)
        } catch {
            throw DiarizationError.audioReadFailed(error.localizedDescription)
        }
        guard let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }
}
