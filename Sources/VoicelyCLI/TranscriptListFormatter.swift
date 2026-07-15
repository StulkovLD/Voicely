import Foundation

struct TranscriptListFormatter {
    static let defaultLimit = 100

    static func render(_ entries: [TranscriptEntry], limit: Int? = nil) -> String {
        guard !entries.isEmpty else {
            return "No transcripts found under \(TranscriptStore.baseDir.path)."
        }

        let effectiveLimit = max(1, min(limit ?? defaultLimit, entries.count))
        let iso = ISO8601DateFormatter()
        var lines = entries.prefix(effectiveLimit).map { entry in
            let preview = previewText(of: entry.transcriptURL)
            return "\(entry.kind.singular)\t\(entry.id)\t\(iso.string(from: entry.modified))\t\(preview)"
        }

        if effectiveLimit < entries.count {
            lines.append("… showing \(effectiveLimit) of \(entries.count) transcripts; pass kind or limit to narrow the result.")
        }

        return lines.joined(separator: "\n")
    }

    static func previewText(of url: URL, maxLength: Int = 80) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines)
        let contentLines = stripYAMLFrontmatterIfPresent(from: lines)
        let firstLine = contentLines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength)) + "…"
        }
        return trimmed
    }

    private static func stripYAMLFrontmatterIfPresent(from lines: [String]) -> [String] {
        guard let firstNonEmptyIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return lines
        }
        guard lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespaces) == "---" else {
            return Array(lines[firstNonEmptyIndex...])
        }
        guard let closingIndex = lines[(firstNonEmptyIndex + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return Array(lines[firstNonEmptyIndex...])
        }
        let bodyStart = lines.index(after: closingIndex)
        guard bodyStart < lines.endIndex else { return [] }
        return Array(lines[bodyStart...])
    }
}
