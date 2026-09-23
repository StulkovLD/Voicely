import Darwin
import Foundation
import OSLog

/// One line per dictation in `~/Library/Logs/Voicely/insertion.jsonl` and the
/// same line in the unified log {subsystem art.voicely.app, category
/// insertion} — in release builds too. It says where the text went and how,
/// never what the text was: the words stay in `~/Documents/Voicely`.
///
///     tail -n 5 ~/Library/Logs/Voicely/insertion.jsonl
///     log show --last 15m --predicate 'subsystem == "art.voicely.app" AND category == "insertion"'
struct InsertionJournal: Sendable {
    enum Value: Equatable, Sendable {
        case string(String?)
        case int(Int?)
        case bool(Bool?)
    }

    let path: String?
    let maxBytes: Int
    let mirrorsToUnifiedLog: Bool

    static let standard = InsertionJournal(
        path: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Voicely/insertion.jsonl").path,
        maxBytes: 2_000_000,
        mirrorsToUnifiedLog: true
    )

    /// Discards every line; for code paths exercised by tests.
    static let disabled = InsertionJournal(path: nil, maxBytes: 0, mirrorsToUnifiedLog: false)

    private static let logger = Logger(subsystem: "art.voicely.app", category: "insertion")
    private static let lock = NSLock()

    func append(_ fields: [(String, Value)], at date: Date = Date()) {
        let line = Self.line(fields, at: date)
        if mirrorsToUnifiedLog {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.notice("\(trimmed, privacy: .public)")
        }
        guard let path else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        if stat(path, &status) == 0, Int(status.st_size) > maxBytes {
            let rotated = path + ".1"
            unlink(rotated)
            rename(path, rotated)
        }
        // One write per line: appends never interleave inside a line.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// `{"ts":…, <fields in order>}\n`; nil values are omitted.
    static func line(_ fields: [(String, Value)], at date: Date) -> String {
        var parts = ["\"ts\":\(quote(timestamp(date)))"]
        for (key, value) in fields {
            switch value {
            case .string(let text?): parts.append("\(quote(key)):\(quote(text))")
            case .int(let number?): parts.append("\(quote(key)):\(number)")
            case .bool(let flag?): parts.append("\(quote(key)):\(flag ? "true" : "false")")
            case .string(nil), .int(nil), .bool(nil): continue
            }
        }
        return "{" + parts.joined(separator: ",") + "}\n"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
