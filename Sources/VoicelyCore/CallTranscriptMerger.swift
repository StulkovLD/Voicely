import Foundation

public enum CallCaptureState: String, Sendable {
    case complete
    case partial
}

public struct CallTranscriptCaptureMetadata: Sendable, Equatable {
    public let state: CallCaptureState
    public let partialReason: String?
    /// Machine-readable backend/configuration failure detail. This remains
    /// separate from `partialReason`, whose value is the stable taxonomy key.
    public let interruptionReason: String?
    public let note: String?
    public let missingChannels: [String]
    public let systemMeanVolumeDBFS: Double?
    public let systemPeakVolumeDBFS: Double?
    public let micDurationSeconds: Double?
    public let systemDurationSeconds: Double?
    public let channelEndGapSeconds: Double?

    public init(
        state: CallCaptureState = .complete,
        partialReason: String? = nil,
        interruptionReason: String? = nil,
        note: String? = nil,
        missingChannels: [String] = [],
        systemMeanVolumeDBFS: Double? = nil,
        systemPeakVolumeDBFS: Double? = nil,
        micDurationSeconds: Double? = nil,
        systemDurationSeconds: Double? = nil,
        channelEndGapSeconds: Double? = nil
    ) {
        self.state = state
        self.partialReason = partialReason
        self.interruptionReason = interruptionReason
        self.note = note
        self.missingChannels = missingChannels
        self.systemMeanVolumeDBFS = systemMeanVolumeDBFS
        self.systemPeakVolumeDBFS = systemPeakVolumeDBFS
        self.micDurationSeconds = micDurationSeconds
        self.systemDurationSeconds = systemDurationSeconds
        self.channelEndGapSeconds = channelEndGapSeconds
    }

    public static let complete = Self()

    public var isPartial: Bool {
        state == .partial
    }
}

/// Merges mic and system dialogue segments into a single time-ordered
/// transcript, and renders both a human-readable and a JSONL form.
public enum CallTranscriptMerger {
    /// Stable merge by start time. Stable so that when two segments start
    /// at exactly the same offset (rare but possible on silence boundaries),
    /// mic/You sorts before system/Other and original channel order is retained.
    public static func merge(mic: [DialogueSegment], system: [DialogueSegment]) -> [DialogueSegment] {
        let tagged = mic.enumerated().map { (segment: $0.element, channel: 0, index: $0.offset) }
            + system.enumerated().map { (segment: $0.element, channel: 1, index: $0.offset) }
        return tagged.sorted { lhs, rhs in
            if lhs.segment.start != rhs.segment.start {
                return lhs.segment.start < rhs.segment.start
            }
            if lhs.channel != rhs.channel {
                return lhs.channel < rhs.channel
            }
            return lhs.index < rhs.index
        }.map(\.segment)
    }

    // MARK: - Speaker labels (call diarization, N2b)

    /// Human-readable label for one segment's speaker column.
    /// - `.you`  -> "You"  (the local user; never diarized).
    /// - `.other` with a diarization `speakerID` -> "Speaker N".
    /// - `.other` without an id (diarization off / failed / no overlap) -> "Other".
    ///
    /// Diarization separates the collapsed system channel (a whole conference in
    /// one stream) into distinct remote speakers; until it runs, every remote
    /// turn is just "Other".
    public static func speakerLabel(for segment: DialogueSegment) -> String {
        switch segment.speaker {
        case .you:
            return "You"
        case .other:
            if let id = segment.speakerID {
                return "Speaker \(id)"
            }
            return "Other"
        }
    }

    /// Distinct remote (`.other`) speaker indices present in the transcript,
    /// ascending. Empty when diarization didn't stamp any segment.
    public static func detectedSpeakerIDs(in segments: [DialogueSegment]) -> [Int] {
        var seen = Set<Int>()
        for s in segments where s.speaker == .other {
            if let id = s.speakerID { seen.insert(id) }
        }
        return seen.sorted()
    }

    /// Legend rendered at the top of the human transcript. Lists how many remote
    /// speakers diarization found plus the local user, so a reader can map the
    /// "Speaker N" / "You" labels below. Returns "" when no remote speaker was
    /// diarized (nothing to disambiguate — keeps the old plain format clean).
    public static func legend(for segments: [DialogueSegment]) -> String {
        let ids = detectedSpeakerIDs(in: segments)
        guard !ids.isEmpty else { return "" }
        var lines: [String] = []
        lines.append("Speakers detected: \(ids.count)")
        lines.append("- You: you (microphone)")
        for id in ids {
            lines.append("- Speaker \(id): remote participant")
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable markdown. Format: `[HH:MM:SS] speaker (lang): text`.
    /// Speaker column padded to a fixed width so lines align when scanned.
    /// When diarization stamped remote speakers, a legend block is prepended
    /// (see `legend(for:)`). Partial captures prepend an explicit honesty note.
    public static func humanFormat(segments: [DialogueSegment]) -> String {
        humanFormat(segments: segments, captureMetadata: .complete)
    }

    public static func humanFormat(
        segments: [DialogueSegment],
        captureMetadata: CallTranscriptCaptureMetadata
    ) -> String {
        let body = humanBody(segments: segments)
        guard captureMetadata.isPartial else { return body }
        let renderedBody = body.isEmpty ? "(No speech detected)" : body
        return partialCaptureBanner(for: captureMetadata) + "\n\n" + renderedBody
    }

    /// One JSON object per line. Fields:
    /// - t: start time in seconds (2-decimal rounded)
    /// - d: duration in seconds (2-decimal rounded)
    /// - speaker: "you" | "other"
    /// - speaker_id: 1-based diarization index (only present for diarized `.other`)
    /// - lang: detected language code (empty string if unknown)
    /// - text: transcript text for this segment
    ///
    /// Partial captures prepend a `type:"capture_meta"` object so the machine-
    /// readable transcript carries the same honesty signal as the human document.
    public static func jsonlFormat(segments: [DialogueSegment]) -> String {
        jsonlFormat(segments: segments, captureMetadata: .complete)
    }

    public static func jsonlFormat(
        segments: [DialogueSegment],
        captureMetadata: CallTranscriptCaptureMetadata
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(segments.count + (captureMetadata.isPartial ? 1 : 0))
        if captureMetadata.isPartial,
           let metadataLine = captureMetadataJSONLine(captureMetadata) {
            lines.append(metadataLine)
        }
        for s in segments {
            var obj: [String: Any] = [
                "t": roundedTwo(s.start),
                "d": roundedTwo(s.end - s.start),
                "speaker": s.speaker.rawValue,
                "lang": s.language ?? "",
                "text": s.text,
            ]
            if let id = s.speakerID {
                obj["speaker_id"] = id
            }
            if let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func humanBody(segments: [DialogueSegment]) -> String {
        // Width fits the widest label we render: "Speaker 10" (10 chars) while
        // still aligning the common "You"/"Other"/"Speaker 1" cases.
        let width = max(5, segments.map { speakerLabel(for: $0).count }.max() ?? 5)
        var lines: [String] = []
        for s in segments {
            let ts = formatTimestamp(s.start)
            let label = speakerLabel(for: s)
            let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
            let lang = s.language ?? "??"
            lines.append("[\(ts)] \(padded) (\(lang)): \(s.text)")
        }
        let body = lines.joined(separator: "\n")
        let legendText = legend(for: segments)
        guard !legendText.isEmpty else { return body }
        return legendText + "\n\n" + body
    }

    private static func partialCaptureBanner(
        for captureMetadata: CallTranscriptCaptureMetadata
    ) -> String {
        let trimmedNote = captureMetadata.note?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedNote.isEmpty {
            return "[Partial capture] \(trimmedNote)"
        }
        return "[Partial capture] One or more call channels were not captured cleanly, so this transcript may be incomplete."
    }

    private static func captureMetadataJSONLine(
        _ captureMetadata: CallTranscriptCaptureMetadata
    ) -> String? {
        var obj: [String: Any] = [
            "type": "capture_meta",
            "capture_state": captureMetadata.state.rawValue,
        ]
        if let reason = captureMetadata.partialReason,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obj["partial_reason"] = reason
        }
        if let interruptionReason = captureMetadata.interruptionReason,
           !interruptionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obj["interruption_reason"] = interruptionReason
        }
        if let note = captureMetadata.note,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obj["note"] = note
        }
        if !captureMetadata.missingChannels.isEmpty {
            obj["missing_channels"] = captureMetadata.missingChannels
        }
        if let mean = captureMetadata.systemMeanVolumeDBFS {
            obj["system_mean_dbfs"] = roundedTwo(mean)
        }
        if let peak = captureMetadata.systemPeakVolumeDBFS {
            obj["system_peak_dbfs"] = roundedTwo(peak)
        }
        if let duration = captureMetadata.micDurationSeconds {
            obj["mic_duration_seconds"] = roundedTwo(duration)
        }
        if let duration = captureMetadata.systemDurationSeconds {
            obj["system_duration_seconds"] = roundedTwo(duration)
        }
        if let gap = captureMetadata.channelEndGapSeconds {
            obj["channel_end_gap_seconds"] = roundedTwo(gap)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func formatTimestamp(_ sec: Double) -> String {
        let s = Int(sec)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private static func roundedTwo(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }
}
