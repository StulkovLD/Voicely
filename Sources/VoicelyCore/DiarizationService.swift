import Foundation
@preconcurrency import FluidAudio

// MARK: - Diarization Service
//
// Thin wrapper over FluidAudio's `OfflineDiarizerManager` (Pyannote powerset
// segmentation + WeSpeaker embeddings + VBx clustering, running on CoreML /
// the Apple Neural Engine). Produces "who spoke when" speaker turns and maps
// them back onto ASR `DialogueSegment`s.
//
// This service is intentionally GENERIC: it knows nothing about `CallSpeaker`
// (you/other). N2b (calls) and N2c (file queue) are the only consumers; they
// read the per-segment `speakerID` it assigns. Speaker indices are 1-based and
// STABLE within a single `diarize(...)` pass (a global one-pass numbering keyed
// by first appearance of each FluidAudio speaker identity, so the index does
// not depend on FluidAudio's internal id string format).
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
    /// The provided audio file could not be read.
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

/// Narrow dependency used by file transcription. Production uses
/// `DiarizationService`; tests can verify URL routing without loading models.
public protocol FileDiarizing: Sendable {
    func diarize(fileURL: URL) async throws -> [SpeakerTurn]
}

/// FluidAudio does not annotate `OfflineDiarizerManager` as Sendable even
/// though its URL pipeline explicitly runs internal detached tasks over
/// read-only models. The box stays private to `DiarizationService`, whose actor
/// serializes prepare/process calls.
private final class OfflineDiarizerBox: @unchecked Sendable {
    private let manager = OfflineDiarizerManager()

    func prepareModels() async throws {
        try await manager.prepareModels()
    }

    func process(_ url: URL) async throws -> DiarizationResult {
        try await manager.process(url)
    }
}

/// Actor-isolated wrapper so FluidAudio's non-`Sendable` manager and its
/// downloaded models never cross an isolation boundary. All FluidAudio calls
/// run inside the actor; the inference itself is offloaded to the ANE by
/// FluidAudio, so holding the actor for the duration of a pass is acceptable.
public actor DiarizationService: FileDiarizing {
    /// FluidAudio's offline/VBx diarizer. Lazily created on first `diarize(...)`.
    private var offlineManager: OfflineDiarizerBox?

    /// Short gap tolerated when ASR and diarization land on slightly different
    /// boundaries. Segments still prefer real overlap first; this only rescues
    /// near-miss assignments that would otherwise render as `Speaker ?`.
    nonisolated static let nearestTurnTolerance: Double = 0.3

    public init() {}

    // MARK: - Lazy model init

    /// Download (first run) / load FluidAudio's diarization models and build the
    /// manager. Idempotent: once a manager exists this is a no-op. Models are
    /// fetched from FluidAudio's HuggingFace mirror on first use and cached on
    /// disk by FluidAudio for subsequent launches.
    private func ensureOfflineManager() async throws -> OfflineDiarizerBox {
        if let offlineManager { return offlineManager }
        let manager = OfflineDiarizerBox()
        do {
            try await manager.prepareModels()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
        offlineManager = manager
        return manager
    }

    // MARK: - Diarize (disk-backed source URL)

    /// Diarize an arbitrary AVFoundation-supported audio/video source without
    /// materializing its PCM in Voicely. FluidAudio's offline manager converts
    /// the source and serves inference windows through a memory-mapped backing.
    /// Every consumer (the calls' system channel, the file queue, the CLI)
    /// enters through this single overload.
    public func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        try Task.checkCancellation()
        let manager = try await ensureOfflineManager()

        let result: DiarizationResult
        do {
            result = try await manager.process(fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        return Self.makeStableTurns(from: result.segments)
    }

    // MARK: - Assign speakers to ASR segments

    /// Stamp each `DialogueSegment` with the `speakerIndex` of the `SpeakerTurn`
    /// it overlaps most (by intersection length on the `[start, end]` axis).
    /// When no overlap exists, borrow the nearest turn within a short boundary
    /// tolerance. Segments with no overlapping or near-enough turn keep
    /// `speakerID == nil`. Pure and order-preserving; safe to call off the actor.
    ///
    /// Both inputs must share the same timeline (seconds from the same origin).
    public nonisolated static func assignSpeakers(
        to segments: [DialogueSegment],
        turns: [SpeakerTurn]
    ) -> [DialogueSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            let speakerIndex = bestOverlappingSpeakerIndex(for: seg, turns: turns)
                ?? nearestSpeakerIndex(
                    for: seg,
                    turns: turns,
                    maxGap: nearestTurnTolerance)
            guard let speakerIndex else { return seg }
            var copy = seg
            copy.speakerID = speakerIndex
            return copy
        }
    }

    // MARK: - Internal helpers

    /// Map FluidAudio's opaque `speakerId` strings (e.g. "S1"/"S2") to 1-based
    /// indices by ORDER OF FIRST APPEARANCE across the segment list. This makes
    /// the numbering stable within one pass and independent of FluidAudio's
    /// id-string format. Segments are kept in their original chronological
    /// order. Empty `speakerId`s are skipped.
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

    /// Best overlapping speaker, if any, by greatest intersection length.
    /// Equal overlaps keep the earliest turn encountered, preserving the
    /// timeline order from diarization output.
    nonisolated static func bestOverlappingSpeakerIndex(
        for segment: DialogueSegment,
        turns: [SpeakerTurn]
    ) -> Int? {
        var best: (speakerIndex: Int, overlap: Double)? = nil
        for turn in turns {
            let lo = max(segment.start, turn.start)
            let hi = min(segment.end, turn.end)
            let overlap = hi - lo
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (turn.speakerIndex, overlap)
            }
        }
        return best?.speakerIndex
    }

    /// Nearest speaker turn within `maxGap` when strict overlap found nothing.
    /// Ties break deterministically by earlier turn start, then earlier turn end,
    /// then lower speaker index.
    nonisolated static func nearestSpeakerIndex(
        for segment: DialogueSegment,
        turns: [SpeakerTurn],
        maxGap: Double
    ) -> Int? {
        var best: (speakerIndex: Int, gap: Double, start: Double, end: Double)? = nil
        for turn in turns {
            let gap = gapBetween(segment: segment, and: turn)
            guard gap <= maxGap else { continue }
            if best == nil
                || gap < best!.gap
                || (gap == best!.gap && turn.start < best!.start)
                || (gap == best!.gap && turn.start == best!.start && turn.end < best!.end)
                || (gap == best!.gap && turn.start == best!.start
                    && turn.end == best!.end && turn.speakerIndex < best!.speakerIndex)
            {
                best = (turn.speakerIndex, gap, turn.start, turn.end)
            }
        }
        return best?.speakerIndex
    }

    /// Positive distance between two non-overlapping intervals on the same
    /// timeline. Touching boundaries have gap 0 and are eligible for the
    /// nearest-turn rescue path.
    nonisolated static func gapBetween(
        segment: DialogueSegment,
        and turn: SpeakerTurn
    ) -> Double {
        if segment.end <= turn.start {
            return turn.start - segment.end
        }
        if turn.end <= segment.start {
            return segment.start - turn.end
        }
        return 0
    }
}
