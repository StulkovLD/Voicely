import ArgumentParser
import Foundation

// MARK: - `voicely connect`
//
// Turnkey agent wiring. Voicely's `mcp` server speaks standard stdio MCP, so it
// works with any MCP-capable harness — the only per-harness difference is how a
// server gets registered. This subcommand delegates that to each harness's OWN
// `mcp add` command (so the harness writes its own config in its own format —
// no risk of us corrupting a TOML/YAML/JSON file we don't own), detecting which
// harnesses are installed and skipping the rest.
//
// `voicely setup` and the website installer call `connect` with no arguments, so
// a fresh install registers Voicely in every agent the user already has.

/// One supported harness and how to (re)register an MCP server with its CLI.
struct HarnessSpec: Sendable {
    let id: String
    let cliBinary: String
    /// Best-effort removal first so a re-run updates the path instead of erroring
    /// on a duplicate. `nil` when the CLI has no remove verb (add overwrites).
    let removeCommand: (@Sendable (_ cli: String, _ name: String) -> [String])?
    let addCommand: @Sendable (_ cli: String, _ name: String, _ voicely: String) -> [String]
    /// Some CLIs prompt interactively (Hermes: "Save config anyway? [y/N]" with a
    /// default of N). Feed this to stdin to auto-confirm. nil = no input.
    let stdinInput: String?
    /// Confirm the server is ACTUALLY registered (not just exit 0): returns true
    /// if `name` shows up in the harness's real config / `mcp list`. The exit code
    /// alone lies (Hermes exits 0 after declining to save).
    let verify: @Sendable (_ cli: String, _ name: String) -> Bool
}

enum HarnessRegistry {
    static let serverName = "voicely"

    /// Verify via the harness's own `mcp list` output containing the name.
    private static let listVerify: @Sendable (_ cli: String, _ name: String) -> Bool = { cli, name in
        ProcessRunner.run([cli, "mcp", "list"]).output.range(of: name, options: .caseInsensitive) != nil
    }

    static let all: [HarnessSpec] = [
        HarnessSpec(
            id: "claude", cliBinary: "claude",
            removeCommand: { cli, n in [cli, "mcp", "remove", n] },
            addCommand: { cli, n, v in [cli, "mcp", "add", n, "--", v, "mcp"] },
            stdinInput: nil, verify: listVerify),
        HarnessSpec(
            id: "codex", cliBinary: "codex",
            removeCommand: { cli, n in [cli, "mcp", "remove", n] },
            addCommand: { cli, n, v in [cli, "mcp", "add", n, "--", v, "mcp"] },
            stdinInput: nil, verify: listVerify),
        HarnessSpec(
            id: "hermes", cliBinary: "hermes",
            removeCommand: { cli, n in [cli, "mcp", "remove", n] },
            addCommand: { cli, n, v in [cli, "mcp", "add", n, "--command", v, "--args", "mcp"] },
            // Hermes probes the server, fails to "connect" (our server exits on
            // stdin EOF — normal), then prompts "Save config anyway? [y/N]"
            // (default N). Feed "y" so it saves; the config is valid and works in
            // real use.
            stdinInput: "y\n", verify: listVerify),
        HarnessSpec(
            id: "cursor", cliBinary: "cursor",
            removeCommand: nil,
            addCommand: { cli, n, v in
                [cli, "--add-mcp", "{\"name\":\"\(n)\",\"command\":\"\(v)\",\"args\":[\"mcp\"]}"]
            },
            // Cursor has no `mcp list`; it writes the server into its user
            // settings.json under Application Support.
            stdinInput: nil,
            verify: { _, name in
                let path = NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json"
                return (try? String(contentsOfFile: path, encoding: .utf8))?.contains(name) ?? false
            }),
        HarnessSpec(
            id: "openclaw", cliBinary: "openclaw",
            removeCommand: { cli, n in [cli, "mcp", "unset", n] },
            addCommand: { cli, n, v in [cli, "mcp", "set", n, "--command", v, "--args", "mcp"] },
            stdinInput: nil, verify: listVerify),
    ]

    struct Outcome { var connected: [String] = []; var skipped: [String] = []; var failed: [String] = [] }

    /// Register the `voicely mcp` server in each requested (or every installed)
    /// harness. `voicelyPath` is the absolute path the harness will launch.
    static func connect(_ wanted: [String], voicelyPath: String) -> Outcome {
        let targets = wanted.isEmpty ? all : all.filter { wanted.contains($0.id) }
        var out = Outcome()
        for h in targets {
            guard let cli = ProcessRunner.which(h.cliBinary) else {
                emitLine("• \(h.id): not installed — skipped")
                out.skipped.append(h.id); continue
            }
            if let remove = h.removeCommand {
                _ = ProcessRunner.run(remove(cli, serverName))  // best-effort; ignore result
            }
            let argv = h.addCommand(cli, serverName, voicelyPath)
            let result = ProcessRunner.run(argv, stdin: h.stdinInput)
            // Trust the harness's real config, NOT the exit code (Hermes exits 0
            // even when it declined to save).
            if h.verify(cli, serverName) {
                emitLine("✓ \(h.id): connected")
                out.connected.append(h.id)
            } else {
                let msg = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                emitLine("! \(h.id): not registered (exit \(result.code)) — \(msg.prefix(160))")
                emitLine("  run manually: \(argv.joined(separator: " "))")
                out.failed.append(h.id)
            }
        }
        return out
    }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Register Voicely's MCP server in your agent harness(es) — turnkey."
    )

    @Argument(help: "Harnesses to connect: claude, codex, cursor, hermes, openclaw. Omit to connect every installed one.")
    var harnesses: [String] = []

    func run() throws {
        let known = Set(HarnessRegistry.all.map(\.id))
        let unknown = harnesses.filter { !known.contains($0) }
        if !unknown.isEmpty {
            logErr("Unknown harness(es): \(unknown.joined(separator: ", ")). Known: \(known.sorted().joined(separator: ", "))")
            throw ExitCode.failure
        }
        let voicely = Setup.currentExecutablePath()
        emitLine("Connecting Voicely (\(voicely)) to \(harnesses.isEmpty ? "every installed harness" : harnesses.joined(separator: ", "))…")
        let out = HarnessRegistry.connect(harnesses, voicelyPath: voicely)
        emitLine("\nConnected: \(out.connected.isEmpty ? "none" : out.connected.joined(separator: ", "))" +
                 (out.skipped.isEmpty ? "" : " · skipped (not installed): \(out.skipped.joined(separator: ", "))") +
                 (out.failed.isEmpty ? "" : " · failed: \(out.failed.joined(separator: ", "))"))
        if !out.connected.isEmpty {
            emitLine("Restart your agent so it picks up the 'voicely' tools (transcribe_file, get_last_call, …).")
        }
    }
}

// MARK: - Process helpers

enum ProcessRunner {
    /// First match for `binary` on PATH, or nil. Avoids depending on `/usr/bin/which`.
    static func which(_ binary: String) -> String? {
        if binary.contains("/") { return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run argv, capturing merged stdout+stderr. Optionally feed `stdin` (e.g.
    /// "y\n" to auto-confirm an interactive prompt). Returns (exitCode, output).
    static func run(_ argv: [String], stdin: String? = nil) -> (code: Int32, output: String) {
        guard let first = argv.first else { return (1, "empty command") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: first)
        proc.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inPipe = Pipe()
        if stdin != nil { proc.standardInput = inPipe }
        do {
            try proc.run()
            if let stdin, let data = stdin.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (127, error.localizedDescription)
        }
    }
}
