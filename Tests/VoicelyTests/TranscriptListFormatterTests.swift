import Foundation
import XCTest
@testable import VoicelyCLI

final class TranscriptListFormatterTests: XCTestCase {
    func testPreviewSkipsYamlFrontmatterAndReturnsBodyLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("transcript.md")
        try "---\ntype: dictation\ndate: 2026-07-06T00:00:00Z\n---\n\nReal body line\nSecond line\n".write(to: transcript, atomically: true, encoding: .utf8)

        XCTAssertEqual(TranscriptListFormatter.previewText(of: transcript), "Real body line")
    }

    func testRenderListDefaultsToCappedOutputWithTruncationNote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var entries: [TranscriptEntry] = []
        for idx in 0..<105 {
            let transcript = dir.appendingPathComponent("t-\(idx).md")
            try "---\nkind: dictation\n---\n\nBody \(idx)\n".write(to: transcript, atomically: true, encoding: .utf8)
            entries.append(TranscriptEntry(
                kind: .dictations,
                id: "id-\(idx)",
                transcriptURL: transcript,
                modified: Date(timeIntervalSince1970: Double(idx))
            ))
        }

        let rendered = TranscriptListFormatter.render(entries)
        let lines = rendered.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 101)
        XCTAssertTrue(lines[0].contains("dictation\tid-0"))
        XCTAssertEqual(lines.last, "… showing 100 of 105 transcripts; pass kind or limit to narrow the result.")
    }
}
