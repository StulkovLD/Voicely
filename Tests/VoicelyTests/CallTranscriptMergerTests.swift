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

    func testHumanFormat_producesExpectedLines() {
        let segments = [
            DialogueSegment(speaker: .other, start: 5.2, end: 7.3, text: "Привет", language: "ru"),
            DialogueSegment(speaker: .you, start: 8.4, end: 11.7, text: "Hi", language: "en"),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        // N2b: speaker labels are now humanized ("you"->"You", "other"->"Other").
        // No diarization id here, so the remote turn renders as "Other" and no
        // legend is prepended (legend only appears once a remote speaker is
        // diarized). Width is 5 ("Other"), so "You" is padded to "You  ".
        XCTAssertTrue(md.contains("[00:00:05] Other (ru): Привет"))
        XCTAssertTrue(md.contains("[00:00:08] You   (en): Hi"))
        XCTAssertFalse(md.contains("Speakers detected"))
    }

    func testHumanFormat_unknownLanguage() {
        let segments = [
            DialogueSegment(speaker: .you, start: 1.0, end: 2.0, text: "Hm", language: nil),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("[00:00:01] You   (??): Hm"))
    }

    // MARK: - N2b: call diarization labels + legend

    func testHumanFormat_diarizedRemoteSpeakersGetNumberedLabels() {
        let segments = [
            DialogueSegment(speaker: .you, start: 0.0, end: 1.0, text: "Hi", language: "en"),
            DialogueSegment(speaker: .other, start: 2.0, end: 3.0, text: "A", language: "en", speakerID: 1),
            DialogueSegment(speaker: .other, start: 4.0, end: 5.0, text: "B", language: "en", speakerID: 2),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        // Legend lists the two detected remote speakers + the local user.
        XCTAssertTrue(md.contains("Speakers detected: 2"))
        XCTAssertTrue(md.contains("- You: you (microphone)"))
        XCTAssertTrue(md.contains("- Speaker 1: remote participant"))
        XCTAssertTrue(md.contains("- Speaker 2: remote participant"))
        // Body uses "Speaker N" for diarized remote turns, "You" for the mic.
        XCTAssertTrue(md.contains("Speaker 1 (en): A"))
        XCTAssertTrue(md.contains("Speaker 2 (en): B"))
        XCTAssertTrue(md.contains("You"))
    }

    func testHumanFormat_undiarizedRemoteStaysOtherNoLegend() {
        // A remote turn without a speakerID (diarization off / failed / no
        // overlap) must keep rendering as "Other" with no legend.
        let segments = [
            DialogueSegment(speaker: .other, start: 0.0, end: 1.0, text: "X", language: "ru"),
        ]
        let md = CallTranscriptMerger.humanFormat(segments: segments)
        XCTAssertTrue(md.contains("Other (ru): X"))
        XCTAssertFalse(md.contains("Speakers detected"))
        XCTAssertFalse(md.contains("Speaker 1"))
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
