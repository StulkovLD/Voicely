import XCTest
@testable import Voicely

final class OverlayMessageTests: XCTestCase {
    func testShortToastKeepsTheBasePill() {
        XCTAssertEqual(Overlay.messagePillWidth(for: "Saved"), 160)
    }

    func testLongToastGrowsToFitItsText() {
        let width = Overlay.messagePillWidth(for: "Copied to clipboard & saved")
        XCTAssertGreaterThan(width, 160)
        XCTAssertLessThanOrEqual(width, 440)
    }

    func testAbsurdToastStopsAtTheCap() {
        let width = Overlay.messagePillWidth(for: String(repeating: "transcription ", count: 40))
        XCTAssertEqual(width, 440)
    }
}
