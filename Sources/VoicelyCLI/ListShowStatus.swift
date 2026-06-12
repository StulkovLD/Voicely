import ArgumentParser
import Foundation
import VoicelyCore

// MARK: - voicely list [dictations|calls|files]

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved transcripts (dictations, calls, files)."
    )

    @Argument(help: "Which kind to list: dictations | calls | files (default: all).")
    var kind: String?

    @Flag(name: .long, help: "Emit JSON instead of a table.")
    var json = false

    func run() throws {
        let entries: [TranscriptEntry]
        if let kind {
            guard let k = TranscriptStore.kindFromToken(kind) else {
                throw ValidationError("Unknown kind '\(kind)'. Use dictations | calls | files.")
            }
            entries = TranscriptStore.entries(of: k)
        } else {
            entries = TranscriptStore.allEntries()
        }

        if json {
            emit(Self.jsonForEntries(entries))
            return
        }

        guard !entries.isEmpty else {
            logErr("No transcripts found under \(TranscriptStore.baseDir.path)")
            return
        }
        let iso = ISO8601DateFormatter()
        for e in entries {
            emitLine("\(e.kind.singular)\t\(e.id)\t\(iso.string(from: e.modified))")
        }
    }

    static func jsonForEntries(_ entries: [TranscriptEntry]) -> String {
        let iso = ISO8601DateFormatter()
        let array: [[String: Any]] = entries.map { e in
            [
                "kind": e.kind.singular,
                "id": e.id,
                "path": e.transcriptURL.path,
                "modified": iso.string(from: e.modified),
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: array, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "[]\n" }
        return s + "\n"
    }
}

// MARK: - voicely show <id|last> [--call|--dictation|--file]

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a transcript by id, or the newest with `last` / `last-call`."
    )

    @Argument(help: "Transcript id, or `last` / `last-call` / `last-file` / `last-dictation`.")
    var id: String

    @Flag(name: .long, help: "Restrict to calls.")
    var call = false

    @Flag(name: .long, help: "Restrict to dictations.")
    var dictation = false

    @Flag(name: .long, help: "Restrict to files.")
    var file = false

    func run() throws {
        let kind: TranscriptKind?
        switch (call, dictation, file) {
        case (true, false, false): kind = .calls
        case (false, true, false): kind = .dictations
        case (false, false, true): kind = .files
        case (false, false, false): kind = nil
        default:
            throw ValidationError("Use at most one of --call / --dictation / --file.")
        }

        guard let entry = TranscriptStore.resolve(idOrAlias: id, kind: kind) else {
            throw ValidationError("No transcript matching '\(id)'\(kind.map { " in \($0.rawValue)" } ?? "").")
        }

        let text = (try? String(contentsOf: entry.transcriptURL, encoding: .utf8)) ?? ""
        emit(text.hasSuffix("\n") ? text : text + "\n")
    }
}

// MARK: - voicely status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show model state, transcript paths, and version."
    )

    @Flag(name: .long, help: "Emit JSON instead of a table.")
    var json = false

    func run() throws {
        let recommended = WhisperModel.recommended()
        let modelOnDisk = FileManager.default.fileExists(atPath: recommended.modelDirectoryPath)
        let ramGB = WhisperModel.systemRAMGB

        if json {
            let obj: [String: Any] = [
                "version": VoicelyCLIVersion.current,
                "recommendedModel": recommended.variant,
                "recommendedModelName": recommended.displayName,
                "modelDownloaded": modelOnDisk,
                "systemRAMGB": ramGB,
                "paths": [
                    "base": TranscriptStore.baseDir.path,
                    "dictations": TranscriptStore.directory(for: .dictations).path,
                    "calls": TranscriptStore.directory(for: .calls).path,
                    "files": TranscriptStore.directory(for: .files).path,
                ],
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: data, encoding: .utf8) {
                emitLine(s)
            }
            return
        }

        emitLine("voicely \(VoicelyCLIVersion.current)")
        emitLine("Recommended model: \(recommended.displayName) (\(recommended.variant)) — \(recommended.sizeLabel)")
        emitLine("Model downloaded:  \(modelOnDisk ? "yes" : "no")")
        emitLine("System RAM:        \(ramGB) GB")
        emitLine("Transcripts:       \(TranscriptStore.baseDir.path)")
        emitLine("  dictations:      \(TranscriptStore.directory(for: .dictations).path)")
        emitLine("  calls:           \(TranscriptStore.directory(for: .calls).path)")
        emitLine("  files:           \(TranscriptStore.directory(for: .files).path)")
    }
}
