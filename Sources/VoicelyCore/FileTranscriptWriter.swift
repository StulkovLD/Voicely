import Darwin
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
    /// let `FileTranscriptWriter` render speaker sections when labels exist.
    /// Trailing-defaulted so existing initializers and call sites stay
    /// source-compatible, and non-diarized jobs still follow the same plain
    /// document-composition rule.
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

    private static let paragraphPauseThreshold: Double = 1.5
    private static let paragraphTargetCharacterCount = 280
    private static let paragraphHardCharacterLimit = 420
    private static let paragraphTargetSentenceCount = 3

    public struct Input: Sendable {
        public let sourceURL: URL
        public let transcript: String            // flat fallback when no segments survive
        public let segments: [WhisperSegment]    // absolute offsets to full file
        public let options: FileTranscriptionOptions
        public let language: String?             // detected by WhisperKit
        public let modelName: String
        /// Speaker-stamped segments (one per `WhisperSegment`, same order and
        /// timeline) produced by a global diarization pass. Non-nil only when
        /// `options.diarize` was requested AND diarization succeeded; when it is
        /// nil the writer falls back to the plain file-document composition rule.
        /// Trailing-defaulted so all existing initializers and tests stay
        /// source-compatible.
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

    /// User-facing file-transcript body renderer shared by the writer and the
    /// CLI stdout path. Keeps file transcripts document-shaped while leaving
    /// call transcript formatting under `CallTranscriptMerger` untouched.
    public static func renderBody(input: Input) -> String {
        // Diarized rendering: only when a global pass actually stamped speakers.
        // `diarize == false` (or a pass that found no overlap) falls through to
        // the plain document path below.
        if let diar = input.diarizedSegments, hasSpeakerLabels(diar) {
            return renderDiarizedBody(input: input, segments: diar)
        }

        switch input.options.content {
        case .plain:
            return renderPlainBody(segments: input.segments, fallbackTranscript: input.transcript)
        case .timestamps:
            return renderTimestampBody(segments: input.segments, format: input.options.format)
        }
    }

    private static func renderMainDocument(input: Input) -> String {
        let body = renderBody(input: input)
        switch input.options.format {
        case .markdown:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return frontmatter(input) + "\n"
            }
            return frontmatter(input) + "\n" + trimmed + "\n"
        case .plainText:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\n" : trimmed + "\n"
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

    /// Render diarized file transcripts as speaker sections with paragraph or
    /// timestamp bodies. This keeps the file path document-shaped instead of a
    /// transport log with repeated inline `Speaker N:` prefixes.
    private static func renderDiarizedBody(
        input: Input,
        segments: [DialogueSegment]
    ) -> String {
        let sections = speakerSections(from: segments)
        guard !sections.isEmpty else {
            return renderPlainBody(segments: input.segments, fallbackTranscript: input.transcript)
        }

        switch input.options.content {
        case .plain:
            return renderSpeakerSections(
                sections,
                format: input.options.format,
                body: { renderSectionParagraphBody($0) }
            )
        case .timestamps:
            return renderSpeakerSections(
                sections,
                format: input.options.format,
                body: { renderSectionTimestampBody($0, format: input.options.format) }
            )
        }
    }

    private struct TextSpan: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct SpeakerSection: Sendable {
        let label: String
        let spans: [TextSpan]
    }

    private static func renderPlainBody(
        segments: [WhisperSegment],
        fallbackTranscript: String
    ) -> String {
        let paragraphs = composeParagraphs(from: segments.map { TextSpan(start: $0.start, end: $0.end, text: $0.text) })
        if !paragraphs.isEmpty {
            return paragraphs.joined(separator: "\n\n")
        }
        return fallbackTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderTimestampBody(
        segments: [WhisperSegment],
        format: FileTranscriptionOptions.Format
    ) -> String {
        timestampLines(
            segments.map { TextSpan(start: $0.start, end: $0.end, text: $0.text) },
            format: format
        ).joined(separator: "\n")
    }

    private static func speakerSections(from segments: [DialogueSegment]) -> [SpeakerSection] {
        var sections: [SpeakerSection] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let label = speakerLabel(for: segment)
            let span = TextSpan(start: segment.start, end: segment.end, text: text)

            if let lastIndex = sections.indices.last, sections[lastIndex].label == label {
                sections[lastIndex] = SpeakerSection(
                    label: sections[lastIndex].label,
                    spans: sections[lastIndex].spans + [span]
                )
            } else {
                sections.append(SpeakerSection(label: label, spans: [span]))
            }
        }

        return sections
    }

    private static func renderSpeakerSections(
        _ sections: [SpeakerSection],
        format: FileTranscriptionOptions.Format,
        body: (SpeakerSection) -> String
    ) -> String {
        sections.compactMap { section in
            let renderedBody = body(section).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !renderedBody.isEmpty else { return nil }

            switch format {
            case .markdown:
                return "## \(section.label)\n\n\(renderedBody)"
            case .plainText:
                return "\(section.label)\n\n\(renderedBody)"
            }
        }.joined(separator: "\n\n")
    }

    private static func renderSectionParagraphBody(_ section: SpeakerSection) -> String {
        composeParagraphs(from: section.spans).joined(separator: "\n\n")
    }

    private static func renderSectionTimestampBody(
        _ section: SpeakerSection,
        format: FileTranscriptionOptions.Format
    ) -> String {
        timestampLines(section.spans, format: format).joined(separator: "\n")
    }

    private static func timestampLines(
        _ spans: [TextSpan],
        format: FileTranscriptionOptions.Format
    ) -> [String] {
        spans.compactMap { span in
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let line = "[\(formatMMSS(span.start)) → \(formatMMSS(span.end))] \(text)"
            switch format {
            case .markdown:
                return "- \(line)"
            case .plainText:
                return line
            }
        }
    }

    private static func composeParagraphs(from spans: [TextSpan]) -> [String] {
        let cleaned = spans.compactMap { span -> TextSpan? in
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextSpan(start: span.start, end: span.end, text: text)
        }

        guard !cleaned.isEmpty else { return [] }

        var paragraphs: [String] = []
        var currentTexts: [String] = []
        var currentCharacterCount = 0
        var currentSentenceCount = 0
        var previous: TextSpan? = nil

        func flushParagraph() {
            guard !currentTexts.isEmpty else { return }
            paragraphs.append(currentTexts.joined(separator: " "))
            currentTexts.removeAll(keepingCapacity: true)
            currentCharacterCount = 0
            currentSentenceCount = 0
        }

        for span in cleaned {
            if let previous,
               shouldBreakParagraph(
                after: previous,
                before: span,
                currentCharacterCount: currentCharacterCount,
                currentSentenceCount: currentSentenceCount
               ) {
                flushParagraph()
            }

            currentTexts.append(span.text)
            currentCharacterCount += span.text.count + (currentTexts.count > 1 ? 1 : 0)
            if endsSentence(span.text) {
                currentSentenceCount += 1
            }
            previous = span
        }

        flushParagraph()
        return paragraphs
    }

    private static func shouldBreakParagraph(
        after previous: TextSpan,
        before current: TextSpan,
        currentCharacterCount: Int,
        currentSentenceCount: Int
    ) -> Bool {
        let gap = max(0, current.start - previous.end)
        if gap >= paragraphPauseThreshold {
            return true
        }
        if currentCharacterCount >= paragraphHardCharacterLimit {
            return true
        }
        if endsSentence(previous.text) {
            if currentCharacterCount >= paragraphTargetCharacterCount {
                return true
            }
            if currentSentenceCount >= paragraphTargetSentenceCount {
                return true
            }
        }
        return false
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return ".!?…".unicodeScalars.contains(scalar)
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
        // Round the complete timestamp first so a value such as 59.9996 carries
        // into the next minute instead of producing the invalid `...,1000` form.
        let totalMilliseconds = Int((max(0, seconds) * 1_000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1_000) % 60
        let millis = totalMilliseconds % 1_000
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
            try setPrivateDirectoryPermissions(centralRoot)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        let baseName = sanitize(input.sourceURL.deletingPathExtension().lastPathComponent)
        let folderURL = resolveCentralFolder(
            parent: centralRoot, base: baseName)
        do {
            try FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: false)
            try setPrivateDirectoryPermissions(folderURL)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        let ext = (input.options.format == .markdown) ? "md" : "txt"
        let mainURL = folderURL.appendingPathComponent("transcript").appendingPathExtension(ext)
        do {
            try mainText.write(to: mainURL, atomically: true, encoding: .utf8)
            try setPrivateFilePermissions(mainURL)
        } catch {
            throw FileTranscriptWriterError.centralWriteFailed(error.localizedDescription)
        }

        if let srt = srtText {
            let srtURL = folderURL.appendingPathComponent("transcript.srt")
            do {
                try srt.write(to: srtURL, atomically: true, encoding: .utf8)
                try setPrivateFilePermissions(srtURL)
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

    /// Make a string safe as a single macOS path component WITHOUT destroying
    /// non-ASCII text. APFS stores names as UTF-8, so Cyrillic/Greek/CJK/emoji
    /// are perfectly valid filenames — only a few characters are actually
    /// path-hostile: the separator `/`, the legacy HFS separator `:` (Finder
    /// still swaps the two), NUL, and control characters. Everything else —
    /// letters and digits of any script, spaces, punctuation — is preserved.
    /// Trims whitespace; falls back to "untitled" when nothing usable remains.
    static func sanitize(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\u{0}").union(.controlCharacters)
        let underscore = Unicode.Scalar("_")
        var scalars = String.UnicodeScalarView()
        for s in input.unicodeScalars {
            scalars.append(forbidden.contains(s) ? underscore : s)
        }
        let out = String(scalars).trimmingCharacters(in: .whitespaces)
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
            return try writeAdjacentOutputSet(
                preferredMainURL: candidateURL,
                mainText: mainText,
                srtText: srtText
            )
        } catch {
            // Ask the caller for a replacement destination.
            guard let replacement = await onFailure(candidateURL, error) else {
                return nil
            }
            do {
                return try writeAdjacentOutputSet(
                    preferredMainURL: replacement,
                    mainText: mainText,
                    srtText: srtText
                )
            } catch {
                return nil
            }
        }
    }

    private struct PreparedAdjacentOutput {
        let fd: Int32
        let temporaryName: String
    }

    /// Publishes the primary transcript and optional SRT as one collision domain.
    /// Every payload is complete and synced in an owner-only sibling temporary
    /// file before any final path appears. `RENAME_EXCL` is the commit primitive:
    /// another writer can win a name, but no existing user file is ever replaced.
    private static func writeAdjacentOutputSet(
        preferredMainURL: URL,
        mainText: String,
        srtText: String?
    ) throws -> URL {
        let parent = preferredMainURL.deletingLastPathComponent()
        let mainExtension = preferredMainURL.pathExtension
        let base = mainExtension.isEmpty
            ? preferredMainURL.lastPathComponent
            : preferredMainURL.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base != ".", base != ".." else {
            throw FileTranscriptWriterError.nextToSourceWriteFailed(
                "invalid output basename"
            )
        }

        let parentFD = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentFD >= 0 else {
            throw posixError("open output directory")
        }
        defer { Darwin.close(parentFD) }

        var suffix = 1
        while true {
            let candidateBase = suffix == 1 ? base : "\(base) (\(suffix))"
            if let result = try attemptAdjacentOutputSet(
                parent: parent,
                parentFD: parentFD,
                candidateBase: candidateBase,
                mainExtension: mainExtension,
                mainText: mainText,
                srtText: srtText
            ) {
                return result
            }
            suffix += 1
        }
    }

    /// Returns nil only when another owner already holds one of the final names.
    private static func attemptAdjacentOutputSet(
        parent: URL,
        parentFD: Int32,
        candidateBase: String,
        mainExtension: String,
        mainText: String,
        srtText: String?
    ) throws -> URL? {
        let mainName = mainExtension.isEmpty
            ? candidateBase
            : "\(candidateBase).\(mainExtension)"
        let srtName = srtText == nil ? nil : "\(candidateBase).srt"
        guard srtName == nil || srtName != mainName else {
            throw FileTranscriptWriterError.nextToSourceWriteFailed(
                "primary output and SRT resolve to the same path"
            )
        }

        if try directoryEntryExists(parentFD: parentFD, name: mainName)
            || (try srtName.map {
                try directoryEntryExists(parentFD: parentFD, name: $0)
            } ?? false) {
            return nil
        }

        let payloads = [Data(mainText.utf8)] + (srtText.map { [Data($0.utf8)] } ?? [])
        let prepared = try prepareAdjacentOutputs(
            payloads,
            parentFD: parentFD
        )
        defer { cleanupPreparedOutputs(prepared, parentFD: parentFD) }

        guard try publishExclusive(
            prepared[0],
            finalName: mainName,
            parentFD: parentFD
        ) else {
            return nil
        }
        var published: [(PreparedAdjacentOutput, String)] = [(prepared[0], mainName)]

        if let srtName {
            guard try publishExclusive(
                prepared[1],
                finalName: srtName,
                parentFD: parentFD
            ) else {
                try rollbackPublishedOutputs(published, parentFD: parentFD)
                return nil
            }
            published.append((prepared[1], srtName))
        }

        guard fsync(parentFD) == 0 else {
            let error = posixError("sync adjacent transcript directory")
            try rollbackPublishedOutputs(published.reversed(), parentFD: parentFD)
            throw error
        }
        return parent.appendingPathComponent(mainName, isDirectory: false)
    }

    private static func prepareAdjacentOutputs(
        _ payloads: [Data],
        parentFD: Int32
    ) throws -> [PreparedAdjacentOutput] {
        var prepared: [PreparedAdjacentOutput] = []
        do {
            for payload in payloads {
                let name = ".voicely-\(UUID().uuidString.lowercased()).partial"
                let fd = openat(
                    parentFD,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard fd >= 0 else { throw posixError("create adjacent transcript staging") }
                let output = PreparedAdjacentOutput(fd: fd, temporaryName: name)
                prepared.append(output)
                try writeAll(payload, fd: fd)
                guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else {
                    throw posixError("sync adjacent transcript staging")
                }
            }
            return prepared
        } catch {
            cleanupPreparedOutputs(prepared, parentFD: parentFD)
            throw error
        }
    }

    private static func cleanupPreparedOutputs(
        _ prepared: [PreparedAdjacentOutput],
        parentFD: Int32
    ) {
        for output in prepared {
            _ = unlinkat(parentFD, output.temporaryName, 0)
            Darwin.close(output.fd)
        }
    }

    private static func publishExclusive(
        _ output: PreparedAdjacentOutput,
        finalName: String,
        parentFD: Int32
    ) throws -> Bool {
        let result = output.temporaryName.withCString { source in
            finalName.withCString { destination in
                renameatx_np(
                    parentFD,
                    source,
                    parentFD,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if result == 0 { return true }
        if errno == EEXIST || errno == ENOTEMPTY { return false }
        throw posixError("publish adjacent transcript")
    }

    private static func rollbackPublishedOutputs<S: Sequence>(
        _ outputs: S,
        parentFD: Int32
    ) throws where S.Element == (PreparedAdjacentOutput, String) {
        for (output, finalName) in outputs {
            var expected = stat()
            var current = stat()
            guard fstat(output.fd, &expected) == 0 else {
                throw posixError("inspect adjacent transcript staging")
            }
            let lookup = finalName.withCString {
                fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW)
            }
            if lookup != 0, errno == ENOENT { continue }
            guard lookup == 0 else {
                throw posixError("inspect published adjacent transcript")
            }
            guard current.st_dev == expected.st_dev,
                  current.st_ino == expected.st_ino else {
                // Another owner replaced the path after our publication. Never
                // unlink an inode that is no longer the one we created.
                continue
            }
            guard unlinkat(parentFD, finalName, 0) == 0 || errno == ENOENT else {
                throw posixError("roll back adjacent transcript")
            }
        }
        _ = fsync(parentFD)
    }

    private static func directoryEntryExists(
        parentFD: Int32,
        name: String
    ) throws -> Bool {
        var info = stat()
        let result = name.withCString {
            fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError("inspect adjacent transcript destination")
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw posixError("write adjacent transcript staging")
            }
            offset += count
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation): \(String(cString: strerror(code)))",
            ]
        )
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

    private static func setPrivateDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func setPrivateFilePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
