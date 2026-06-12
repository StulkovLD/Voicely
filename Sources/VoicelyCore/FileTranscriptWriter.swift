import Foundation

/// Shared options for file transcription output. Lives in its own namespace
/// so both FileTranscriptionQueue (commit 3) and FileTranscriptWriter can
/// depend on it without circular references.
public struct FileTranscriptionOptions: Sendable, Equatable {
    public enum Content: String, Sendable { case plain; case timestamps }
    public enum Format: String, Sendable { case markdown; case plainText }
    public let content: Content
    public let format: Format
    /// When true, run a single global diarization pass over the whole file and
    /// prefix each segment with "Speaker N:" plus a legend. Trailing with a
    /// default so existing initializers and call sites stay source-compatible
    /// and `diarize == false` reproduces the old byte-for-byte output.
    public var diarize: Bool = false

    public init(content: Content, format: Format, diarize: Bool = false) {
        self.content = content
        self.format = format
        self.diarize = diarize
    }
}

public enum FileTranscriptWriterError: Error, LocalizedError {
    case centralWriteFailed(String)
    case nextToSourceWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .centralWriteFailed(let detail):
            return "Could not save transcript to central folder: \(detail)"
        case .nextToSourceWriteFailed(let detail):
            return "Could not save transcript next to source: \(detail)"
        }
    }
}

public struct FileTranscriptWriter {

    public struct Input: Sendable {
        public let sourceURL: URL
        public let transcript: String            // joined text across all chunks
        public let segments: [WhisperSegment]    // absolute offsets to full file
        public let options: FileTranscriptionOptions
        public let language: String?             // detected by WhisperKit
        public let modelName: String
        /// Speaker-stamped segments (one per `WhisperSegment`, same order and
        /// timeline) produced by a global diarization pass. Non-nil only when
        /// `options.diarize` was requested AND diarization succeeded; when it is
        /// nil the writer renders exactly as before. Trailing-defaulted so all
        /// existing initializers and tests stay source-compatible.
        public var diarizedSegments: [DialogueSegment]? = nil

        public init(
            sourceURL: URL,
            transcript: String,
            segments: [WhisperSegment],
            options: FileTranscriptionOptions,
            language: String?,
            modelName: String,
            diarizedSegments: [DialogueSegment]? = nil
        ) {
            self.sourceURL = sourceURL
            self.transcript = transcript
            self.segments = segments
            self.options = options
            self.language = language
            self.modelName = modelName
            self.diarizedSegments = diarizedSegments
        }
    }

    public struct Result: Sendable {
        public let nextToSourceURL: URL?  // nil if user skipped during error dialog
        public let centralURL: URL
    }

    /// Writes transcript next to source + to central folder.
    ///
    /// - Parameters:
    ///   - input: what to write
    ///   - centralRoot: the root of the central folder (tests pass a temp dir;
    ///                  production uses ~/Documents/Voicely/files)
    ///   - onNextToSourceFailure: closure invoked when the next-to-source write
    ///                            fails. Return a replacement URL (from an
    ///                            NSSavePanel, for example) or nil to skip.
    /// - Throws: `FileTranscriptWriterError.centralWriteFailed` if the central
    ///           folder write fails (queue should pause on that).
    public static func write(
        input: Input,
        centralRoot: URL,
        onNextToSourceFailure: @Sendable @escaping (URL, Error) async -> URL?
    ) async throws -> Result {

        // --- 1. Build content strings
        let mainText = renderMainDocument(input: input)
        let srtText: String? = (input.options.content == .timestamps)
            ? renderSRT(segments: input.segments)
            : nil

        // --- 2. Central folder (this is REQUIRED — throw if it fails)
        let centralURL = try writeCentralFolder(
            input: input,
            centralRoot: centralRoot,
            mainText: mainText,
            srtText: srtText
        )

        // --- 3. Next-to-source (optional — fall back to callback on error)
        let nextToSourceURL = await writeNextToSourceWithFallback(
            input: input,
            mainText: mainText,
            srtText: srtText,
            onFailure: onNextToSourceFailure
        )

        return Result(nextToSourceURL: nextToSourceURL, centralURL: centralURL)
    }

    // MARK: - Rendering

    private static func renderMainDocument(input: Input) -> String {
        // Diarized rendering: only when a global pass actually stamped speakers.
        // `diarize == false` (or a pass that found no overlap) falls through to
        // the original, byte-identical output below.
        if let diar = input.diarizedSegments, hasSpeakerLabels(diar) {
            return renderDiarizedDocument(input: input, segments: diar)
        }
        switch (input.options.content, input.options.format) {
        case (.plain, .markdown):
            return frontmatter(input) + "\n" + input.transcript + "\n"
        case (.plain, .plainText):
            return input.transcript + "\n"
        case (.timestamps, .markdown):
            let body = input.segments.map { seg in
                "- [\(formatMMSS(seg.start)) → \(formatMMSS(seg.end))] \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n")
            return frontmatter(input) + "\n" + body + "\n"
        case (.timestamps, .plainText):
            let body = input.segments.map { seg in
                "[\(formatMMSS(seg.start)) → \(formatMMSS(seg.end))] \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n")
            return body + "\n"
        }
    }

    // MARK: - Diarized rendering

    /// True when at least one segment carries a diarization `speakerID`. Without
    /// any stamped speaker there is nothing to label, so we keep the plain path.
    private static func hasSpeakerLabels(_ segments: [DialogueSegment]) -> Bool {
        segments.contains { $0.speakerID != nil }
    }

    /// "Speaker N" for a stamped segment, "Speaker ?" for an un-overlapped one.
    /// File transcription has no local "You" channel (that is call-only), so the
    /// only labels here are numbered remote speakers.
    private static func speakerLabel(for segment: DialogueSegment) -> String {
        if let id = segment.speakerID { return "Speaker \(id)" }
        return "Speaker ?"
    }

    /// Distinct speaker indices present, ascending.
    private static func detectedSpeakerIDs(in segments: [DialogueSegment]) -> [Int] {
        var seen = Set<Int>()
        for s in segments { if let id = s.speakerID { seen.insert(id) } }
        return seen.sorted()
    }

    /// Legend listing how many speakers were detected, so a reader can map the
    /// "Speaker N:" prefixes below. Empty when nothing was stamped.
    private static func diarizationLegend(for segments: [DialogueSegment]) -> String {
        let ids = detectedSpeakerIDs(in: segments)
        guard !ids.isEmpty else { return "" }
        var lines: [String] = []
        lines.append("Speakers detected: \(ids.count)")
        for id in ids {
            lines.append("- Speaker \(id)")
        }
        return lines.joined(separator: "\n")
    }

    /// Render the document with "Speaker N:" prefixes and a leading legend.
    /// Markdown variants keep the frontmatter; plain-text variants do not, in
    /// step with the non-diarized formats.
    private static func renderDiarizedDocument(
        input: Input,
        segments: [DialogueSegment]
    ) -> String {
        let legend = diarizationLegend(for: segments)
        let showTimestamps = (input.options.content == .timestamps)

        let body = segments.map { seg -> String in
            let label = speakerLabel(for: seg)
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if showTimestamps {
                return "[\(formatMMSS(seg.start)) → \(formatMMSS(seg.end))] \(label): \(text)"
            }
            return "\(label): \(text)"
        }.joined(separator: "\n")

        let labelledBody = legend.isEmpty ? body : (legend + "\n\n" + body)

        switch input.options.format {
        case .markdown:
            return frontmatter(input) + "\n" + labelledBody + "\n"
        case .plainText:
            return labelledBody + "\n"
        }
    }

    private static func frontmatter(_ input: Input) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        let lang = input.language ?? "unknown"
        return """
        ---
        type: file-transcription
        source: \(input.sourceURL.path)
        date: \(iso)
        language: \(lang)
        model: \(input.modelName)
        ---
        """
    }

    private static func renderSRT(segments: [WhisperSegment]) -> String {
        var lines: [String] = []
        for (i, seg) in segments.enumerated() {
            lines.append("\(i + 1)")
            lines.append("\(formatSRT(seg.start)) --> \(formatSRT(seg.end))")
            lines.append(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// "MM:SS" used in inline markdown/text
    private static func formatMMSS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "HH:MM:SS,mmm" per SRT spec
    private static func formatSRT(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total / 3600)
        let minutes = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let secs = Int(total.truncatingRemainder(dividingBy: 60))
        let millis = Int(((total - total.rounded(.down)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    // MARK: - Central folder

    private static func writeCentralFolder(
        input: Input,
        centralRoot: URL,
        mainText: String,
        srtText: String?
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: centralRoot, withIntermediateDirectories: true)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        let baseName = sanitize(input.sourceURL.deletingPathExtension().lastPathComponent)
        let folderURL = resolveCentralFolder(
            parent: centralRoot, base: baseName)
        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: false)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        let ext = (input.options.format == .markdown) ? "md" : "txt"
        let mainURL = folderURL.appendingPathComponent("transcript").appendingPathExtension(ext)
        do {
            try mainText.write(to: mainURL, atomically: true, encoding: .utf8)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        if let srt = srtText {
            let srtURL = folderURL.appendingPathComponent("transcript.srt")
            do {
                try srt.write(to: srtURL, atomically: true, encoding: .utf8)
            } catch {
                throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
            }
        }

        return mainURL
    }

    /// Returns the first unused folder URL in the form
    /// `parent/base`, then `parent/base-2`, `parent/base-3`, ...
    private static func resolveCentralFolder(parent: URL, base: String) -> URL {
        let first = parent.appendingPathComponent(base)
        if !FileManager.default.fileExists(atPath: first.path) {
            return first
        }
        var i = 2
        while true {
            let candidate = parent.appendingPathComponent("\(base)-\(i)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }

    /// Replaces characters outside `[A-Za-z0-9 _.-]` with underscore.
    /// Trims whitespace. Falls back to "untitled".
    static func sanitize(_ input: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.-")
        var out = String(input.map { allowed.contains($0) ? $0 : "_" })
        out = out.trimmingCharacters(in: .whitespaces)
        if out.isEmpty || out.allSatisfy({ $0 == "." }) {
            return "untitled"
        }
        return out
    }

    // MARK: - Next-to-source

    private static func writeNextToSourceWithFallback(
        input: Input,
        mainText: String,
        srtText: String?,
        onFailure: @Sendable @escaping (URL, Error) async -> URL?
    ) async -> URL? {
        let ext = (input.options.format == .markdown) ? "md" : "txt"
        let candidateURL = resolveNextToSourceURL(
            source: input.sourceURL, ext: ext)

        do {
            try mainText.write(to: candidateURL, atomically: true, encoding: .utf8)
            if let srt = srtText {
                let srtURL = candidateURL.deletingPathExtension()
                    .appendingPathExtension("srt")
                try srt.write(to: srtURL, atomically: true, encoding: .utf8)
            }
            return candidateURL
        } catch {
            // Ask the caller for a replacement destination.
            guard let replacement = await onFailure(candidateURL, error) else {
                return nil
            }
            do {
                try mainText.write(to: replacement, atomically: true, encoding: .utf8)
                if let srt = srtText {
                    let srtURL = replacement.deletingPathExtension()
                        .appendingPathExtension("srt")
                    try? srt.write(to: srtURL, atomically: true, encoding: .utf8)
                }
                return replacement
            } catch {
                return nil
            }
        }
    }

    /// `video.mp4` → `video.md` (or `video (2).md` if taken, `video (3).md` ...)
    private static func resolveNextToSourceURL(source: URL, ext: String) -> URL {
        let parent = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let first = parent.appendingPathComponent("\(base).\(ext)")
        if !FileManager.default.fileExists(atPath: first.path) {
            return first
        }
        var i = 2
        while true {
            let candidate = parent.appendingPathComponent("\(base) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }
}
