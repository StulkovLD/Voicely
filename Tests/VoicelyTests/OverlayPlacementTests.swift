import AppKit
import XCTest
@testable import Voicely

final class OverlayPlacementTests: XCTestCase {
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let screenB = CGRect(x: 1440, y: 0, width: 1728, height: 1117)
    private let panelSize = CGSize(width: 160, height: 56)

    func testFocusedElementRectKeepsOverlayOnMatchingScreen() throws {
        let placement = try XCTUnwrap(
            OverlayPlacementResolver.resolve(
                OverlayPlacementRequest(
                    screens: [screenA, screenB],
                    focusedElementRect: CGRect(x: 220, y: 420, width: 640, height: 48),
                    focusedWindowRect: CGRect(x: 1500, y: 120, width: 1200, height: 900),
                    fallbackScreen: screenB,
                    panelSize: panelSize
                )
            )
        )

        XCTAssertEqual(placement.screenFrame, screenA)
        XCTAssertEqual(placement.frame.minY, screenA.minY + 140)
        XCTAssertEqual(placement.frame.midX, 540, accuracy: 0.001)
    }

    func testFocusedWindowRectFallsBackWhenElementRectMissing() throws {
        let placement = try XCTUnwrap(
            OverlayPlacementResolver.resolve(
                OverlayPlacementRequest(
                    screens: [screenA, screenB],
                    focusedElementRect: nil,
                    focusedWindowRect: CGRect(x: screenB.minX, y: screenB.minY, width: screenB.width, height: screenB.height),
                    fallbackScreen: screenA,
                    panelSize: panelSize
                )
            )
        )

        XCTAssertEqual(placement.screenFrame, screenB)
        XCTAssertEqual(placement.frame.midX, screenB.midX, accuracy: 0.001)
    }

    func testInvalidFocusedElementRectFallsBackToFocusedWindowRect() throws {
        let placement = try XCTUnwrap(
            OverlayPlacementResolver.resolve(
                OverlayPlacementRequest(
                    screens: [screenA, screenB],
                    focusedElementRect: CGRect(x: -10_000, y: -10_000, width: 80, height: 40),
                    focusedWindowRect: CGRect(x: 1600, y: 140, width: 1200, height: 900),
                    fallbackScreen: screenA,
                    panelSize: panelSize
                )
            )
        )

        XCTAssertEqual(placement.screenFrame, screenB)
        XCTAssertEqual(placement.frame.midX, 2200, accuracy: 0.001)
    }

    func testPlacementClampsToHorizontalMargins() throws {
        let placement = try XCTUnwrap(
            OverlayPlacementResolver.resolve(
                OverlayPlacementRequest(
                    screens: [screenA],
                    focusedElementRect: CGRect(x: screenA.minX + 2, y: 260, width: 30, height: 30),
                    focusedWindowRect: nil,
                    fallbackScreen: screenA,
                    panelSize: panelSize,
                    screenMargin: 24
                )
            )
        )

        XCTAssertEqual(placement.frame.minX, screenA.minX + 24, accuracy: 0.001)
    }

    func testDeterministicFallbackUsesProvidedFallbackScreen() throws {
        let placement = try XCTUnwrap(
            OverlayPlacementResolver.resolve(
                OverlayPlacementRequest(
                    screens: [screenA, screenB],
                    focusedElementRect: nil,
                    focusedWindowRect: nil,
                    fallbackScreen: screenB,
                    panelSize: panelSize
                )
            )
        )

        XCTAssertEqual(placement.screenFrame, screenB)
        XCTAssertEqual(placement.frame.midX, screenB.midX, accuracy: 0.001)
    }

    func testPanelCollectionBehaviorSupportsFullscreenSpaces() {
        let behavior = Overlay.panelCollectionBehavior

        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        // .moveToActiveSpace is mutually exclusive with .canJoinAllSpaces;
        // macOS 26 raises an exception if both are set. canJoinAllSpaces
        // already puts the pill on the user's current space.
        XCTAssertFalse(behavior.contains(.moveToActiveSpace))
        XCTAssertFalse(behavior.contains(.stationary))
    }

    func testOverlayAccessibilityPolicyDistinguishesStatusAndError() {
        let status = Overlay.accessibilityAnnouncement(
            message: "Model ready",
            isError: false
        )
        let error = Overlay.accessibilityAnnouncement(
            message: "Microphone unavailable",
            isError: true
        )

        XCTAssertEqual(status.label, "Voicely status")
        XCTAssertEqual(status.message, "Model ready")
        XCTAssertEqual(status.priority, NSAccessibilityPriorityLevel.medium.rawValue)
        XCTAssertEqual(error.label, "Voicely error")
        XCTAssertEqual(error.message, "Microphone unavailable")
        XCTAssertEqual(error.priority, NSAccessibilityPriorityLevel.high.rawValue)
    }
}
