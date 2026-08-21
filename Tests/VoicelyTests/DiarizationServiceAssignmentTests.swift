import XCTest
@testable import VoicelyCore

final class DiarizationServiceAssignmentTests: XCTestCase {
    private func segment(
        start: Double,
        end: Double,
        speaker: CallSpeaker = .other,
        speakerID: Int? = nil
    ) -> DialogueSegment {
        DialogueSegment(
            speaker: speaker,
            start: start,
            end: end,
            text: "segment",
            language: "ru",
            speakerID: speakerID)
    }

    func testAssignSpeakersPrefersOverlapBeforeNearestTurnFallback() {
        let segments = [segment(start: 1.05, end: 1.35)]
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0.0, end: 1.0),
            SpeakerTurn(speakerIndex: 2, start: 1.1, end: 2.0),
        ]

        let stamped = DiarizationService.assignSpeakers(to: segments, turns: turns)

        XCTAssertEqual(stamped[0].speakerID, 2)
    }

    func testAssignSpeakersBorrowsNearestTurnWithinTolerance() {
        let segments = [segment(start: 1.05, end: 1.2)]
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0.0, end: 1.0),
            SpeakerTurn(speakerIndex: 2, start: 1.45, end: 2.0),
        ]

        let stamped = DiarizationService.assignSpeakers(to: segments, turns: turns)

        XCTAssertEqual(stamped[0].speakerID, 1)
    }

    func testAssignSpeakersBreaksNearestTurnTiesDeterministically() {
        let segments = [segment(start: 1.0, end: 1.1)]
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0.0, end: 1.0),
            SpeakerTurn(speakerIndex: 2, start: 1.1, end: 2.0),
        ]

        let stamped = DiarizationService.assignSpeakers(to: segments, turns: turns)

        XCTAssertEqual(stamped[0].speakerID, 1)
    }

    func testAssignSpeakersLeavesUnknownWhenNoTurnIsNearEnough() {
        let segments = [segment(start: 1.0 + DiarizationService.nearestTurnTolerance + 0.05,
                                end: 1.5 + DiarizationService.nearestTurnTolerance + 0.05)]
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0.0, end: 1.0),
        ]

        let stamped = DiarizationService.assignSpeakers(to: segments, turns: turns)

        XCTAssertNil(stamped[0].speakerID)
    }
}
