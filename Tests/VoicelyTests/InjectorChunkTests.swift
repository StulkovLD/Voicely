import XCTest
@testable import Voicely

final class InjectorChunkTests: XCTestCase {
    func testPlainTextChunksAtMaxLength() {
        let chunks = Injector.utf16Chunks(of: "abcdefgh", maxLength: 3)
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) },
                       ["abc", "def", "gh"])
    }

    func testSurrogatePairIsNeverTorn() {
        // "a😀b": the emoji is one surrogate pair; a maxLength of 2 would cut
        // straight through it, so the chunk must stretch by one unit.
        let chunks = Injector.utf16Chunks(of: "a😀b", maxLength: 2)
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) },
                       ["a😀", "b"])
    }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertTrue(Injector.utf16Chunks(of: "", maxLength: 20).isEmpty)
    }

    func testCyrillicRoundTripsThroughChunks() {
        let text = "привет, мир — ёжик и §"
        let joined = Injector.utf16Chunks(of: text, maxLength: 5)
            .map { String(utf16CodeUnits: $0, count: $0.count) }
            .joined()
        XCTAssertEqual(joined, text)
    }
}
