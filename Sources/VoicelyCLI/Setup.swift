import ArgumentParser
import Foundation

// MARK: - `voicely setup`
//
// Exposes the CLI on the user's PATH as `voicely` so an MCP harness (the
// Claude Code plugin's .mcp.json uses `command: "voicely"`) can launch it.
//
// Why a symlink and not just naming the SPM product `voicely`: on a
// case-insensitive APFS volume the lowercase `voicely` and the app binary
// `Voicely` collapse to one file, so the SPM product must stay `VoicelyCLI`.
// We bridge the gap by symlinking the real binary to `<bindir>/voicely`,
// where it lives in a directory that has no `Voicely` to collide with.

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install `voicely` on your PATH so agents/MCP can launch it."
    )

    @Flag(name: .long, help: "Remove the installed `voicely` symlink instead of creating it.")
    var uninstall = false

    @Option(name: .long, help: "Target directory for the symlink (default: first writable of /usr/local/bin, ~/.local/bin).")
    var dir: String?

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = dir.map { [$0] } ?? ["/usr/local/bin", "\(home)/.local/bin"]
        let fm = FileManager.default

        // Pick the first directory that exists-and-is-writable, or that we can create.
        var binDir: String?
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
                if fm.isWritableFile(atPath: c) { binDir = c; break }
            } else if (try? fm.createDirectory(atPath: c, withIntermediateDirectories: true)) != nil {
                binDir = c; break
            }
        }
        guard let binDir else {
            logErr("No writable bin directory among: \(candidates.joined(separator: ", "))")
            logErr("Re-run with --dir <path> pointing at a directory on your PATH.")
            throw ExitCode.failure
        }

        let linkPath = "\(binDir)/voicely"

        if uninstall {
            if fm.fileExists(atPath: linkPath) || isSymlink(linkPath) {
                try? fm.removeItem(atPath: linkPath)
                emitLine("Removed \(linkPath)")
            } else {
                emitLine("Nothing to remove at \(linkPath)")
            }
            return
        }

        let exe = Self.currentExecutablePath()
        // Replace any stale link/file at the target.
        if fm.fileExists(atPath: linkPath) || isSymlink(linkPath) {
            try? fm.removeItem(atPath: linkPath)
        }
        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: exe)
        } catch {
            logErr("Failed to link \(linkPath) -> \(exe): \(error.localizedDescription)")
            throw ExitCode.failure
        }

        emitLine("Installed: \(linkPath) -> \(exe)")
        // Warn if the chosen dir is unlikely to be on PATH.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(binDir)) {
            logErr("Note: \(binDir) is not on your PATH. Add it, e.g.:")
            logErr("  echo 'export PATH=\"\(binDir):$PATH\"' >> ~/.zshrc && source ~/.zshrc")
        }
        // Turnkey: register the MCP server in every agent harness the user has,
        // so `voicely setup` (and the website installer that calls it) wires up
        // Claude Code / Codex / Cursor / Hermes / OpenClaw in one shot.
        emitLine("\nConnecting installed agent harnesses…")
        let out = HarnessRegistry.connect([], voicelyPath: Self.currentExecutablePath())
        if out.connected.isEmpty && out.failed.isEmpty {
            emitLine("No agent harness detected. Install one, then run `voicely connect`.")
        } else {
            emitLine("Restart your agent(s) to pick up the 'voicely' tools.")
        }
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Absolute path to the running binary, resolving symlinks.
    static func currentExecutablePath() -> String {
        if let p = Bundle.main.executablePath {
            return (p as NSString).resolvingSymlinksInPath
        }
        let arg0 = CommandLine.arguments.first ?? "voicely"
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(arg0) as NSString).resolvingSymlinksInPath
    }
}
