import XCTest
@testable import VoicelyCore

final class CallTranscriptMergerTests: XCTestCase {
    func testMerge_ordersByStartTime() {
        let mic = [
            DialogueSegment(speaker: .you, start: 8.4, end: 11.7, text: "Hi, all good", language: "en")
        ]
        let system = [
            DialogueSegment(speaker: .other, start: 5.2, end: 7.3, text: "Привет", language: "ru")
        ]
        let out = CallTranscriptMerger.merge(mic: mic, system: system)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].speaker, .other)
        XCTAssertEqual(out[1].speaker, .you)
    }

    func testMerge_interleavesOverlappingSpeakers() {
        let mic = [
            DialogueSegment(speaker: .you, start: 0.0, end: 2.0, text: "A", language: "en"),
            DialogueSegment(speaker: .you, start: 6.0, end: 8.0, text: "C", language: "en"),
        ]
        let system = [
            DialogueSegment(speaker: .other, start: 2.5, end: 5.5, text: "B", language: "ru"),
        ]
        let out = CallTranscriptMerger.merge(mic: mic, system: system)
        XCTAssertEqual(out.map { $0.text }, ["A", "B", "C"])
    }

    func testMerge_equalStartsUseDeterministicChannelAndSourceOrder() {
        let mic = [
            DialogueSegment(speaker: .you, start: 1, end: 2, text: "you-1", language: "en"),
            DialogueSegment(speaker: .you, start: 1, end: 3, text: "you-2", language: "en"),
        ]
        let system = [
            DialogueSegment(speaker: .other, start: 1, end: 2, text: "other-1", language: "en"),
            DialogueSegment(speaker: .other, start: 1, end: 3, text: "other-2", language: "en"),
        ]

        for _ in 0..<20 {
            XCTAssertEqual(
                CallTranscriptMerger.merge(mic: mic, system: system).map(\.text),
                ["you-1", "you-2", "other-1", "other-2"]
            )
        }
    }

    // The accepted transcript shape (owner, 2026-08-19): one block per speaker
    // turn — "[mm:ss] Label" then the turn's text joined into running prose.

    func testHumanFormat_rendersOneBlockPerSpeakerTurn() {
        let segments = [
            DialogueSegment(speaker: .other, start: 5.2, end: 7.3, text: "Привет", language: "ru"),
            DialogueSegment(speaker: .you, start: 8.4, end: 11.7, text: "Hi", language: "en"),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("[00:05] Other\nПривет"), md)
        XCTAssertTrue(md.contains("[00:08] You\nHi"), md)
        XCTAssertFalse(md.contains("(ru)"), "language tags live in the JSONL, not the human file")
        XCTAssertFalse(md.contains("Speakers detected"))
    }

    func testHumanFormat_unknownLanguageRendersNoPlaceholder() {
        let segments = [
            DialogueSegment(speaker: .you, start: 1.0, end: 2.0, text: "Hm", language: nil),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("[00:01] You\nHm"), md)
        XCTAssertFalse(md.contains("??"))
    }

    func testHumanFormat_consecutiveSameSpeakerSegmentsJoinIntoOneBlock() {
        let segments = [
            DialogueSegment(speaker: .you, start: 4.0, end: 6.0, text: "Так, у нас пошёл рекординг.", language: "ru"),
            DialogueSegment(speaker: .you, start: 8.0, end: 10.0, text: "Просто хочу протестить.", language: "ru"),
            DialogueSegment(speaker: .other, start: 12.0, end: 13.0, text: "Ага.", language: "ru", speakerID: 1),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(
            md.contains("[00:04] You\nТак, у нас пошёл рекординг. Просто хочу протестить."),
            md
        )
        XCTAssertTrue(md.contains("[00:12] Speaker 1\nАга."), md)
    }

    func testHumanFormat_longSilenceSplitsTheSameSpeakerIntoBlocks() {
        let segments = [
            DialogueSegment(speaker: .you, start: 0.0, end: 2.0, text: "Раз.", language: "ru"),
            // 10s of silence — past the 6s block gap
            DialogueSegment(speaker: .you, start: 12.0, end: 13.0, text: "Два.", language: "ru"),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("[00:00] You\nРаз."), md)
        XCTAssertTrue(md.contains("[00:12] You\nДва."), md)
    }

    func testHumanFormat_hourLongCallGrowsHourDigit() {
        let segments = [
            DialogueSegment(speaker: .you, start: 3725.0, end: 3726.0, text: "Час пробит.", language: "ru"),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("[1:02:05] You"), md)
    }

    func testFrontMatterHelpers_durationAndSpeakers() {
        let segments = [
            DialogueSegment(speaker: .you, start: 0.0, end: 4.0, text: "A", language: "ru"),
            DialogueSegment(speaker: .other, start: 30.0, end: 74.0, text: "B", language: "ru", speakerID: 1),
        ]
        XCTAssertEqual(CallTranscriptMerger.durationLabel(for: segments), "01:14")
        XCTAssertEqual(CallTranscriptMerger.speakersSummary(for: segments), "You + 1")
        XCTAssertEqual(
            CallTranscriptMerger.speakersSummary(for: [segments[0]]),
            "You"
        )
    }

    func testJSONLFormat_includesSpeakerIDWhenDiarized() {
        let segments = [
            DialogueSegment(speaker: .other, start: 1.0, end: 2.0, text: "A", language: "en", speakerID: 2),
            DialogueSegment(speaker: .you, start: 3.0, end: 4.0, text: "B", language: "en"),
        ]
        let jsonl = CallTranscriptMerger.jsonlFormat(segments: segments)
        let lines = jsonl.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        // Diarized remote segment carries speaker_id; the mic segment does not.
        XCTAssertTrue(lines[0].contains("\"speaker_id\":2"))
        XCTAssertFalse(lines[1].contains("speaker_id"))
    }

    func testJSONLFormat_oneJSONPerLine() {
        let segments = [
            DialogueSegment(speaker: .other, start: 5.2, end: 7.3, text: "Привет", language: "ru"),
        ]
        let jsonl = CallTranscriptMerger.jsonlFormat(segments: segments)
        let lines = jsonl.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let line = String(lines[0])
        XCTAssertTrue(line.contains("\"speaker\":\"other\""))
        XCTAssertTrue(line.contains("\"lang\":\"ru\""))
        XCTAssertTrue(line.contains("\"text\":\"Привет\""))
        XCTAssertTrue(line.contains("\"t\":5.2"))
        // duration = end - start = 2.1, rounded to 2 decimals
        XCTAssertTrue(line.contains("\"d\":2.1"))
    }

    func testJSONLFormat_emptyInputProducesEmptyString() {
        XCTAssertEqual(CallTranscriptMerger.jsonlFormat(segments: []), "")
    }
}
