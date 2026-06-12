import ArgumentParser
import Foundation

// MARK: - Root command
//
// `voicely` is the headless entry point an agent drives to use Voicely's
// transcription engine without the menu-bar UI. It loads the WhisperKit model
// itself (standalone, no daemon) and writes data to stdout, progress/logs to
// stderr.
//
// EXTENSION POINT (N3b): add new subcommands by appending the command type to
// `subcommands` below. N3b registers `Mcp.self` here to expose `voicely mcp`
// with a single-line edit — no other wiring needed.

@main
struct Voicely: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voicely",
        abstract: "Headless offline transcription + diarization for any agent.",
        version: VoicelyCLIVersion.current,
        subcommands: [
            Transcribe.self,
            List.self,
            Show.self,
            Status.self,
            Mcp.self,  // N3b: stdio MCP server (`voicely mcp`).
            Setup.self,  // install `voicely` on PATH for MCP harnesses.
        ],
        defaultSubcommand: nil
    )
}

/// Single source of truth for the CLI's reported version. Kept here so `voicely
/// --version` and `voicely status` agree.
enum VoicelyCLIVersion {
    static let current = "1.0.0"
}

// MARK: - stderr / stdout helpers
//
// Contract: data → stdout, progress/logs → stderr. An agent can pipe stdout
// straight into another tool while still seeing progress on the terminal.

/// Write a line to stderr (progress, status, diagnostics).
func logErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Write to stdout without a trailing newline (caller controls newlines).
func emit(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

/// Write a line to stdout (the actual transcript / list / status data).
func emitLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
