import ArgumentParser
import Foundation
import VoicelyCore

// MARK: - voicely mcp
//
// A stdio MCP (Model Context Protocol) server, in pure Swift, with no Node. Any
// harness (Claude Code, Codex, …) launches `voicely mcp` as a subprocess and
// speaks JSON-RPC 2.0 to it, gaining four tools backed by Voicely's offline
// engine: transcribe_file, list_transcripts, get_transcript, get_last_call.
//
// Transport (MCP 2025-06-18, stdio):
//   • newline-delimited JSON-RPC 2.0 over stdin/stdout; one message per line,
//     no embedded newlines (we serialize compact, no .prettyPrinted);
//   • stdout is STRICTLY protocol — nothing but valid MCP messages;
//   • all logs/progress go to stderr (reuses logErr from Voicely.swift).
//
// Lifecycle handled: initialize → notifications/initialized → tools/list →
// tools/call → ping → shutdown. Notifications (no `id`) get no response.
//
// TranscribeJob.execute() is @MainActor (it loads the @MainActor Transcriber),
// so tool dispatch that runs it hops to the main actor; the read-only tools use
// the off-main TranscriptStore directly.

struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a stdio MCP server exposing Voicely's transcription tools to any agent."
    )

    /// Protocol revision we implement. If the client asks for a different one we
    /// still answer with ours (spec allows the server to pick a version it
    /// supports); modern clients down/up-negotiate from there.
    static let protocolVersion = "2025-06-18"

    func run() async throws {
        let server = MCPServer()
        try await server.serve()
    }
}

// MARK: - Server loop

/// Drives the blocking stdin read loop and routes each JSON-RPC message. Kept
/// as an actor-free struct: the loop is sequential (one request at a time, as a
/// stdio server is), and the only async hop is into @MainActor for transcription.
struct MCPServer {
    /// Read stdin line by line and answer on stdout until EOF (client closed the
    /// pipe → graceful shutdown). Blocking reads are fine: a stdio MCP server is
    /// single-client and request/response serial.
    func serve() async throws {
        logErr("Voicely MCP server ready (protocol \(Mcp.protocolVersion)). Reading JSON-RPC on stdin…")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }

            let message: JSONRPCMessage
            do {
                message = try JSONRPCMessage(data: data)
            } catch {
                // Couldn't even parse the envelope → Parse error, null id.
                write(JSONRPCResponse.error(id: .null, code: -32700, message: "Parse error"))
                continue
            }

            if let response = await handle(message) {
                write(response)
            }
            // No response → it was a notification (initialized, etc.).
        }
        logErr("stdin closed; Voicely MCP server shutting down.")
    }

    // MARK: - Routing

    /// Map one request/notification to an optional response. Returns nil for
    /// notifications (which, per JSON-RPC, get no reply).
    private func handle(_ message: JSONRPCMessage) async -> JSONRPCResponse? {
        // Notifications carry no id and never get a response.
        guard let id = message.id else {
            switch message.method {
            case "notifications/initialized", "initialized":
                logErr("Client initialized.")
            case "notifications/cancelled":
                break
            default:
                logErr("Ignoring notification: \(message.method ?? "<none>")")
            }
            return nil
        }

        switch message.method {
        case "initialize":
            return .result(id: id, result: Self.initializeResult())

        case "ping":
            // Spec: ping result is an empty object.
            return .result(id: id, result: .object([:]))

        case "tools/list":
            return .result(id: id, result: Self.toolsListResult())

        case "tools/call":
            return await handleToolsCall(id: id, params: message.params)

        case "shutdown":
            logErr("Received shutdown.")
            return .result(id: id, result: .object([:]))

        case .some(let m):
            return .error(id: id, code: -32601, message: "Method not found: \(m)")

        case .none:
            return .error(id: id, code: -32600, message: "Invalid Request: missing method")
        }
    }

    // MARK: - initialize / tools/list payloads

    private static func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(Mcp.protocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("voicely"),
                "version": .string(VoicelyCLIVersion.current),
            ]),
            "instructions": .string(
                "Offline transcription + diarization. Use transcribe_file to transcribe an "
                + "audio/video file, list_transcripts/get_transcript to read saved transcripts, "
                + "and get_last_call to read the most recent call transcript."
            ),
        ])
    }

    private static func toolsListResult() -> JSONValue {
        .object(["tools": .array(MCPTool.all.map { $0.descriptor })])
    }

    // MARK: - tools/call dispatch

    private func handleToolsCall(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        guard case let .object(obj)? = params,
              case let .string(name)? = obj["name"] else {
            return .error(id: id, code: -32602, message: "Invalid params: tools/call requires a tool name")
        }
        let arguments: [String: JSONValue]
        if case let .object(a)? = obj["arguments"] { arguments = a } else { arguments = [:] }

        guard let tool = MCPTool.all.first(where: { $0.name == name }) else {
            return .error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }

        do {
            let text = try await tool.run(arguments)
            return .result(id: id, result: Self.toolText(text, isError: false))
        } catch let error as ToolError {
            // Tool execution errors are reported in-band (isError: true), not as
            // protocol errors, so the model can read and react to them.
            return .result(id: id, result: Self.toolText(error.message, isError: true))
        } catch {
            return .result(id: id, result: Self.toolText("Tool failed: \(error.localizedDescription)", isError: true))
        }
    }

    /// Build a tools/call result with a single text content block.
    private static func toolText(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)]),
            ]),
            "isError": .bool(isError),
        ])
    }

    // MARK: - stdout writer

    /// Serialize one message compact (no embedded newlines) + a single trailing
    /// newline. This is the ONLY thing allowed on stdout.
    private func write(_ response: JSONRPCResponse) {
        let value = response.jsonValue
        guard let data = try? JSONValue.encode(value) else {
            logErr("Failed to serialize response.")
            return
        }
        var out = data
        out.append(0x0A)  // '\n'
        FileHandle.standardOutput.write(out)
    }
}

// MARK: - Tools

/// A tool execution error surfaced to the model as `isError: true` text content
/// (e.g. file not found, no such transcript) rather than a JSON-RPC error.
struct ToolError: Error {
    let message: String
}

/// One MCP tool: its name, description, input JSON Schema, and an async runner.
/// `descriptor` renders the tools/list entry; `run` performs the call.
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let run: @Sendable ([String: JSONValue]) async throws -> String

    var descriptor: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    /// The four tools exposed to agents, each reusing the existing CLI engine.
    static let all: [MCPTool] = [transcribeFile, listTranscripts, getTranscript, getLastCall]

    // MARK: transcribe_file

    private static let transcribeFile = MCPTool(
        name: "transcribe_file",
        description:
            "Transcribe an audio or video file offline using Voicely's WhisperKit engine. "
            + "Optionally run speaker diarization. Returns the transcript text "
            + "(speaker-labelled when diarize=true and speakers are detected).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the audio/video file to transcribe."),
                ]),
                "diarize": .object([
                    "type": .string("boolean"),
                    "description": .string("Run speaker diarization and label segments by speaker."),
                ]),
                "language": .object([
                    "type": .string("string"),
                    "enum": .array([.string("auto"), .string("ru"), .string("en")]),
                    "description": .string("Force a language, or 'auto' to detect (default: auto)."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ]),
        run: { args in
            guard case let .string(rawPath)? = args["path"], !rawPath.isEmpty else {
                throw ToolError(message: "transcribe_file requires a non-empty 'path'.")
            }
            let diarize: Bool = { if case let .bool(b)? = args["diarize"] { return b } else { return false } }()
            let forcedLanguage: String? = {
                if case let .string(lang)? = args["language"], lang != "auto" { return lang }
                return nil
            }()

            let fileURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ToolError(message: "File not found: \(fileURL.path)")
            }

            // TranscribeJob is @MainActor (loads the @MainActor Transcriber), so
            // run it on a @MainActor task and await its result here.
            let transcript = try await Task { @MainActor in
                let job = TranscribeJob(
                    fileURL: fileURL,
                    diarize: diarize,
                    forcedLanguage: forcedLanguage,
                    modelVariant: nil
                )
                let result = try await job.execute()
                // For diarized runs with detected speakers, return the labelled
                // dialogue; otherwise the plain transcript.
                if diarize, result.hasSpeakers {
                    return Transcribe.render(result, format: .txt, timestamps: false)
                }
                return result.transcript
            }.value

            return transcript.isEmpty ? "(no speech detected)" : transcript
        }
    )

    // MARK: list_transcripts

    private static let listTranscripts = MCPTool(
        name: "list_transcripts",
        description:
            "List saved Voicely transcripts (dictations, calls, files). Returns id, kind, "
            + "modified date, and a short text preview for each, newest first.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("dictations"), .string("calls"), .string("files")]),
                    "description": .string("Restrict to one kind. Omit to list all kinds."),
                ]),
            ]),
            "required": .array([]),
        ]),
        run: { args in
            let entries: [TranscriptEntry]
            if case let .string(kindToken)? = args["kind"] {
                guard let kind = TranscriptStore.kindFromToken(kindToken) else {
                    throw ToolError(message: "Unknown kind '\(kindToken)'. Use dictations | calls | files.")
                }
                entries = TranscriptStore.entries(of: kind)
            } else {
                entries = TranscriptStore.allEntries()
            }

            if entries.isEmpty {
                return "No transcripts found under \(TranscriptStore.baseDir.path)."
            }
            let iso = ISO8601DateFormatter()
            let lines = entries.map { e -> String in
                let preview = previewText(of: e.transcriptURL)
                return "\(e.kind.singular)\t\(e.id)\t\(iso.string(from: e.modified))\t\(preview)"
            }
            return lines.joined(separator: "\n")
        }
    )

    // MARK: get_transcript

    private static let getTranscript = MCPTool(
        name: "get_transcript",
        description:
            "Read a saved transcript by id. Accepts an exact id, or an alias like "
            + "'last', 'last-call', 'last-file', 'last-dictation'. Returns the full text.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Transcript id, or alias: last | last-call | last-file | last-dictation."),
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("dictations"), .string("calls"), .string("files")]),
                    "description": .string("Restrict resolution to one kind (optional)."),
                ]),
            ]),
            "required": .array([.string("id")]),
        ]),
        run: { args in
            guard case let .string(id)? = args["id"], !id.isEmpty else {
                throw ToolError(message: "get_transcript requires a non-empty 'id'.")
            }
            var kind: TranscriptKind? = nil
            if case let .string(kindToken)? = args["kind"] {
                guard let k = TranscriptStore.kindFromToken(kindToken) else {
                    throw ToolError(message: "Unknown kind '\(kindToken)'. Use dictations | calls | files.")
                }
                kind = k
            }
            guard let entry = TranscriptStore.resolve(idOrAlias: id, kind: kind) else {
                throw ToolError(message: "No transcript matching '\(id)'\(kind.map { " in \($0.rawValue)" } ?? "").")
            }
            return readTranscript(at: entry.transcriptURL)
        }
    )

    // MARK: get_last_call

    private static let getLastCall = MCPTool(
        name: "get_last_call",
        description:
            "Read the most recent call transcript ('show me the last call'). Returns the full text.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
        ]),
        run: { _ in
            guard let entry = TranscriptStore.resolve(idOrAlias: "last-call", kind: .calls) else {
                throw ToolError(message: "No call transcripts found under \(TranscriptStore.directory(for: .calls).path).")
            }
            return readTranscript(at: entry.transcriptURL)
        }
    )

    // MARK: - helpers

    private static func readTranscript(at url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.isEmpty ? "(empty transcript)" : text
    }

    /// First non-empty line, truncated, for list previews.
    private static func previewText(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 80 {
            return String(trimmed.prefix(80)) + "…"
        }
        return trimmed
    }
}
