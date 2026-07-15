import AVFoundation
import Foundation

/// One diarization-first system-channel ASR unit. `contentStart...contentEnd`
/// is the exact call-timeline span represented by the output. `audioStart...audioEnd`
/// may include bounded context for recognition, but never exceeds the ASR limit.
public struct CallSystemTranscriptionWindow: Sendable, Equatable {
    public let speakerID: Int?
    public let contentStart: Double
    public let contentEnd: Double
    public let audioStart: Double
    public let audioEnd: Double

    public init(
        speakerID: Int?,
        contentStart: Double,
        contentEnd: Double,
        audioStart: Double,
        audioEnd: Double
    ) {
        self.speakerID = speakerID
        self.contentStart = contentStart
        self.contentEnd = contentEnd
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }
}

public enum CallAudioProcessingError: Error, LocalizedError, Equatable {
    case invalidSampleRate(Double)
    case resamplingSetupFailed
    case resamplingFailed(String)
    case resamplingOutputMissing

    public var errorDescription: String? {
        switch self {
        case let .invalidSampleRate(rate):
            return "Invalid audio sample rate: \(rate)"
        case .resamplingSetupFailed:
            return "Could not configure audio resampling."
        case let .resamplingFailed(detail):
            return "Audio resampling failed. \(detail)"
        case .resamplingOutputMissing:
            return "Audio resampling returned no samples."
        }
    }
}

/// Pure audio helpers for the call pipeline.
///
/// Calls keep channel provenance as the source of truth: mic is always `.you`,
/// system audio is always `.other`. Diarization may split only the system
/// channel into remote `Speaker N` ids; it must never promote a mixed/remote
/// diarization cluster into `.you`.
///
/// Everything here is a PURE function of its inputs — no engine, model, or
/// actor state — so the speaker-attribution logic is unit-testable.
public enum CallAudioProcessing {

    /// The rate WhisperKit and FluidAudio both consume.
    public static let targetRate: Double = 16000
    public static let systemASRMaxWindowSeconds: Double = 30
    public static let systemASRContextPaddingSeconds: Double = 0.25
    public static let sameSpeakerMergeGapSeconds: Double = 0.20

    /// Resample mono Float32 to `toRate`. Returning source-rate samples as if they
    /// were 16 kHz corrupts every downstream timestamp, so conversion failures are
    /// explicit and callers can preserve the raw recording instead.
    public static func resampleMono(
        _ samples: [Float], fromRate: Double, toRate: Double = targetRate
    ) throws -> [Float] {
        if samples.isEmpty { return [] }
        guard fromRate.isFinite, fromRate > 0 else {
            throw CallAudioProcessingError.invalidSampleRate(fromRate)
        }
        guard toRate.isFinite, toRate > 0 else {
            throw CallAudioProcessingError.invalidSampleRate(toRate)
        }
        if abs(fromRate - toRate) < 1 { return samples }
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate,
                                      channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate,
                                      channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: src,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CallAudioProcessingError.resamplingSetupFailed }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        if let p = srcBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { if let b = $0.baseAddress { p.initialize(from: b, count: samples.count) } }
        }
        guard let conv = AVAudioConverter(from: src, to: dst) else {
            throw CallAudioProcessingError.resamplingSetupFailed
        }
        let outCap = AVAudioFrameCount(ceil(Double(samples.count) * toRate / fromRate)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCap) else {
            throw CallAudioProcessingError.resamplingSetupFailed
        }
        var err: NSError?
        let input = SingleBufferAudioConverterInput(srcBuf)
        conv.convert(to: dstBuf, error: &err) { _, status in
            input.provide(status: status)
        }
        if let err {
            throw CallAudioProcessingError.resamplingFailed(err.localizedDescription)
        }
        guard let d = dstBuf.floatChannelData?[0] else {
            throw CallAudioProcessingError.resamplingOutputMissing
        }
        return Array(UnsafeBufferPointer(start: d, count: Int(dstBuf.frameLength)))
    }

    /// Sum two mono channels into one, clamped to [-1, 1]. The shorter channel is
    /// treated as silence past its end, so the length is the LONGER of the two —
    /// neither the local nor the remote tail is dropped (the old two-channel path
    /// trimmed to the shorter channel and lost the rest).
    public static func mixSum(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let s = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
            out[i] = min(1, max(-1, s))
        }
        return out
    }

    // MARK: - Diarization-first system transcription

    /// Clamp turns to the available system-audio timeline, discard invalid spans,
    /// sort deterministically, and merge only adjacent turns from the same stable
    /// speaker. Different-speaker overlaps remain intact.
    public static func normalizeSystemTurns(
        _ turns: [SpeakerTurn],
        audioDuration: Double,
        mergeGapSeconds: Double = sameSpeakerMergeGapSeconds
    ) -> [SpeakerTurn] {
        guard audioDuration.isFinite, audioDuration > 0 else { return [] }
        let allowedGap = max(0, mergeGapSeconds)
        let sanitized = turns.compactMap { turn -> SpeakerTurn? in
            guard turn.speakerIndex > 0,
                  turn.start.isFinite,
                  turn.end.isFinite else { return nil }
            let start = min(audioDuration, max(0, turn.start))
            let end = min(audioDuration, max(0, turn.end))
            guard end > start else { return nil }
            return SpeakerTurn(
                speakerIndex: turn.speakerIndex,
                start: start,
                end: end
            )
        }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.speakerIndex < rhs.speakerIndex
        }

        var merged: [SpeakerTurn] = []
        merged.reserveCapacity(sanitized.count)
        for turn in sanitized {
            if let previous = merged.last,
               previous.speakerIndex == turn.speakerIndex,
               turn.start <= previous.end + allowedGap {
                merged[merged.count - 1] = SpeakerTurn(
                    speakerIndex: previous.speakerIndex,
                    start: previous.start,
                    end: max(previous.end, turn.end)
                )
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    /// Build speaker-stable ASR windows from diarization turns. The complement of
    /// the turn union is emitted as unlabeled windows, so diarization gaps and the
    /// head/tail of the recording are still transcribed. Different-speaker overlaps
    /// remain separate labeled windows. Every audio span is at most 30 seconds.
    ///
    /// An empty result means diarization produced no valid turns; callers must keep
    /// the existing unlabeled fixed-window fallback for the whole system channel.
    public static func systemTranscriptionWindows(
        turns: [SpeakerTurn],
        audioDuration: Double,
        maxWindowSeconds: Double = systemASRMaxWindowSeconds,
        contextPaddingSeconds: Double = systemASRContextPaddingSeconds
    ) -> [CallSystemTranscriptionWindow] {
        guard audioDuration.isFinite,
              audioDuration > 0,
              maxWindowSeconds.isFinite,
              maxWindowSeconds > 0 else { return [] }

        let normalized = normalizeSystemTurns(turns, audioDuration: audioDuration)
        guard !normalized.isEmpty else { return [] }

        struct Interval {
            let speakerID: Int?
            let start: Double
            let end: Double
            let turnIndex: Int?
        }

        var intervals = normalized.enumerated().map { index, turn in
            Interval(
                speakerID: turn.speakerIndex,
                start: turn.start,
                end: turn.end,
                turnIndex: index
            )
        }

        // Fill only the complement of the union. Overlapping turns stay in
        // `intervals`; the sweep prevents an overlap from manufacturing a gap.
        var coverageEnd = 0.0
        for turn in normalized {
            if turn.start > coverageEnd {
                intervals.append(Interval(
                    speakerID: nil,
                    start: coverageEnd,
                    end: turn.start,
                    turnIndex: nil
                ))
            }
            coverageEnd = max(coverageEnd, turn.end)
        }
        if coverageEnd < audioDuration {
            intervals.append(Interval(
                speakerID: nil,
                start: coverageEnd,
                end: audioDuration,
                turnIndex: nil
            ))
        }

        intervals.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return (lhs.speakerID ?? Int.max) < (rhs.speakerID ?? Int.max)
        }

        let requestedPadding = max(0, contextPaddingSeconds)
        let padding = min(requestedPadding, maxWindowSeconds / 4)
        let maxContentDuration = maxWindowSeconds - (2 * padding)
        guard maxContentDuration > 0 else { return [] }

        var windows: [CallSystemTranscriptionWindow] = []
        for interval in intervals {
            var leftContextLimit = interval.start
            var rightContextLimit = interval.end

            if let turnIndex = interval.turnIndex {
                leftContextLimit = max(0, interval.start - padding)
                rightContextLimit = min(audioDuration, interval.end + padding)

                for (otherIndex, other) in normalized.enumerated() where otherIndex != turnIndex {
                    if other.start < interval.start, other.end > leftContextLimit {
                        leftContextLimit = max(
                            leftContextLimit,
                            min(interval.start, other.end)
                        )
                    }
                    if other.end > interval.end, other.start < rightContextLimit {
                        rightContextLimit = min(
                            rightContextLimit,
                            max(interval.end, other.start)
                        )
                    }
                }
            }

            var contentStart = interval.start
            while contentStart < interval.end {
                let contentEnd = min(interval.end, contentStart + maxContentDuration)
                let audioStart = max(leftContextLimit, contentStart - padding)
                let audioEnd = min(rightContextLimit, contentEnd + padding)
                windows.append(CallSystemTranscriptionWindow(
                    speakerID: interval.speakerID,
                    contentStart: contentStart,
                    contentEnd: contentEnd,
                    audioStart: audioStart,
                    audioEnd: audioEnd
                ))
                contentStart = contentEnd
            }
        }

        windows.sort { lhs, rhs in
            if lhs.contentStart != rhs.contentStart {
                return lhs.contentStart < rhs.contentStart
            }
            if lhs.contentEnd != rhs.contentEnd {
                return lhs.contentEnd < rhs.contentEnd
            }
            if lhs.speakerID != rhs.speakerID {
                return (lhs.speakerID ?? Int.max) < (rhs.speakerID ?? Int.max)
            }
            if lhs.audioStart != rhs.audioStart { return lhs.audioStart < rhs.audioStart }
            return lhs.audioEnd < rhs.audioEnd
        }
        return windows
    }

    /// Crop padded ASR output back to a window's exact call-timeline core and
    /// stamp the diarizer's stable speaker id. Text never influences assignment.
    public static func systemSegments(
        from transcribed: [DialogueSegment],
        in window: CallSystemTranscriptionWindow
    ) -> [DialogueSegment] {
        transcribed.compactMap { segment in
            let start = max(window.contentStart, segment.start)
            let end = min(window.contentEnd, segment.end)
            guard end > start else { return nil }
            return DialogueSegment(
                speaker: .other,
                start: start,
                end: end,
                text: segment.text,
                language: segment.language,
                speakerID: window.speakerID
            )
        }
    }

    /// Assemble a call transcript using channel provenance as truth.
    ///
    /// - Mic segments are normalized to `.you` and any diarization id is cleared.
    /// - System segments are normalized to `.other`, stamped with diarization
    ///   turns from the system channel only, then merged with mic by timestamp.
    ///
    /// This is the regression guard for the call speaker bug: remote/system text
    /// must never become "You" just because a system diarization turn overlaps
    /// the mic timeline or because the mic contains remote bleed.
    public static func assembleCallTranscript(
        mic: [DialogueSegment],
        system: [DialogueSegment],
        systemTurns: [SpeakerTurn]
    ) -> [DialogueSegment] {
        let micTruth = mic.map { seg in
            DialogueSegment(
                speaker: .you,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                language: seg.language,
                speakerID: nil
            )
        }
        let systemTruth = system.map { seg in
            DialogueSegment(
                speaker: .other,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                language: seg.language,
                speakerID: seg.speakerID
            )
        }
        let stampedSystem = systemTurns.isEmpty
            ? systemTruth
            : DiarizationService.assignSpeakers(to: systemTruth, turns: systemTurns)
        return CallTranscriptMerger.merge(mic: micTruth, system: stampedSystem)
    }

    /// Most common detected language in already-transcribed call segments.
    /// Used to stabilize sparse mic speech: the remote/system channel usually
    /// has much more speech than the local mic channel, so its language is a
    /// better call-level prior than a quiet first mic window.
    public static func dominantLanguage(in segments: [DialogueSegment]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for segment in segments {
            guard let language = segment.language?.lowercased(), !language.isEmpty else { continue }
            if counts[language] == nil { order.append(language) }
            counts[language, default: 0] += 1
        }
        return order.max { lhs, rhs in
            let lhsOrder = order.firstIndex(of: lhs) ?? Int.max
            let rhsOrder = order.firstIndex(of: rhs) ?? Int.max
            return (counts[lhs, default: 0], -lhsOrder) < (counts[rhs, default: 0], -rhsOrder)
        }
    }

    /// Language override for mic transcription in call mode.
    ///
    /// In Auto mode, the mic channel can be sparse: a quiet/noisy first window
    /// may latch English, and later Russian phrases get decoded as English
    /// (`"Там какое-то мороженое есть" -> "There's some ice cream"`). When the
    /// system channel has a detected dominant language, force the mic channel to
    /// that language. Explicit user language and Translate-to-English modes keep
    /// their existing behavior.
    public static func micLanguageOverride(
        preferredLanguage: String?,
        translateToEnglish: Bool,
        system: [DialogueSegment]
    ) -> String? {
        guard preferredLanguage == nil, !translateToEnglish else { return nil }
        return dominantLanguage(in: system)
    }

    /// Voice-activity intervals (seconds) in a mono channel: windows whose RMS
    /// clears `threshold` are "speech", and adjacent speech windows merge into one
    /// interval. Run on the CLEAN mic channel to find when the local user spoke.
    public static func voiceIntervals(
        _ samples: [Float], rate: Double = targetRate,
        windowSec: Double = 0.1, threshold: Float = 0.02
    ) -> [(start: Double, end: Double)] {
        guard !samples.isEmpty, rate > 0 else { return [] }
        let win = max(1, Int(windowSec * rate))
        var intervals: [(start: Double, end: Double)] = []
        var i = 0
        var runStart: Int? = nil
        while i < samples.count {
            let end = min(i + win, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let rms = (end > i) ? (sum / Float(end - i)).squareRoot() : 0
            if rms >= threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                intervals.append((Double(s) / rate, Double(i) / rate))
                runStart = nil
            }
            i = end
        }
        if let s = runStart {
            intervals.append((Double(s) / rate, Double(samples.count) / rate))
        }
        return intervals
    }

    /// Identify the diarized speaker who is the local user ("You"): the one whose
    /// turns overlap the mic's voice intervals the most. Returns nil when the mic
    /// was silent or no turn overlaps any mic speech — then nobody is "You" and
    /// every remote turn renders as "Speaker N".
    @available(*, deprecated, message: "Do not use for calls: channel provenance is truth; diarize only system audio.")
    public static func detectYouSpeaker(
        micIntervals: [(start: Double, end: Double)], turns: [SpeakerTurn]
    ) -> Int? {
        guard !micIntervals.isEmpty, !turns.isEmpty else { return nil }
        var overlapBy: [Int: Double] = [:]
        for turn in turns {
            for mi in micIntervals {
                let lo = max(turn.start, mi.start)
                let hi = min(turn.end, mi.end)
                if hi > lo { overlapBy[turn.speakerIndex, default: 0] += (hi - lo) }
            }
        }
        // Tie-break on the lower speaker index for determinism.
        return overlapBy.max { ($0.value, -Double($1.key)) < ($1.value, -Double($0.key)) }?.key
    }

    /// Relabel diarized segments for a call. The `youIndex` speaker becomes
    /// `.you`; every other speaker stays `.other` and is renumbered 1..M by order
    /// of first appearance, so the "You" slot doesn't leave a gap in the Speaker
    /// numbering. A segment with no diarization id (no overlapping turn) stays an
    /// unnumbered `.other` ("Other"). Order-preserving.
    @available(*, deprecated, message: "Do not use for calls: system diarization must not promote a remote speaker to You.")
    public static func labelCallSpeakers(
        _ segments: [DialogueSegment], youIndex: Int?
    ) -> [DialogueSegment] {
        var renumber: [Int: Int] = [:]
        var next = 1
        return segments.map { seg in
            if let id = seg.speakerID, id == youIndex {
                return DialogueSegment(speaker: .you, start: seg.start, end: seg.end,
                                       text: seg.text, language: seg.language, speakerID: nil)
            }
            guard let id = seg.speakerID else {
                return DialogueSegment(speaker: .other, start: seg.start, end: seg.end,
                                       text: seg.text, language: seg.language, speakerID: nil)
            }
            let newId: Int
            if let r = renumber[id] { newId = r } else { newId = next; renumber[id] = next; next += 1 }
            return DialogueSegment(speaker: .other, start: seg.start, end: seg.end,
                                   text: seg.text, language: seg.language, speakerID: newId)
        }
    }
}
