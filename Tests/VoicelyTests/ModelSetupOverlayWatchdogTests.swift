import XCTest
@testable import Voicely

/// The model-setup pill passes through two modes: `.downloading` while bytes
/// arrive, then `.loading` while CoreML compiles. The 10-second watchdog that
/// dismisses it used to recognise only `.downloading`, so the switch to
/// `.loading` disarmed it — and `.loading` has no auto-hide. The pill stayed up
/// forever.
final class ModelSetupOverlayWatchdogTests: XCTestCase {

    func testWatchdogFiresWhileDownloading() {
        XCTAssertTrue(AppDelegate.isModelSetupOverlay(.downloading))
    }

    /// The regression: progress reaching `.loadingModel` switches the pill to
    /// `.loading`, and the watchdog must still own it.
    func testWatchdogSurvivesTheSwitchToLoading() {
        XCTAssertTrue(
            AppDelegate.isModelSetupOverlay(.loading),
            "the pill is still the model-setup pill after it switches to .loading"
        )
    }

    /// A hidden pill must not answer the watchdog — otherwise it would tear down
    /// whatever unrelated panel came after it.
    func testWatchdogIgnoresAHiddenOverlay() {
        XCTAssertFalse(AppDelegate.isModelSetupOverlay(nil))
    }

    func testWatchdogIgnoresUnrelatedModes() {
        XCTAssertFalse(AppDelegate.isModelSetupOverlay(.recording))
        XCTAssertFalse(AppDelegate.isModelSetupOverlay(.error))
        XCTAssertFalse(AppDelegate.isModelSetupOverlay(.fileQueue(title: "x", progress: 0.5)))
        XCTAssertFalse(AppDelegate.isModelSetupOverlay(.fileQueuePaused(title: "x")))
    }
}
