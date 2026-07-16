import AppKit
import XCTest
@testable import Voicely

final class MenuBarIconRenderTests: XCTestCase {
    /// AppKit invokes NSImage drawing handlers from its rendering machinery,
    /// outside any Swift concurrency context. Rendering the menu-bar icon from
    /// a plain background thread reproduces that environment: a
    /// MainActor-inherited drawing closure crashes the process here
    /// (SIGSEGV in the runtime executor check), which is exactly how the app
    /// died on launch on macOS 26.
    func testMenuBarIconRendersOffMainThread() {
        // NSImage is intentionally carried across threads: AppKit renders
        // status items on its own machinery, and reproducing that hand-off is
        // the whole point of this test.
        struct ImageBox: @unchecked Sendable { let image: NSImage }
        let box = MainActor.assumeIsolated {
            ImageBox(image: AppDelegate.makeMenuBarIcon())
        }

        let expectation = expectation(description: "render finished")
        Thread.detachNewThread {
            var rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            let cgImage = box.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            XCTAssertNotNil(cgImage, "menu-bar icon must render off the main thread")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testDrawingHandlerIsCallableFromAnyContext() {
        // The handler itself must stay nonisolated; calling it directly from a
        // nonisolated test context fails to compile if isolation regresses.
        let didDraw = renderDirectly()
        XCTAssertTrue(didDraw)
    }

    private nonisolated func renderDirectly() -> Bool {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }
        return AppDelegate.drawMenuBarIconBars(NSRect(x: 0, y: 0, width: 18, height: 18))
    }
}
