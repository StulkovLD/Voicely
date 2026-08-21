import XCTest
@testable import VoicelyCore
import FluidAudio

final class ParakeetSegmentingTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    func testSentenceTerminatorClosesSegment() {
        let words = [
            word("Привет,", 0.0, 0.4),
            word("мир.", 0.5, 0.9),
            word("Как", 1.0, 1.2),
            word("дела?", 1.3, 1.7),
        ]
        let segments = ParakeetEngine.makeSegments(words: words, fallbackText: "", duration: 2.0)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Привет, мир.")
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[0].end, 0.9)
        XCTAssertEqual(segments[1].text, "Как дела?")
        XCTAssertEqual(segments[1].start, 1.0)
        XCTAssertEqual(segments[1].end, 1.7)
    }

    func testLongPauseClosesSegmentMidSentence() {
        let words = [
            word("раз", 0.0, 0.3),
            word("два", 0.4, 0.7),
            // 1.5s of silence — longer than the 1.0s segment gap
            word("три", 2.2, 2.5),
        ]
        let segments = ParakeetEngine.makeSegments(words: words, fallbackText: "", duration: 3.0)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "раз два")
        XCTAssertEqual(segments[1].text, "три")
        XCTAssertEqual(segments[1].start, 2.2)
    }

    func testNoTimingsFallsBackToOneFullSpanSegment() {
        let segments = ParakeetEngine.makeSegments(words: [], fallbackText: "весь текст", duration: 12.5)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 12.5)
        XCTAssertEqual(segments[0].text, "весь текст")
    }

    func testEmptyEverythingYieldsNoSegments() {
        XCTAssertTrue(ParakeetEngine.makeSegments(words: [], fallbackText: "", duration: 5).isEmpty)
    }
}
