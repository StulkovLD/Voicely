import XCTest
@testable import VoicelyCore

final class CallTranscriptionProgressTests: XCTestCase {
    func testMenuBarTitleClampsAndRoundsPercent() {
        XCTAssertEqual(CallTranscriptionProgress.menuBarTitle(for: -0.20), " 0%")
        XCTAssertEqual(CallTranscriptionProgress.menuBarTitle(for: 0.424), " 42%")
        XCTAssertEqual(CallTranscriptionProgress.menuBarTitle(for: 0.995), " 100%")
        XCTAssertEqual(CallTranscriptionProgress.menuBarTitle(for: 1.50), " 100%")
    }

    func testMenuItemTitleIncludesRoundedPercent() {
        XCTAssertEqual(CallTranscriptionProgress.menuItemTitle(for: 0.0), "Transcribing call... 0%")
        XCTAssertEqual(CallTranscriptionProgress.menuItemTitle(for: 0.876), "Transcribing call... 88%")
    }

    func testPhaseProgressAllocatesMostWeightToTranscriptionWindows() {
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .preparing), 0.0, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .transcribing(completedWindows: 0, totalWindows: 4)), 0.05, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .transcribing(completedWindows: 2, totalWindows: 4)), 0.45, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .transcribing(completedWindows: 4, totalWindows: 4)), 0.85, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .diarizing), 0.90, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .saving), 0.97, accuracy: 0.0001)
        XCTAssertEqual(CallTranscriptionProgress.fraction(for: .finished), 1.0, accuracy: 0.0001)
    }

    func testTranscriptionWindowCountUsesThirtySecondChunks() {
        XCTAssertEqual(CallTranscriptionProgress.windowCount(sampleCount: 0, sampleRate: 16_000), 0)
        XCTAssertEqual(CallTranscriptionProgress.windowCount(sampleCount: 16_000, sampleRate: 16_000), 1)
        XCTAssertEqual(CallTranscriptionProgress.windowCount(sampleCount: 30 * 16_000, sampleRate: 16_000), 1)
        XCTAssertEqual(CallTranscriptionProgress.windowCount(sampleCount: 30 * 16_000 + 1, sampleRate: 16_000), 2)
        XCTAssertEqual(CallTranscriptionProgress.windowCount(sampleCount: 90 * 16_000, sampleRate: 16_000), 3)
    }
}
