import XCTest
@testable import VoicelyCore

final class SemanticTranscriptFilterTests: XCTestCase {
    func testLegitimateShortPhrasesAreNeverDeletedByMeaning() {
        for phrase in [
            "Спасибо.",
            "Спасибо за просмотр!",
            "Thank you.",
            "Bye.",
            "Goodbye.",
            "Music",
            "Продолжение следует...",
            "Subtitles by Alice",
        ] {
            XCTAssertEqual(
                WhisperKitEngine.cleanSegmentText(phrase),
                phrase,
                "semantic text filter deleted legitimate speech: \(phrase)"
            )
        }
    }

    func testTokenOnlyAndPunctuationOnlySegmentsAreDropped() {
        for value in ["", "   ", "...", "♪ ♫", "<|startoftranscript|><|ru|>"] {
            XCTAssertNil(WhisperKitEngine.cleanSegmentText(value))
        }
    }

    func testSpecialTokensAreRemovedWithoutDeletingSpeech() {
        XCTAssertEqual(
            WhisperKitEngine.cleanSegmentText(
                "<|startoftranscript|><|ru|><|transcribe|> Спасибо. <|2.00|>"
            ),
            "Спасибо."
        )
    }
}
