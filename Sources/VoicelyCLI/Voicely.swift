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
            Connect.self,  // register the MCP server in agent harnesses (turnkey).
        ],
        defaultSubcommand: nil
    )
}

/// The CLI's reported version (`voicely --version`, `voicely status`, and the MCP
/// `serverInfo.version`). The product has one version source — the app's
/// `Info.plist` (`CFBundleShortVersionString`):
/// - inside `Voicely.app/Contents/Helpers/voicely` the CLI reads it from the
///   enclosing bundle;
/// - anywhere else (the MCPB bundle's `server/voicely`, a bare `swift build`) it
///   reports `VoicelyBuildVersion.shortVersion`, which the `EmbedAppVersion`
///   build plugin generates from the same `Info.plist`.
enum VoicelyCLIVersion {
    static let current = resolve(executablePath: Setup.currentExecutablePath())

    /// `executablePath` must already have symlinks resolved (the PATH shim that
    /// `voicely setup` installs is a symlink into the app bundle).
    static func resolve(
        executablePath: String,
        builtVersion: String = VoicelyBuildVersion.shortVersion
    ) -> String {
        bundleVersion(executablePath: executablePath) ?? builtVersion
    }

    static func bundleVersion(executablePath: String) -> String? {
        let helpersDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let contentsDir = helpersDir.deletingLastPathComponent()
        guard contentsDir.lastPathComponent == "Contents",
              contentsDir.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contentsDir.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }
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
