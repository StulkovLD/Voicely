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

/// Serializes protocol responses so concurrent tool requests can never
/// interleave bytes on stdout.
private actor MCPResponseSink {
    func write(_ response: JSONRPCResponse) {
        let value = response.jsonValue
        guard let data = try? JSONValue.encode(value) else {
            logErr("Failed to serialize response.")
            return
        }
        var output = data
        output.append(0x0A)
        FileHandle.standardOutput.write(output)
    }
}

/// Owns in-flight JSON-RPC tasks. Cancellation removes the publication token
/// before cancelling the task, so a cancellation-ignoring backend still cannot
/// publish a stale result after `notifications/cancelled` or shutdown.
actor MCPRequestCoordinator {
    typealias Publisher = @Sendable (JSONRPCResponse) async -> Void
    static let defaultMaximumRequests = 32

    enum SubmissionResult: Equatable {
        case accepted
        case duplicateID
        case shuttingDown
        case serverBusy
    }

    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let publish: Publisher
    private let maximumRequests: Int
    private var entries: [JSONRPCID: Entry] = [:]
    private var acceptingRequests = true

    init(
        maximumRequests: Int = MCPRequestCoordinator.defaultMaximumRequests,
        publish: @escaping Publisher
    ) {
        self.maximumRequests = max(1, maximumRequests)
        self.publish = publish
    }

    func submit(
        id: JSONRPCID,
        operation: @Sendable @escaping () async -> JSONRPCResponse?
    ) -> SubmissionResult {
        guard acceptingRequests else { return .shuttingDown }
        guard entries[id] == nil else { return .duplicateID }
        guard entries.count < maximumRequests else { return .serverBusy }

        let token = UUID()
        // Detached by design: shutdown must not wait indefinitely for a model
        // backend that ignores cooperative cancellation. Publication remains
        // safe because cancel/shutdown removes this task's token first.
        let task = Task.detached { [weak self] in
            let response = await operation()
            await self?.complete(id: id, token: token, response: response)
        }
        entries[id] = Entry(token: token, task: task)
        return .accepted
    }

    @discardableResult
    func cancel(id: JSONRPCID) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.task.cancel()
        return true
    }

    func shutdown() {
        acceptingRequests = false
        // Cancel without stripping publication tokens: a fast request whose
        // response is already computed still publishes (its `complete` call is
        // queued on this actor ahead of us or lands right after). Measured on
        // stdin-EOF: initialize's ready answer was thrown away by the old
        // token-strip. A backend that ignores cancellation cannot hold exit
        // hostage either way — the process leaves when the read loop ends.
        for entry in entries.values { entry.task.cancel() }
    }

    var activeRequestCount: Int { entries.count }
    var isAcceptingRequests: Bool { acceptingRequests }

    private func complete(
        id: JSONRPCID,
        token: UUID,
        response: JSONRPCResponse?
    ) async {
        guard let entry = entries[id], entry.token == token else { return }
        entries.removeValue(forKey: id)
        // A computed response publishes even if shutdown has since cancelled
        // the task: the client asked, the answer exists. Explicit per-request
        // cancel(id:) removed the entry, so the guard above already covers it.
        guard let response else { return }
        await publish(response)
    }
}

/// Admission control for the memory-heavy `transcribe_file` path. One request
/// may decode/load/diarize, two more may wait, and the fourth is rejected before
/// any model or audio allocation begins. Read-only MCP requests bypass it.
actor MCPHeavyRequestAdmission {
    static let defaultMaximumQueued = 2

    struct Permit: Sendable, Equatable {
        fileprivate let token: UUID
    }

    enum AdmissionError: Error, Equatable {
        case serverBusy
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumQueued: Int
    private var activeToken: UUID?
    private var waiters: [Waiter] = []

    init(
        maximumQueued: Int = MCPHeavyRequestAdmission.defaultMaximumQueued
    ) {
        self.maximumQueued = max(0, maximumQueued)
    }

    func acquire() async throws -> Permit {
        try Task.checkCancellation()
        let token = UUID()

        if activeToken == nil {
            activeToken = token
            return Permit(token: token)
        }
        guard waiters.count < maximumQueued else {
            throw AdmissionError.serverBusy
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) -> Void in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(
                        token: token,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaitingOrActive(token: token) }
        }

        do {
            try Task.checkCancellation()
        } catch {
            // The waiter may have been promoted immediately before cancellation,
            // after the cancellation-handler scope ended. Release that freshly
            // acquired slot here so it cannot remain permanently occupied.
            if activeToken == token {
                promoteNext()
            }
            throw error
        }
        return Permit(token: token)
    }

    func release(_ permit: Permit) {
        guard activeToken == permit.token else { return }
        promoteNext()
    }

    var activeCount: Int { activeToken == nil ? 0 : 1 }
    var queuedCount: Int { waiters.count }

    private func cancelWaitingOrActive(token: UUID) {
        if activeToken == token {
            promoteNext()
            return
        }
        guard let index = waiters.firstIndex(where: { $0.token == token }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func promoteNext() {
        guard !waiters.isEmpty else {
            activeToken = nil
            return
        }
        let waiter = waiters.removeFirst()
        activeToken = waiter.token
        waiter.continuation.resume()
    }
}

/// Drives stdin and routes requests. Tool calls run concurrently with the read
/// loop so cancellation and shutdown messages remain observable while a long
/// transcription is in flight.
struct MCPServer {
    /// Read stdin line by line until EOF or an explicit shutdown request.
    func serve() async throws {
        logErr("Voicely MCP server ready (protocol \(Mcp.protocolVersion)). Reading JSON-RPC on stdin…")
        let sink = MCPResponseSink()
        let transcriptionRuntime = await MainActor.run {
            CLITranscriptionRuntime()
        }
        let coordinator = MCPRequestCoordinator { response in
            await sink.write(response)
        }
        let heavyAdmission = MCPHeavyRequestAdmission()

        // stdin is read on a dedicated thread. A blocking FileHandle.read
        // inside the concurrency world pinned the cooperative thread and —
        // measured live, 2026-08-19 — never surfaced bytes that arrived on an
        // open pipe: the server greeted, then sat deaf while Claude Code's
        // initialize timed out. A plain thread plus AsyncStream keeps the
        // actor world free and wakes on every frame.
        let frames = AsyncStream<JSONRPCFrameReader.Event> { continuation in
            Thread.detachNewThread {
                var reader = JSONRPCFrameReader(input: .standardInput)
                while let event = try? reader.nextFrame() {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        for await frame in frames {
            guard case let .frame(frameData) = frame else {
                await sink.write(.error(
                    id: .null,
                    code: -32600,
                    message: "Request too large"
                ))
                continue
            }
            guard let line = String(data: frameData, encoding: .utf8) else {
                await sink.write(.error(id: .null, code: -32700, message: "Parse error"))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }

            let message: JSONRPCMessage
            do {
                message = try JSONRPCMessage(data: data)
            } catch is JSONRPCParseError {
                await sink.write(.error(id: .null, code: -32600, message: "Invalid Request"))
                continue
            } catch {
                // Couldn't even parse the envelope → Parse error, null id.
                await sink.write(.error(id: .null, code: -32700, message: "Parse error"))
                continue
            }

            guard let id = message.id else {
                await handleNotification(message, coordinator: coordinator)
                continue
            }

            if message.method == "shutdown" {
                logErr("Received shutdown; cancelling in-flight requests.")
                await coordinator.shutdown()
                await sink.write(.result(id: id, result: .object([:])))
                return
            }

            let submission = await coordinator.submit(id: id) {
                await handle(
                    message,
                    runtime: transcriptionRuntime,
                    heavyAdmission: heavyAdmission
                )
            }
            switch submission {
            case .accepted:
                break
            case .duplicateID:
                await sink.write(.error(
                    id: id,
                    code: -32600,
                    message: "Duplicate request id"
                ))
            case .shuttingDown:
                await sink.write(.error(id: id, code: -32600, message: "Server is shutting down"))
            case .serverBusy:
                await sink.write(.error(id: id, code: -32000, message: "Server busy"))
            }
        }
        await coordinator.shutdown()
        logErr("stdin closed; Voicely MCP server shutting down.")
    }

    private func handleNotification(
        _ message: JSONRPCMessage,
        coordinator: MCPRequestCoordinator
    ) async {
        switch message.method {
        case "notifications/initialized", "initialized":
            logErr("Client initialized.")

        case "notifications/cancelled":
            guard let requestID = Self.cancelledRequestID(from: message.params) else {
                logErr("Ignoring malformed cancellation notification.")
                return
            }
            if await coordinator.cancel(id: requestID) {
                logErr("Cancelled request \(requestID.logDescription).")
            }

        default:
            logErr("Ignoring notification: \(message.method ?? "<none>")")
        }
    }

    static func cancelledRequestID(from params: JSONValue?) -> JSONRPCID? {
        guard case let .object(object)? = params,
              let value = object["requestId"] else {
            return nil
        }
        return JSONRPCID(from: value)
    }

    // MARK: - Routing

    /// Map one request/notification to an optional response. Returns nil for
    /// notifications (which, per JSON-RPC, get no reply).
    private func handle(
        _ message: JSONRPCMessage,
        runtime: CLITranscriptionRuntime,
        heavyAdmission: MCPHeavyRequestAdmission
    ) async -> JSONRPCResponse? {
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
            return await handleToolsCall(
                id: id,
                params: message.params,
                runtime: runtime,
                heavyAdmission: heavyAdmission
            )

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

    private func handleToolsCall(
        id: JSONRPCID,
        params: JSONValue?,
        runtime: CLITranscriptionRuntime,
        heavyAdmission: MCPHeavyRequestAdmission
    ) async -> JSONRPCResponse {
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
            let text = try await tool.run(arguments, runtime, heavyAdmission)
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
    let run: @Sendable (
        [String: JSONValue],
        CLITranscriptionRuntime,
        MCPHeavyRequestAdmission
    ) async throws -> String

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
        run: { args, runtime, heavyAdmission in
            guard case let .string(rawPath)? = args["path"], !rawPath.isEmpty else {
                throw ToolError(message: "transcribe_file requires a non-empty 'path'.")
            }
            let diarize: Bool = { if case let .bool(b)? = args["diarize"] { return b } else { return false } }()
            let forcedLanguage: String?
            switch args["language"] {
            case nil, .string("auto")?:
                forcedLanguage = nil
            case .string("ru")?:
                forcedLanguage = "ru"
            case .string("en")?:
                forcedLanguage = "en"
            case .string(let language)?:
                throw ToolError(message: "Unknown language '\(language)'. Use auto | ru | en.")
            default:
                throw ToolError(message: "language must be auto, ru, or en when provided.")
            }

            let fileURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ToolError(message: "File not found: \(fileURL.path)")
            }

            let permit: MCPHeavyRequestAdmission.Permit
            do {
                permit = try await heavyAdmission.acquire()
            } catch MCPHeavyRequestAdmission.AdmissionError.serverBusy {
                throw ToolError(message: "Server busy: one transcription is active and two are queued. Try again later.")
            }

            do {
                // Admission precedes model preparation, audio decoding, and
                // diarizer use. A direct actor hop stays in this request task.
                let transcript = try await renderTranscription(
                    fileURL: fileURL,
                    diarize: diarize,
                    forcedLanguage: forcedLanguage,
                    runtime: runtime
                )
                try Task.checkCancellation()
                await heavyAdmission.release(permit)
                return transcript.isEmpty ? "(no speech detected)" : transcript
            } catch {
                await heavyAdmission.release(permit)
                throw error
            }
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
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Optional max rows to return. Default 100."),
                ]),
            ]),
            "required": .array([]),
        ]),
        run: { args, _, _ in
            let entries: [TranscriptEntry]
            if case let .string(kindToken)? = args["kind"] {
                guard let kind = TranscriptStore.kindFromToken(kindToken) else {
                    throw ToolError(message: "Unknown kind '\(kindToken)'. Use dictations | calls | files.")
                }
                entries = TranscriptStore.entries(of: kind)
            } else {
                entries = TranscriptStore.allEntries()
            }

            let limit: Int?
            switch args["limit"] {
            case .int(let value)?:
                guard value >= 0 else {
                    throw ToolError(message: "limit must be a non-negative integer.")
                }
                limit = value
            case .double(let value)?:
                guard case let .int(exact)? = JSONRPCID(from: .double(value)),
                      exact >= 0 else {
                    throw ToolError(message: "limit must be a non-negative integer.")
                }
                limit = exact
            case nil:
                limit = nil
            default:
                throw ToolError(message: "limit must be an integer when provided.")
            }
            return TranscriptListFormatter.render(entries, limit: limit)
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
        run: { args, _, _ in
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
        run: { _, _, _ in
            guard let entry = TranscriptStore.resolve(idOrAlias: "last-call", kind: .calls) else {
                throw ToolError(message: "No call transcripts found under \(TranscriptStore.directory(for: .calls).path).")
            }
            return readTranscript(at: entry.transcriptURL)
        }
    )

    // MARK: - helpers

    @MainActor
    private static func renderTranscription(
        fileURL: URL,
        diarize: Bool,
        forcedLanguage: String?,
        runtime: CLITranscriptionRuntime
    ) async throws -> String {
        try Task.checkCancellation()
        let job = TranscribeJob(
            fileURL: fileURL,
            diarize: diarize,
            forcedLanguage: forcedLanguage,
            modelVariant: nil
        )
        let result = try await job.execute(runtime: runtime)
        try Task.checkCancellation()
        return Transcribe.render(result, format: .txt, timestamps: false)
    }

    private static func readTranscript(at url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.isEmpty ? "(empty transcript)" : text
    }
}
