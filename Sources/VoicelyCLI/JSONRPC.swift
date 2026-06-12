import Foundation

// MARK: - JSON-RPC 2.0 over stdio (MCP)
//
// A minimal, dependency-free JSON value model + JSON-RPC envelope, built on
// Foundation only. We avoid `[String: Any]` so the whole thing is Sendable and
// the serializer emits compact, deterministic, single-line JSON (stdio MCP
// forbids embedded newlines in a message).

/// A JSON value. Covers everything we need to read requests and write responses
/// without reaching for `Any`. `Sendable` so it crosses actor boundaries cleanly.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Decoding (from JSONSerialization output)

    /// Bridge a `JSONSerialization`-decoded object graph into a `JSONValue`.
    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // NSNumber is the tricky one: distinguish Bool from numeric.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    // MARK: Encoding (to single-line UTF-8 JSON)

    /// Convert back to a `JSONSerialization`-friendly object graph.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationObject }
        case .object(let o): return o.mapValues { $0.foundationObject }
        }
    }

    /// Serialize compact (no pretty-printing → no embedded newlines), UTF-8.
    static func encode(_ value: JSONValue) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value.foundationObject,
            options: [.withoutEscapingSlashes]
        )
    }
}

// MARK: - JSON-RPC id

/// A JSON-RPC id: a string, a number, or null (used only on parse errors).
/// We preserve the client's original type so responses echo it faithfully.
enum JSONRPCID: Sendable, Equatable {
    case string(String)
    case int(Int)
    case null

    var jsonValue: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .int(let i): return .int(i)
        case .null: return .null
        }
    }

    init?(from value: JSONValue) {
        switch value {
        case .string(let s): self = .string(s)
        case .int(let i): self = .int(i)
        case .double(let d): self = .int(Int(d))
        default: return nil
        }
    }
}

// MARK: - Incoming message

/// A parsed JSON-RPC request or notification. `id == nil` ⇒ notification.
struct JSONRPCMessage: Sendable {
    let id: JSONRPCID?
    let method: String?
    let params: JSONValue?

    /// Parse one line of JSON into an envelope. Throws if it isn't valid JSON.
    init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let value = JSONValue(any: raw)
        guard case let .object(obj) = value else {
            throw JSONRPCParseError.notAnObject
        }
        self.id = obj["id"].flatMap(JSONRPCID.init(from:))
        if case let .string(m)? = obj["method"] { self.method = m } else { self.method = nil }
        self.params = obj["params"]
    }
}

enum JSONRPCParseError: Error {
    case notAnObject
}

// MARK: - Outgoing response

/// A JSON-RPC response: either a `result` or an `error`, tagged with the id it
/// answers. Built only via the factory methods so the envelope is always valid.
struct JSONRPCResponse: Sendable {
    let id: JSONRPCID
    private let payload: Payload

    private enum Payload: Sendable {
        case result(JSONValue)
        case error(code: Int, message: String)
    }

    static func result(id: JSONRPCID, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, payload: .result(result))
    }

    static func error(id: JSONRPCID, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, payload: .error(code: code, message: message))
    }

    private init(id: JSONRPCID, payload: Payload) {
        self.id = id
        self.payload = payload
    }

    /// The full wire object: `{ "jsonrpc": "2.0", "id": …, "result"|"error": … }`.
    var jsonValue: JSONValue {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
        ]
        switch payload {
        case .result(let r):
            obj["result"] = r
        case .error(let code, let message):
            obj["error"] = .object([
                "code": .int(code),
                "message": .string(message),
            ])
        }
        return .object(obj)
    }
}
