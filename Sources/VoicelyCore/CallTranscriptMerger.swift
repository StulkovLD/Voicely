import Foundation

/// Merges mic and system dialogue segments into a single time-ordered
/// transcript, and renders both a human-readable and a JSONL form.
public enum CallTranscriptMerger {
    /// Stable merge by start time. Stable so that when two segments start
    /// at exactly the same offset (rare but possible on silence boundaries),
    /// their relative order is preserved rather than flipping nondeterministically.
    public static func merge(mic: [DialogueSegment], system: [DialogueSegment]) -> [DialogueSegment] {
        var combined = mic + system
        combined.sort { $0.start < $1.start }
        return combined
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
    /// (see `legend(for:)`).
    public static func humanFormat(segments: [DialogueSegment]) -> String {
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

    /// One JSON object per line. Fields:
    /// - t: start time in seconds (2-decimal rounded)
    /// - d: duration in seconds (2-decimal rounded)
    /// - speaker: "you" | "other"
    /// - speaker_id: 1-based diarization index (only present for diarized `.other`)
    /// - lang: detected language code (empty string if unknown)
    /// - text: transcript text for this segment
    public static func jsonlFormat(segments: [DialogueSegment]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(segments.count)
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

    private static func formatTimestamp(_ sec: Double) -> String {
        let s = Int(sec)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private static func roundedTwo(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }
}
