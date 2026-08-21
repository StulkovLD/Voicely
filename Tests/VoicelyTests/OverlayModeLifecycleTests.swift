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

    func testShowAfterHideRepublishesMode() {
        let overlay = Overlay()
        overlay.show(mode: .recording)
        overlay.hide()
        overlay.show(mode: .loading)

        XCTAssertEqual(overlay.currentMode, .loading, "a fresh show must re-arm the mode")
    }
}
