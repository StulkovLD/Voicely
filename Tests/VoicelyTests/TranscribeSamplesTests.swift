import XCTest
@testable import VoicelyCore

/// These tests exercise the types, NOT the real WhisperKit pipeline.
/// They pin the public shape of WhisperSegment / WhisperTranscription /
/// SampleTranscribing so downstream file-transcription code can depend
/// on a stable contract.
final class TranscribeSamplesTests: XCTestCase {

    func testWhisperSegmentIsSendable() {
        let s = WhisperSegment(start: 1.0, end: 2.5, text: "hello")
        XCTAssertEqual(s.start, 1.0)
        XCTAssertEqual(s.end, 2.5)
        XCTAssertEqual(s.text, "hello")
    }

    func testWhisperTranscriptionBundlesFields() {
        let t = WhisperTranscription(
            text: "hello world",
            segments: [
                WhisperSegment(start: 0, end: 1, text: "hello"),
                WhisperSegment(start: 1, end: 2, text: "world"),
            ],
            detectedLanguage: "en"
        )
        XCTAssertEqual(t.text, "hello world")
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertEqual(t.detectedLanguage, "en")
    }

    func testMockSampleTranscriberRecordsCalls() async throws {
        let mock = MockSampleTranscriber()
        let result = try await mock.transcribeSamples(
            [Float](repeating: 0, count: 100),
            translate: false,
            language: nil)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].sampleCount, 100)
    }

    func testMockSampleTranscriberThrowsOnConfiguredIndex() async {
        let mock = MockSampleTranscriber()
        mock.throwOnCallIndex = 1
        _ = try? await mock.transcribeSamples([], translate: false, language: nil)
        do {
            _ = try await mock.transcribeSamples([], translate: false, language: nil)
            XCTFail("second call should have thrown")
        } catch {
            // expected
        }
    }

    func testWhisperKitEngineConformsToSampleTranscribing() {
        // Compile-time check: casting a real engine to the protocol must succeed.
        // No runtime behavior — just shape.
        let model = WhisperModel.recommended()
        let engine = WhisperKitEngine(model: model, onProgress: nil)
        let _: any SampleTranscribing = engine
    }

    // MARK: - Fix 1.5: confidence-gated, candidate-biased language pick

    private let candidates: Set<String> = ["ru", "en"]
    private let threshold: Float = 0.6

    func testPickLanguageTrustsConfidentDetection() {
        // High-confidence Russian is trusted as-is (the working RU dictation case).
        let picked = WhisperKitEngine.pickLanguage(
            langProbs: ["ru": 0.92, "en": 0.05, "uk": 0.03],
            candidates: candidates, threshold: threshold)
        XCTAssertEqual(picked, "ru")
    }

    func testPickLanguageTrustsConfidentNonCandidate() {
        // A genuinely French file (confident) still latches French even though
        // French is not in the user's candidate set.
        let picked = WhisperKitEngine.pickLanguage(
            langProbs: ["fr": 0.78, "en": 0.12, "ru": 0.05],
            candidates: candidates, threshold: threshold)
        XCTAssertEqual(picked, "fr")
    }

    func testPickLanguageRejectsAmbiguousExoticMisfire() {
        // The observed bug: an English clip whose top (low-confidence) guess is
        // Urdu must NOT latch Urdu — it falls back to the best candidate (en).
        let picked = WhisperKitEngine.pickLanguage(
            langProbs: ["ur": 0.40, "en": 0.34, "ru": 0.18, "hi": 0.08],
            candidates: candidates, threshold: threshold)
        XCTAssertEqual(picked, "en")
    }

    func testPickLanguageAmbiguousPrefersHigherCandidate() {
        // Ambiguous between the two candidates -> pick the more probable one.
        let picked = WhisperKitEngine.pickLanguage(
            langProbs: ["ca": 0.30, "ru": 0.28, "en": 0.22],
            candidates: candidates, threshold: threshold)
        XCTAssertEqual(picked, "ru")
    }

    func testPickLanguageNoCandidatePresentFallsBackToArgmax() {
        // Ambiguous and neither candidate has any probability mass -> last-resort
        // argmax (don't drop the result entirely).
        let picked = WhisperKitEngine.pickLanguage(
            langProbs: ["de": 0.45, "nl": 0.40, "fr": 0.15],
            candidates: candidates, threshold: threshold)
        XCTAssertEqual(picked, "de")
    }

    func testPickLanguageEmptyReturnsNil() {
        XCTAssertNil(WhisperKitEngine.pickLanguage(
            langProbs: [:], candidates: candidates, threshold: threshold))
    }
}
