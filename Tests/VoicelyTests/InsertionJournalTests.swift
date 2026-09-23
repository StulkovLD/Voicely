import XCTest
@testable import Voicely

/// One JSON line per dictation, private to the user, never the words.
final class InsertionJournalTests: XCTestCase {
    func testLineIsValidJSONWithNilFieldsOmitted() throws {
        let line = InsertionJournal.line([
            ("app", .string("com.microsoft.VSCode")),
            ("app_name", .string("Code \"Insiders\"\n")),
            ("owner", .string(nil)),
            ("channel", .string("paste")),
            ("receipt_ms", .int(34)),
            ("mods_wait_ms", .int(nil)),
            ("restored", .bool(true)),
        ], at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(line.hasSuffix("}\n"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "com.microsoft.VSCode")
        XCTAssertEqual(object["app_name"] as? String, "Code \"Insiders\"\n")
        XCTAssertEqual(object["receipt_ms"] as? Int, 34)
        XCTAssertEqual(object["restored"] as? Bool, true)
        XCTAssertNil(object["owner"])
        XCTAssertNil(object["mods_wait_ms"])
        XCTAssertNotNil(object["ts"])
    }

    func testFileIsPrivateAppendOnlyAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("insertion.jsonl").path
        let journal = InsertionJournal(path: path, maxBytes: 300, mirrorsToUnifiedLog: false)
        for index in 0..<3 {
            journal.append([("n", .int(index)), ("channel", .string("typing"))])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        for _ in 0..<10 { journal.append([("channel", .string("paste"))]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"), "grows past the cap → rotated")
    }

    /// The dictation's words have no field to go into: the line of a real
    /// delivery carries the length, never the text.
    @MainActor
    func testJournalLineOfADictationCarriesLengthNotText() throws {
        let secret = "мой секретный текст диктовки"
        let line = JournalLine(text: secret, front: nil)
        line.decision = "deliver"
        line.finish(channel: "paste", outcome: "delivered")
        let text = InsertionJournal.line(line.fields, at: Date())
        XCTAssertFalse(text.contains("секрет"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["len"] as? Int, secret.count)
        XCTAssertEqual(object["channel"] as? String, "paste")
        XCTAssertEqual(object["outcome"] as? String, "delivered")
    }
}
