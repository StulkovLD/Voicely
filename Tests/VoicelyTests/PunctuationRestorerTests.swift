import XCTest
@testable import VoicelyCore

final class PunctuationRestorerTests: XCTestCase {
    func testLabelDecoderCaseAndPunctuation() {
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "привет", label: "UPPER_COMMA", scheme: .ruPunct), "Привет,")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "мир", label: "UPPER_VOSKL", scheme: .ruPunct), "Мир!")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "языке", label: "LOWER_PERIOD", scheme: .ruPunct), "языке.")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "сша", label: "UPPER_TOTAL_O", scheme: .ruPunct), "США")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "точно", label: "LOWER_O", scheme: .ruPunct), "точно")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "да", label: "UPPER_QUESTION", scheme: .ruPunct), "Да?")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "но", label: "LOWER_TIRE", scheme: .ruPunct), "но —")
    }

    func testRpunctLabelDecoder() {
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "hello", label: "OU", scheme: .rpunct), "Hello")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "model", label: ".O", scheme: .rpunct), "model.")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "world", label: ",O", scheme: .rpunct), "world,")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "it", label: "?U", scheme: .rpunct), "It?")
        XCTAssertEqual(PunctuationLabelDecoder.apply(word: "ok", label: "OO", scheme: .rpunct), "ok")
    }

    func testCapitalizeSentencesFixesPostPeriodCase() {
        // The token model often leaves the word after a period lowercase.
        XCTAssertEqual(
            PunctuationLabelDecoder.capitalizeSentences("привет, мир! сегодня хорошо. она пришла."),
            "Привет, мир! Сегодня хорошо. Она пришла."
        )
        XCTAssertEqual(
            PunctuationLabelDecoder.capitalizeSentences("вопрос? ответ."),
            "Вопрос? Ответ."
        )
    }

    func testRuleBasedFloorCapitalizesFirstLetter() async throws {
        let floor = RuleBasedPunctuationRestorer()
        let out = try await floor.restore("hello world today we test", language: "en")
        XCTAssertEqual(out, "Hello world today we test")
    }

    func testWordPieceGreedyMatchAndUnknown() {
        // Tiny hand-built vocab exercising continuation pieces and [UNK].
        let vocabLines = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "при", "##вет", "мир", "ⱺ"]
        let tok = WordPieceTokenizer(
            vocabLines: vocabLines,
            meta: .init(clsID: 2, sepID: 3, padID: 0, unkID: 1, maxLen: 32)
        )
        let enc = tok.encode(words: ["привет", "мир", "zzz"])
        // [CLS] при ##вет мир [UNK] [SEP]
        XCTAssertEqual(enc.ids, [2, 4, 5, 6, 1, 3])
        // Only the first subtoken of each word carries the word index.
        XCTAssertEqual(enc.wordIndex, [-1, 0, -1, 1, 2, -1])
    }
}
