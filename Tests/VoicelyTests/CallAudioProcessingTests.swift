import XCTest
@testable import VoicelyCore

final class CallAudioProcessingTests: XCTestCase {

    // MARK: - mixSum

    func testMixSumAlignsToLongerChannel() {
        // Shorter channel is silence past its end; length = longer channel.
        let mix = CallAudioProcessing.mixSum([0.2, 0.2], [0.1, 0.1, 0.3])
        XCTAssertEqual(mix.count, 3)
        XCTAssertEqual(mix[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(mix[1], 0.3, accuracy: 1e-6)
        XCTAssertEqual(mix[2], 0.3, accuracy: 1e-6, "tail of the longer channel must survive")
    }

    func testMixSumClampsToUnit() {
        let mix = CallAudioProcessing.mixSum([0.8, -0.8], [0.8, -0.8])
        XCTAssertEqual(mix[0], 1.0, accuracy: 1e-6, "1.6 clamps to +1")
        XCTAssertEqual(mix[1], -1.0, accuracy: 1e-6, "-1.6 clamps to -1")
    }

    func testResampleRejectsInvalidSourceRateInsteadOfReturningMistimedAudio() {
        XCTAssertThrowsError(
            try CallAudioProcessing.resampleMono([0.1, 0.2], fromRate: 0)
        ) { error in
            XCTAssertEqual(error as? CallAudioProcessingError, .invalidSampleRate(0))
        }
    }

    // MARK: - diarization-first system windows

    func testSystemWindowsKeepAlternatingShortSpeakerTurnsStable() {
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0, end: 3.5),
            SpeakerTurn(speakerIndex: 2, start: 3.5, end: 8),
            SpeakerTurn(speakerIndex: 1, start: 8, end: 11),
            SpeakerTurn(speakerIndex: 2, start: 11, end: 16),
        ]

        let windows = CallAudioProcessing.systemTranscriptionWindows(
            turns: turns,
            audioDuration: 16
        )

        XCTAssertEqual(windows.map(\.speakerID), [1, 2, 1, 2])
        XCTAssertEqual(windows.map(\.contentStart), [0, 3.5, 8, 11])
        XCTAssertEqual(windows.map(\.contentEnd), [3.5, 8, 11, 16])
        XCTAssertEqual(windows.map(\.audioStart), [0, 3.5, 8, 11])
        XCTAssertEqual(windows.map(\.audioEnd), [3.5, 8, 11, 16],
                       "context padding must not cross a different speaker boundary")
        XCTAssertTrue(windows.allSatisfy {
            $0.audioEnd - $0.audioStart <= CallAudioProcessing.systemASRMaxWindowSeconds
        })
    }

    func testNormalizeSystemTurnsMergesOneSpeakerDeterministically() {
        let unsorted = [
            SpeakerTurn(speakerIndex: 1, start: 3.05, end: 7),
            SpeakerTurn(speakerIndex: 1, start: 7, end: 10),
            SpeakerTurn(speakerIndex: 1, start: 0, end: 3),
        ]

        let first = CallAudioProcessing.normalizeSystemTurns(
            unsorted,
            audioDuration: 10
        )
        let second = CallAudioProcessing.normalizeSystemTurns(
            Array(unsorted.reversed()),
            audioDuration: 10
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].speakerIndex, 1)
        XCTAssertEqual(first[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(first[0].end, 10, accuracy: 1e-9)
    }

    func testSystemWindowsPreserveDifferentSpeakerOverlapAndUnlabeledGaps() {
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 1, end: 4),
            SpeakerTurn(speakerIndex: 2, start: 3, end: 6),
        ]

        let first = CallAudioProcessing.systemTranscriptionWindows(
            turns: turns,
            audioDuration: 8
        )
        let second = CallAudioProcessing.systemTranscriptionWindows(
            turns: Array(turns.reversed()),
            audioDuration: 8
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.speakerID), [nil, 1, 2, nil])
        XCTAssertEqual(first.map(\.contentStart), [0, 1, 3, 6])
        XCTAssertEqual(first.map(\.contentEnd), [1, 4, 6, 8])
        XCTAssertEqual(first[1].contentEnd - first[2].contentStart, 1, accuracy: 1e-9,
                       "the 3...4 second two-speaker overlap must remain in both windows")
    }

    func testLongSystemTurnIsSplitIntoBoundedWindowsWithoutTimelineLoss() {
        // The window mechanics are what is under test, so the bound is passed
        // explicitly; the shipped default is 300 s (fewer seams for Parakeet).
        let windows = CallAudioProcessing.systemTranscriptionWindows(
            turns: [SpeakerTurn(speakerIndex: 1, start: 0, end: 65)],
            audioDuration: 65,
            maxWindowSeconds: 30
        )

        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.speakerID == 1 })
        XCTAssertTrue(windows.allSatisfy {
            $0.audioEnd - $0.audioStart <= 30 + 1e-9
        })
        XCTAssertEqual(windows.first?.contentStart, 0)
        XCTAssertEqual(windows.last?.contentEnd, 65)
        for pair in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(pair.0.contentEnd, pair.1.contentStart, accuracy: 1e-9)
        }
    }

    func testSystemSegmentsCropPaddingAndStampDiarizerSpeaker() {
        let window = CallSystemTranscriptionWindow(
            speakerID: 2,
            contentStart: 3.5,
            contentEnd: 8,
            audioStart: 3.25,
            audioEnd: 8.25
        )
        let raw = [DialogueSegment(
            speaker: .you,
            start: 3.25,
            end: 8.25,
            text: "remote speech",
            language: "en",
            speakerID: 99
        )]

        let segments = CallAudioProcessing.systemSegments(from: raw, in: window)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speaker, .other)
        XCTAssertEqual(segments[0].speakerID, 2)
        XCTAssertEqual(segments[0].start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 8, accuracy: 1e-9)
        XCTAssertEqual(segments[0].text, "remote speech")
    }

    func testEmptyDiarizationSignalsWholeChannelFallback() {
        XCTAssertTrue(CallAudioProcessing.systemTranscriptionWindows(
            turns: [],
            audioDuration: 60
        ).isEmpty)
    }

    // MARK: - voiceIntervals

    func testVoiceIntervalsFindsLoudSpan() {
        let rate = 16000.0
        let win = Int(0.1 * rate) // 1600
        var samples = [Float](repeating: 0, count: win)        // 0.0–0.1 s silence
        samples += [Float](repeating: 0.5, count: win)         // 0.1–0.2 s speech
        samples += [Float](repeating: 0, count: win)           // 0.2–0.3 s silence
        let intervals = CallAudioProcessing.voiceIntervals(samples, rate: rate)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start, 0.1, accuracy: 0.01)
        XCTAssertEqual(intervals[0].end, 0.2, accuracy: 0.01)
    }

    func testVoiceIntervalsEmptyForSilence() {
        let intervals = CallAudioProcessing.voiceIntervals([Float](repeating: 0, count: 16000))
        XCTAssertTrue(intervals.isEmpty)
    }

    // MARK: - assembleCallTranscript

    private func seg(
        _ speaker: CallSpeaker,
        _ start: Double,
        _ text: String,
        speakerID: Int? = nil
    ) -> DialogueSegment {
        DialogueSegment(speaker: speaker, start: start, end: start + 1,
                        text: text, language: "ru", speakerID: speakerID)
    }

    func testAssembleCallTranscriptStampsOnlySystemAndKeepsMicAsYou() {
        let mic = [seg(.you, 1.0, "mic", speakerID: 99)]
        let system = [
            seg(.other, 0.0, "remote 1"),
            seg(.other, 2.0, "remote 2"),
        ]
        let turns = [
            SpeakerTurn(speakerIndex: 1, start: 0.0, end: 1.0),
            SpeakerTurn(speakerIndex: 2, start: 2.0, end: 3.0),
        ]

        let out = CallAudioProcessing.assembleCallTranscript(
            mic: mic, system: system, systemTurns: turns)

        XCTAssertEqual(out.map(\.text), ["remote 1", "mic", "remote 2"])
        XCTAssertEqual(out[1].speaker, .you)
        XCTAssertNil(out[1].speakerID, "mic provenance is truth; diarization never stamps You")
        XCTAssertEqual(out[0].speaker, .other)
        XCTAssertEqual(out[0].speakerID, 1)
        XCTAssertEqual(out[2].speaker, .other)
        XCTAssertEqual(out[2].speakerID, 2)
    }

    func testAssembleCallTranscriptNeverPromotesOverlappingSystemTurnToYou() {
        let mic = [seg(.you, 10.0, "local speech")]
        let system = [seg(.other, 10.0, "remote bleed overlap")]
        let turns = [SpeakerTurn(speakerIndex: 1, start: 9.5, end: 11.5)]

        let out = CallAudioProcessing.assembleCallTranscript(
            mic: mic, system: system, systemTurns: turns)

        let remote = out.first { $0.text == "remote bleed overlap" }
        XCTAssertEqual(remote?.speaker, .other)
        XCTAssertEqual(remote?.speakerID, 1)
        let local = out.first { $0.text == "local speech" }
        XCTAssertEqual(local?.speaker, .you)
        XCTAssertNil(local?.speakerID)
    }

    func testAssembleCallTranscriptPreservesDiarizationFirstSpeakerIDs() {
        let system = [seg(.other, 2, "remote", speakerID: 2)]

        let out = CallAudioProcessing.assembleCallTranscript(
            mic: [],
            system: system,
            systemTurns: []
        )

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speaker, .other)
        XCTAssertEqual(out[0].speakerID, 2)
    }

    // MARK: - call language

    func testDominantLanguagePrefersMostCommonNonNilLanguage() {
        let segments = [
            DialogueSegment(speaker: .other, start: 0, end: 1, text: "one", language: "en"),
            DialogueSegment(speaker: .other, start: 1, end: 2, text: "два", language: "ru"),
            DialogueSegment(speaker: .other, start: 2, end: 3, text: "три", language: "ru"),
            DialogueSegment(speaker: .other, start: 3, end: 4, text: "?", language: nil),
        ]

        XCTAssertEqual(CallAudioProcessing.dominantLanguage(in: segments), "ru")
    }

    func testMicLanguageOverrideUsesSystemLanguageOnlyInAutoNonTranslateCalls() {
        let system = [
            DialogueSegment(speaker: .other, start: 0, end: 1, text: "Привет", language: "ru"),
        ]

        XCTAssertEqual(
            CallAudioProcessing.micLanguageOverride(
                preferredLanguage: nil,
                translateToEnglish: false,
                system: system),
            "ru"
        )
        XCTAssertNil(
            CallAudioProcessing.micLanguageOverride(
                preferredLanguage: "en",
                translateToEnglish: false,
                system: system),
            "explicit user language already forces both channels"
        )
        XCTAssertNil(
            CallAudioProcessing.micLanguageOverride(
                preferredLanguage: nil,
                translateToEnglish: true,
                system: system),
            "translate-to-English mode should keep translating both channels"
        )
    }
}
