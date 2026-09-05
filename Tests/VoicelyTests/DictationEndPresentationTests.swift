import XCTest
@testable import Voicely

/// The pill's last word at the end of a dictation session is decided by one
/// pure policy and applied through `Overlay.finish`. Every outcome is a session
/// end — `.silent` or a terminal toast — so no branch can bring `.loading` back
/// (lived: tap-and-release dictation, "No speech detected" over `.loading`,
/// pill loading forever).
final class DictationEndPresentationTests: XCTestCase {
    private func presentation(
        hasText: Bool = true,
        injection: InjectionResult? = .directInsert,
        saved: Bool = true,
        requiresRecovery: Bool = false,
        terminationInProgress: Bool = false
    ) -> Overlay.SessionEnd {
        AppDelegate.dictationEndPresentation(
            hasText: hasText,
            injection: injection,
            saved: saved,
            requiresRecovery: requiresRecovery,
            terminationInProgress: terminationInProgress
        )
    }

    func testTapAndReleaseEndsWithNoSpeechDetected() {
        XCTAssertEqual(presentation(hasText: false, injection: nil, saved: false), .info("No speech detected"))
    }

    func testEmptyIncompleteDecodePreservesAudio() {
        XCTAssertEqual(
            presentation(hasText: false, injection: nil, saved: false, requiresRecovery: true),
            .error("Transcription incomplete. Audio preserved")
        )
    }

    func testCleanInsertAndSaveIsSilent() {
        XCTAssertEqual(presentation(), .silent)
    }

    func testInsertWithFailedSaveSaysSo() {
        XCTAssertEqual(presentation(saved: false), .error("Inserted. Save failed"))
    }

    func testClipboardFallbackIsInfo() {
        XCTAssertEqual(presentation(injection: .copiedOnly), .info("Copied to clipboard & saved"))
        XCTAssertEqual(presentation(injection: .copiedOnly, saved: false), .info("Copied to clipboard; save failed"))
    }

    func testSecureFieldAndCopyFailureAreErrors() {
        XCTAssertEqual(presentation(injection: .blockedSecureTarget), .error("Secure field blocked. Saved"))
        XCTAssertEqual(presentation(injection: .blockedSecureTarget, saved: false), .error("Secure field blocked. Save failed"))
        XCTAssertEqual(presentation(injection: .failed), .error("Copy failed. Saved"))
        XCTAssertEqual(presentation(injection: .failed, saved: false), .error("Copy failed. Save failed"))
    }

    func testIncompleteDecodeOutranksTheInjectionOutcome() {
        XCTAssertEqual(
            presentation(injection: .copiedOnly, requiresRecovery: true),
            .error("Transcription incomplete. Audio preserved")
        )
        XCTAssertEqual(
            presentation(injection: .copiedOnly, saved: false, requiresRecovery: true),
            .error("Transcription incomplete. Audio preserved; save failed")
        )
    }

    /// App termination: text is saved, nothing is injected, nothing is said.
    func testTerminationWithTextIsSilent() {
        XCTAssertEqual(presentation(injection: nil, terminationInProgress: true), .silent)
        XCTAssertEqual(presentation(injection: nil, requiresRecovery: true, terminationInProgress: true), .silent)
    }
}
