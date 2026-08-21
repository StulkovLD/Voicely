import XCTest
@testable import VoicelyCore

final class CallMixdownTests: XCTestCase {
    func testSpeechIntervalsFindTheLoudStretchAndMergeNeighbours() {
        // 2s of silence, 1s of tone, 0.1s dip, 1s of tone -> one merged interval.
        let sr = Int(CallMixdown.sampleRate)
        var samples = [Float](repeating: 0, count: sr * 2)
        let tone = (0..<sr).map { Float(0.3 * sin(Double($0) * 0.3)) }
        samples += tone
        samples += [Float](repeating: 0, count: sr / 10)
        samples += tone

        let intervals = CallMixdown.speechIntervals(in: samples)

        XCTAssertEqual(intervals.count, 1, "\(intervals)")
        XCTAssertEqual(intervals[0].start, 2.0, accuracy: 0.31)
        XCTAssertEqual(intervals[0].end, 4.1, accuracy: 0.35)
    }

    func testYouSpeakerIsTheClusterTheMicCovers() {
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0, end: 10),   // remote talker
            SpeakerTurn(speakerIndex: 2, start: 12, end: 16),  // the local user
            SpeakerTurn(speakerIndex: 1, start: 18, end: 25),
        ]
        // The mic was hot exactly while speaker 2 talked.
        let mic = [(start: 11.8, end: 16.2)]

        XCTAssertEqual(CallMixdown.youSpeakerIndex(turns: turns, micActivity: mic), 2)
    }

    func testNoYouWhenTheMicNeverMatchesEnough() {
        let turns = [SpeakerTurn(speakerIndex: 1, start: 0, end: 100)]
        let mic = [(start: 0.0, end: 2.0)]  // 2% coverage — under the floor

        XCTAssertNil(CallMixdown.youSpeakerIndex(turns: turns, micActivity: mic))
    }

    func testApplyYouRelabelsAndRenumbersWithoutGaps() {
        let segments = [
            DialogueSegment(speaker: .other, start: 0, end: 1, text: "a", language: nil, speakerID: 3),
            DialogueSegment(speaker: .other, start: 2, end: 3, text: "b", language: nil, speakerID: 7),
            DialogueSegment(speaker: .other, start: 4, end: 5, text: "c", language: nil, speakerID: 3),
            DialogueSegment(speaker: .other, start: 6, end: 7, text: "d", language: nil, speakerID: 5),
        ]

        let out = CallMixdown.applyYou(to: segments, youSpeakerIndex: 7)

        XCTAssertEqual(out.map(\.speaker), [.other, .you, .other, .other])
        XCTAssertEqual(out.map(\.speakerID), [1, nil, 1, 2],
                       "remote speakers renumber 1..K by first appearance; You carries no id")
    }

    func testMixdownSumsChannelsAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-mixdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sr = Int(CallMixdown.sampleRate)
        let a = (0..<sr).map { Float(0.25 * sin(Double($0) * 0.2)) }
        let b = [Float](repeating: 0.5, count: sr / 2)
        let aURL = dir.appendingPathComponent("system.wav")
        let bURL = dir.appendingPathComponent("mic.wav")
        try CallMixdown.writeMono16k(a, to: aURL)
        try CallMixdown.writeMono16k(b, to: bURL)

        let mixURL = dir.appendingPathComponent("mix.wav")
        let duration = try CallMixdown.mixdown(system: aURL, mic: bURL, to: mixURL)

        XCTAssertEqual(duration, 1.0, accuracy: 0.01, "mix runs as long as the longest channel")
        let mixed = try CallMixdown.readMono16k(from: mixURL)
        XCTAssertEqual(mixed.count, sr)
        XCTAssertEqual(mixed[100], a[100] + 0.5, accuracy: 0.02)
        XCTAssertEqual(mixed[sr - 100], a[sr - 100], accuracy: 0.02,
                       "past the short channel's end only the long channel remains")
    }
}
