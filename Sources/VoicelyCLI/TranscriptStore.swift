import Foundation

// MARK: - Transcript store (read side)
//
// The on-disk transcript layout is Voicely's public data API:
//   ~/Documents/Voicely/dictations/<timestamp>-<rand>.md
//   ~/Documents/Voicely/calls/<id>/transcript.md         (+ transcript.jsonl, system.wav, mic.wav)
//   ~/Documents/Voicely/files/<name>/transcript.{md,txt} (+ transcript.srt)
//
// `list` / `show` read this tree. They intentionally do NOT depend on the
// @MainActor `TranscriptStorage` writer in VoicelyCore — reading is pure
// Foundation and must work off the main actor.

enum TranscriptKind: String, CaseIterable {
    case dictations
    case calls
    case files

    /// Singular spelling accepted on the `show --<kind>` flags / `list <kind>`.
    var singular: String {
        switch self {
        case .dictations: return "dictation"
        case .calls: return "call"
        case .files: return "file"
        }
    }
}

/// One discovered transcript on disk.
struct TranscriptEntry {
    let kind: TranscriptKind
    /// Stable id an agent passes to `voicely show <id>`. For dictations this is
    /// the file's basename (no extension); for calls/files it's the folder name.
    let id: String
    /// The transcript document to print (`.md` / `.txt`).
    let transcriptURL: URL
    /// Last-modified time, used to order lists and resolve `last`.
    let modified: Date
}

enum TranscriptStore {
    /// Root of the public transcript tree (`~/Documents/Voicely`). Matches
    /// `TranscriptStorage.baseDir` exactly so the CLI reads what the app writes.
    static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Voicely")
    }

    static func directory(for kind: TranscriptKind) -> URL {
        baseDir.appendingPathComponent(kind.rawValue)
    }

    /// All transcripts of a given kind, newest first.
    static func entries(of kind: TranscriptKind) -> [TranscriptEntry] {
        let fm = FileManager.default
        let dir = directory(for: kind)
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [TranscriptEntry] = []
        for url in contents {
            switch kind {
            case .dictations:
                // Flat .md files; the id is the basename.
                guard url.pathExtension.lowercased() == "md" else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                entries.append(TranscriptEntry(
                    kind: kind, id: id, transcriptURL: url,
                    modified: modificationDate(of: url)))
            case .calls, .files:
                // Folders containing transcript.{md,txt}.
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                guard let transcript = transcriptDocument(in: url) else { continue }
                entries.append(TranscriptEntry(
                    kind: kind, id: url.lastPathComponent, transcriptURL: transcript,
                    modified: modificationDate(of: transcript)))
            }
        }
        return entries.sorted { $0.modified > $1.modified }
    }

    /// All transcripts across every kind, newest first.
    static func allEntries() -> [TranscriptEntry] {
        TranscriptKind.allCases.flatMap { entries(of: $0) }
            .sorted { $0.modified > $1.modified }
    }

    /// Resolve a `voicely show` argument to a transcript.
    ///
    /// - `last` / `latest`            → newest across all kinds (or within `kind`).
    /// - `last-call` / `last-file` …  → newest of that kind.
    /// - any other string            → exact id match (optionally scoped by `kind`).
    static func resolve(idOrAlias: String, kind: TranscriptKind?) -> TranscriptEntry? {
        let lowered = idOrAlias.lowercased()

        // `last-<kind>` shorthand.
        if lowered.hasPrefix("last-") {
            let suffix = String(lowered.dropFirst("last-".count))
            if let k = kindFromToken(suffix) {
                return entries(of: k).first
            }
        }

        if lowered == "last" || lowered == "latest" {
            if let kind { return entries(of: kind).first }
            return allEntries().first
        }

        let pool = kind.map { entries(of: $0) } ?? allEntries()
        return pool.first { $0.id == idOrAlias }
    }

    /// Map "call"/"calls"/"dictation"/… to a `TranscriptKind`.
    static func kindFromToken(_ token: String) -> TranscriptKind? {
        let t = token.lowercased()
        for kind in TranscriptKind.allCases {
            if t == kind.rawValue || t == kind.singular { return kind }
        }
        return nil
    }

    // MARK: - Internals

    /// First existing `transcript.md` / `transcript.txt` in a call/file folder.
    private static func transcriptDocument(in folder: URL) -> URL? {
        let fm = FileManager.default
        for name in ["transcript.md", "transcript.txt"] {
            let candidate = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
