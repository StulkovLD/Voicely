import AppKit
import XCTest
@testable import Voicely

/// Every watchdog in the app gates on `overlay.currentMode == X` before hiding a
/// panel it thinks is stuck. Those guards are only as good as the mode being
/// truthful about what is on screen.
@MainActor
final class OverlayModeLifecycleTests: XCTestCase {

    func testModeStartsEmptyBeforeAnythingIsShown() {
        XCTAssertNil(Overlay().currentMode, "nothing shown yet — no mode to report")
    }

    func testShowPublishesItsMode() {
        let overlay = Overlay()
        overlay.show(mode: .loading)
        XCTAssertEqual(overlay.currentMode, .loading)
    }

    /// The fade-out leaves `isVisible == true` for 0.3 s. A mode that outlived
    /// `hide()` let a watchdog fire inside that gap and re-show the panel it was
    /// dismissing — stranding it on screen with no auto-hide. The mode must go
    /// immediately, not in the animation's completion handler.
    func testHideClearsModeImmediatelyEvenWhileStillFadingOut() {
        let overlay = Overlay()
        overlay.show(mode: .downloading)
        XCTAssertEqual(overlay.currentMode, .downloading)

        overlay.hide()

        XCTAssertNil(
            overlay.currentMode,
            "mode must not survive hide() — watchdogs read it to decide whether the panel is still up"
        )
    }

    /// The concrete shape of the bug this guards: the download watchdog only
    /// hides when the panel is still `.downloading`, so a hidden-but-stale
    /// `.downloading` would make it tear down a later, unrelated panel.
    func testStaleModeCannotSatisfyAWatchdogAfterHide() {
        let overlay = Overlay()
        overlay.show(mode: .downloading)
        overlay.hide()

        // This is verbatim the guard used in AppDelegate's download watchdogs.
        let watchdogWouldFire = overlay.currentMode == .downloading
        XCTAssertFalse(watchdogWouldFire, "a hidden panel must not answer to the downloading watchdog")
    }

    /// A toast over a live session is a toast: when it expires the session pill
    /// comes back. "Transcribing… press again to cancel" over `.loading` relies
    /// on this.
    func testToastOverLiveSessionResumesIt() {
        let overlay = Overlay()
        overlay.show(mode: .loading)
        overlay.showInfo("Transcribing… press again to cancel")

        XCTAssertEqual(overlay.currentMode, .error, "the toast owns the pill while it is up")
        XCTAssertEqual(overlay.toastResumeMode, .loading, "and hands it back to the session when it expires")
    }

    /// The bug the owner hit: tap the hotkey, release at once, nothing captured.
    /// The pill was `.loading`; "No speech detected" went up as a plain toast,
    /// expired 2.5 s later and put `.loading` back — with the session already
    /// over, nothing was left to hide it. A session's last word must not name a
    /// pill to come back to.
    func testFinishToastDoesNotResurrectTheSessionPill() {
        let overlay = Overlay()
        overlay.show(mode: .loading)
        overlay.finish(.info("No speech detected"))

        XCTAssertEqual(overlay.currentMode, .error, "the outcome is on screen")
        XCTAssertNil(overlay.toastResumeMode, "and nothing comes back after it")
    }

    /// The regression the first patch introduced: the file queue's "Transcribed
    /// 1 files" is a toast from a non-owner. Over a running dictation it must
    /// bring `.recording` back, not end it.
    func testNonOwnerToastOverLiveRecordingResumesIt() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Transcribed 1 files")

        XCTAssertEqual(overlay.toastResumeMode, .recording)
    }

    func testFinishSilentJustHidesTheSessionPill() {
        let overlay = Overlay()
        overlay.show(mode: .loading)
        overlay.finish(.silent)

        XCTAssertNil(overlay.currentMode)
        XCTAssertNil(overlay.toastResumeMode)
    }

    /// `hide()` means nothing is pending: a toast's delayed work item must not
    /// outlive it and act on whatever is on screen by then.
    func testHideCancelsAPendingToastExpiry() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")
        overlay.hide()

        XCTAssertNil(overlay.toastResumeMode)
        XCTAssertNil(overlay.currentMode)
    }

    func testFinishErrorToastDoesNotResurrectTheSessionPill() {
        let overlay = Overlay()
        overlay.show(mode: .loading)
        overlay.finish(.error("No audio captured"))

        XCTAssertEqual(overlay.currentMode, .error)
        XCTAssertNil(overlay.toastResumeMode)
    }

    /// A fresh session started while a terminal toast is still up must not be
    /// captured as that toast's resume target either way round.
    func testShowClearsAnyPendingResume() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")
        XCTAssertEqual(overlay.toastResumeMode, .recording)

        overlay.show(mode: .loading)
        XCTAssertNil(overlay.toastResumeMode)
        XCTAssertEqual(overlay.currentMode, .loading)
    }

    /// Two toasts in a row over a recording: the second one saw `.error`, took
    /// that as "no session", and when it expired the pill left mid-recording.
    /// A toast replacing a toast inherits its resume target.
    func testSecondToastKeepsTheSessionOfTheFirst() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")
        overlay.showError("Accessibility permission lost")

        XCTAssertEqual(overlay.toastResumeMode, .recording, "the recording is still on and must come back")
    }

    func testShowAfterHideRepublishesMode() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.hide()
        overlay.show(mode: .loading)

        XCTAssertEqual(overlay.currentMode, .loading, "a fresh show must re-arm the mode")
    }
}
