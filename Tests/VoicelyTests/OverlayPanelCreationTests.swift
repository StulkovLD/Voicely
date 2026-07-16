import AppKit
import XCTest
@testable import Voicely

@MainActor
final class OverlayPanelCreationTests: XCTestCase {
    /// macOS 26 raises NSInternalInconsistencyException from setCollectionBehavior
    /// when .canJoinAllSpaces and .moveToActiveSpace are combined. That crash
    /// happened on the overlay's first panel creation and froze launch at
    /// "Preparing". The collection behavior must be a valid combination.
    func testPanelCollectionBehaviorIsValid() {
        let behavior = Overlay.panelCollectionBehavior
        XCTAssertFalse(
            behavior.contains(.canJoinAllSpaces) && behavior.contains(.moveToActiveSpace),
            "canJoinAllSpaces and moveToActiveSpace are mutually exclusive; macOS raises an exception"
        )

        // Apply it to a real panel exactly as Overlay does — this is the call
        // that threw before the fix.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = behavior
        XCTAssertEqual(panel.collectionBehavior, behavior)
    }

    /// Exercises the full first-show path (createPanelIfNeeded -> setCollectionBehavior
    /// -> panel display) that crashed the app on launch.
    func testShowInfoCreatesPanelWithoutCrashing() {
        let overlay = Overlay()
        overlay.showInfo("Preparing model...")
        overlay.hide()
    }
}
