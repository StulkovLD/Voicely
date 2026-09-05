import AppKit
import XCTest
@testable import Voicely

/// Every watchdog in the app gates on the overlay's session before hiding a
/// panel it thinks is stuck. Those guards are only as good as the mode and the
/// session token being truthful about what is on screen.
@MainActor
final class OverlayModeLifecycleTests: XCTestCase {

    /// Captures toast expiry instead of scheduling it, so a test fires it by
    /// hand and can read the delay the overlay asked for.
    private func overlayWithManualToasts() -> (Overlay, fire: () -> Void, delay: () -> TimeInterval?) {
        var pending: DispatchWorkItem?
        var delay: TimeInterval?
        let overlay = Overlay(toastScheduler: { d, work in
            delay = d
            pending = work
        })
        return (overlay, { pending?.perform() }, { delay })
    }

    func testModeStartsEmptyBeforeAnythingIsShown() {
        XCTAssertNil(Overlay().currentMode, "nothing shown yet — no mode to report")
    }

    func testShowPublishesItsModeAndASession() {
        let overlay = Overlay()
        let token = overlay.show(mode: .loading)
        XCTAssertEqual(overlay.currentMode, .loading)
        XCTAssertEqual(overlay.session, token)
    }

    /// The fade-out leaves `isVisible == true` for 0.3 s. A mode that outlived
    /// hide let a watchdog fire inside that gap and re-show the panel it was
    /// dismissing — stranding it on screen with no auto-hide. The mode must go
    /// immediately, not in the animation's completion handler.
    func testHideClearsModeImmediatelyEvenWhileStillFadingOut() {
        let overlay = Overlay()
        let token = overlay.show(mode: .downloading)
        overlay.hide(token)
        XCTAssertNil(overlay.currentMode, "mode must not survive hide — watchdogs read it")
        XCTAssertNil(overlay.session)
    }

    /// Only the owner takes its pill down: `.loading` is shared by model setup,
    /// dictation and call finalization.
    func testHideWithAForeignTokenIsANoOp() {
        let overlay = Overlay()
        let stale = overlay.show(mode: .loading)
        overlay.finish(.silent, of: stale)
        let live = overlay.show(mode: .loading)

        overlay.hide(stale)

        XCTAssertEqual(overlay.currentMode, .loading)
        XCTAssertEqual(overlay.session, live)
    }

    func testShowAfterHideRepublishesMode() {
        let overlay = Overlay()
        let token = overlay.show(mode: .recording)
        overlay.hide(token)
        overlay.show(mode: .loading)
        XCTAssertEqual(overlay.currentMode, .loading, "a fresh show must re-arm the mode")
    }

    // MARK: toasts over a live session

    /// A toast over a live session is a toast: when it expires the session pill
    /// comes back. "Transcribing… press again to cancel" over `.loading` relies
    /// on this.
    func testToastOverLiveSessionResumesIt() {
        let (overlay, fire, delay) = overlayWithManualToasts()
        let token = overlay.show(mode: .loading)
        overlay.showInfo("Transcribing… press again to cancel")

        XCTAssertEqual(overlay.currentMode, .error, "the toast owns the pill while it is up")
        XCTAssertEqual(overlay.toastResumeMode, .loading)
        XCTAssertEqual(delay(), Overlay.sessionToastSeconds, "toasts over a session return quickly")

        fire()
        XCTAssertEqual(overlay.currentMode, .loading)
        XCTAssertEqual(overlay.session, token, "the same session, not a new one")
    }

    /// The file queue's "Transcribed 1 files" is a toast from a non-owner. Over
    /// a running dictation it must bring `.recording` back, not end it.
    func testNonOwnerToastOverLiveRecordingResumesIt() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Transcribed 1 files")
        XCTAssertEqual(overlay.toastResumeMode, .recording)
    }

    /// Two toasts in a row over a recording: the second one saw `.error`, took
    /// that as "no session", and when it expired the pill left mid-recording.
    /// A toast replacing a toast inherits its resume target — and the clock's
    /// epoch, so the timer neither restarts nor dies at 0:00.
    func testSecondToastKeepsTheSessionAndTheRecordingEpoch() {
        let (overlay, fire, _) = overlayWithManualToasts()
        overlay.show(mode: .recording)
        let epoch = overlay.currentRecordingStart
        XCTAssertNotNil(epoch)
        overlay.showInfo("Hotkey active")
        overlay.showError("Accessibility permission lost")
        XCTAssertEqual(overlay.toastResumeMode, .recording)

        fire()
        XCTAssertEqual(overlay.currentMode, .recording)
        XCTAssertEqual(overlay.currentRecordingStart, epoch)
    }

    /// A mode switch of the session behind a toast must not kill the toast:
    /// the toast is read, then the pill returns in the NEW mode.
    func testModeSwitchBehindAToastRetargetsTheResume() {
        let (overlay, fire, _) = overlayWithManualToasts()
        let token = overlay.show(mode: .downloading)
        overlay.showError("Accessibility permission lost")

        XCTAssertTrue(overlay.show(mode: .loading, in: token))
        XCTAssertEqual(overlay.currentMode, .error, "the toast stays readable")
        XCTAssertEqual(overlay.toastResumeMode, .loading)

        fire()
        XCTAssertEqual(overlay.currentMode, .loading)
        XCTAssertEqual(overlay.session, token)
    }

    func testModeSwitchInALiveSessionKeepsTheToken() {
        let overlay = Overlay()
        let token = overlay.show(mode: .downloading)
        XCTAssertTrue(overlay.show(mode: .loading, in: token))
        XCTAssertEqual(overlay.currentMode, .loading)
        XCTAssertEqual(overlay.session, token)
    }

    func testModeSwitchAfterHideShowsNothing() {
        let overlay = Overlay()
        let token = overlay.show(mode: .downloading)
        overlay.hide(token)
        XCTAssertFalse(overlay.show(mode: .loading, in: token))
        XCTAssertNil(overlay.currentMode)
    }

    // MARK: session ends

    /// The bug the owner hit: tap the hotkey, release at once, nothing captured.
    /// The pill was `.loading`; "No speech detected" went up as a plain toast,
    /// expired 2.5 s later and put `.loading` back — with the session already
    /// over, nothing was left to hide it. A session's last word must not name a
    /// pill to come back to, and must stay the full terminal 5 s.
    func testFinishToastDoesNotResurrectTheSessionPill() {
        let (overlay, fire, delay) = overlayWithManualToasts()
        let token = overlay.show(mode: .loading)
        overlay.finish(.info("No speech detected"), of: token)

        XCTAssertEqual(overlay.currentMode, .error, "the outcome is on screen")
        XCTAssertNil(overlay.toastResumeMode, "and nothing comes back after it")
        XCTAssertEqual(delay(), Overlay.terminalToastSeconds)

        fire()
        XCTAssertNil(overlay.currentMode)
    }

    func testFinishErrorToastDoesNotResurrectTheSessionPill() {
        let overlay = Overlay()
        let token = overlay.show(mode: .loading)
        overlay.finish(.error("No audio captured"), of: token)
        XCTAssertEqual(overlay.currentMode, .error)
        XCTAssertNil(overlay.toastResumeMode)
    }

    func testFinishSilentJustHidesTheSessionPill() {
        let overlay = Overlay()
        let token = overlay.show(mode: .loading)
        overlay.finish(.silent, of: token)
        XCTAssertNil(overlay.currentMode)
        XCTAssertNil(overlay.toastResumeMode)
    }

    /// A last word from an owner whose pill is not the live one is a toast:
    /// the live session comes back after it.
    func testFinishWithAForeignTokenIsAToastOverTheLiveSession() {
        let overlay = Overlay()
        let stale = overlay.show(mode: .loading)
        overlay.finish(.silent, of: stale)
        let live = overlay.show(mode: .recording)

        overlay.finish(.error("Model failed"), of: stale)

        XCTAssertEqual(overlay.currentMode, .error)
        XCTAssertEqual(overlay.toastResumeMode, .recording)
        XCTAssertEqual(overlay.session, live)
    }

    func testFinishWithoutATokenIsAToast() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.finish(.info("Ready"), of: nil)
        XCTAssertEqual(overlay.toastResumeMode, .recording)
    }

    /// A fresh session started while a toast is up must not be captured as
    /// that toast's resume target.
    func testShowClearsAnyPendingResume() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")
        XCTAssertEqual(overlay.toastResumeMode, .recording)

        overlay.show(mode: .loading)
        XCTAssertNil(overlay.toastResumeMode)
        XCTAssertEqual(overlay.currentMode, .loading)
    }

    /// hide means nothing is pending: a toast's delayed work item must not
    /// outlive it and act on whatever is on screen by then.
    func testHideCancelsAPendingToastExpiry() {
        let (overlay, fire, _) = overlayWithManualToasts()
        let token = overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")
        overlay.hide(token)
        XCTAssertNil(overlay.toastResumeMode)

        let next = overlay.show(mode: .loading)
        fire()
        XCTAssertEqual(overlay.currentMode, .loading, "a cancelled expiry does nothing")
        XCTAssertEqual(overlay.session, next)
    }

    // MARK: watchdogs

    /// A watchdog firing while a toast is up must not kill the toast, and the
    /// session pill behind it must not come back when the toast expires. The
    /// toast is terminal now, so it gets the terminal duration.
    func testToastExpiryAfterDismissSessionLeavesNothingOnScreen() {
        let (overlay, fire, delay) = overlayWithManualToasts()
        let token = overlay.show(mode: .downloading)
        overlay.showInfo("Preparing model...")
        XCTAssertEqual(overlay.toastResumeMode, .downloading)

        overlay.dismissSession(token)
        XCTAssertEqual(overlay.currentMode, .error, "the toast stays up")
        XCTAssertNil(overlay.session)
        XCTAssertEqual(delay()!, Overlay.terminalToastSeconds, accuracy: 0.5)

        fire()
        XCTAssertNil(overlay.currentMode, "and nothing comes back after it")
    }

    func testDismissSessionWithoutToastHidesNow() {
        let overlay = Overlay()
        let token = overlay.show(mode: .loading)
        overlay.dismissSession(token)
        XCTAssertNil(overlay.currentMode)
    }

    /// `.loading` is shared by model setup, dictation and call finalization.
    /// A stale watchdog holding the previous owner's token must not tear down
    /// the next owner's pill.
    func testStaleWatchdogTokenCannotDismissTheNextSession() {
        let overlay = Overlay()
        let callToken = overlay.show(mode: .loading)
        overlay.finish(.error("No audio captured"), of: callToken)
        let dictationToken = overlay.show(mode: .loading)

        overlay.dismissSession(callToken)

        XCTAssertEqual(overlay.currentMode, .loading, "the dictation pill is not the call's to dismiss")
        XCTAssertEqual(overlay.session, dictationToken)
    }

    /// The lived shape: the stale watchdog fires while a toast is up over the
    /// NEXT owner's live session.
    func testStaleWatchdogTokenDuringAToastLeavesTheNextSessionIntact() {
        let (overlay, fire, _) = overlayWithManualToasts()
        let setupToken = overlay.show(mode: .downloading)
        overlay.finish(.silent, of: setupToken)
        let recordingToken = overlay.show(mode: .recording)
        overlay.showInfo("Hotkey active")

        overlay.dismissSession(setupToken)
        XCTAssertEqual(overlay.toastResumeMode, .recording)

        fire()
        XCTAssertEqual(overlay.currentMode, .recording)
        XCTAssertEqual(overlay.session, recordingToken)
    }

    /// Model progress switching the setup pill to `.loading` after the watchdog
    /// dismissed it must show nothing — that switch used to resurrect the pill
    /// inside the ending toast.
    func testModeSwitchInADismissedSessionShowsNothing() {
        let (overlay, fire, _) = overlayWithManualToasts()
        let token = overlay.show(mode: .downloading)
        overlay.showInfo("Model loading...")
        overlay.dismissSession(token)

        XCTAssertFalse(overlay.show(mode: .loading, in: token))
        XCTAssertEqual(overlay.currentMode, .error)
        fire()
        XCTAssertNil(overlay.currentMode)
    }
}
