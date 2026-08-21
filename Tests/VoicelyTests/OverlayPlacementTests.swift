import AppKit
import XCTest
@testable import Voicely

/// The pill attaches to nothing — no focused element, no window. It is centred
/// on the screen the user is on, and it follows them there.
///
/// Attaching it to the focused element is what made the overlay ask
/// Accessibility where the caret was; that query is why it clamped the AX
/// messaging timeout, and that clamp — being process-wide — broke every paste
/// in the product. No AX input reaches this resolver any more, so that whole
/// hazard class cannot return.
final class OverlayPlacementTests: XCTestCase {
    private let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let screenB = CGRect(x: 1440, y: 0, width: 1728, height: 1117)
    private let panelSize = CGSize(width: 160, height: 56)

    private func resolve(
        screens: [CGRect],
        cursor: CGPoint?,
        mainScreen: CGRect? = nil
    ) -> OverlayPlacement? {
        OverlayPlacementResolver.resolve(
            OverlayPlacementRequest(
                screens: screens,
                cursor: cursor,
                mainScreen: mainScreen,
                panelSize: panelSize
            )
        )
    }

    // MARK: - Centred, always

    func testPillIsHorizontallyCentredOnItsScreen() throws {
        let placement = try XCTUnwrap(resolve(screens: [screenA], cursor: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(placement.frame.midX, screenA.midX, accuracy: 0.5)
    }

    /// The bug the owner hit: he moved to a fullscreen app on the second display
    /// and the pill stayed behind on the first. .canJoinAllSpaces puts the panel
    /// on every Space, but at fixed global coordinates — so it must be re-centred
    /// on whichever screen he is on now.
    func testPillFollowsTheUserToTheOtherScreen() throws {
        let onA = try XCTUnwrap(resolve(screens: [screenA, screenB], cursor: CGPoint(x: 700, y: 400)))
        XCTAssertEqual(onA.screenFrame, screenA)
        XCTAssertEqual(onA.frame.midX, screenA.midX, accuracy: 0.5)

        let onB = try XCTUnwrap(resolve(screens: [screenA, screenB], cursor: CGPoint(x: 2300, y: 600)))
        XCTAssertEqual(onB.screenFrame, screenB, "the pill must move to the screen the user is on")
        XCTAssertEqual(onB.frame.midX, screenB.midX, accuracy: 0.5)
    }

    func testPillSitsAboveTheBottomEdgeNotInTheReadingArea() throws {
        let placement = try XCTUnwrap(resolve(screens: [screenA], cursor: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(placement.frame.minY, screenA.minY + 140, accuracy: 0.5)
    }

    // MARK: - Active-screen fallbacks

    func testCursorOffAllScreensFallsBackToMainScreen() throws {
        let placement = try XCTUnwrap(
            resolve(screens: [screenA, screenB], cursor: CGPoint(x: 99_999, y: 99_999), mainScreen: screenB)
        )
        XCTAssertEqual(placement.screenFrame, screenB)
    }

    func testNoCursorAndNoMainScreenIsDeterministic() throws {
        let first = try XCTUnwrap(resolve(screens: [screenB, screenA], cursor: nil))
        let second = try XCTUnwrap(resolve(screens: [screenA, screenB], cursor: nil))
        XCTAssertEqual(first.screenFrame, second.screenFrame, "screen order must not change the answer")
        XCTAssertEqual(first.screenFrame, screenA)
    }

    func testNonFiniteCursorDoesNotPlaceThePillOffScreen() throws {
        let placement = try XCTUnwrap(
            resolve(
                screens: [screenA],
                cursor: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                mainScreen: screenA
            )
        )
        XCTAssertEqual(placement.screenFrame, screenA)
        XCTAssertTrue(screenA.contains(placement.frame.origin))
    }

    func testNoScreensYieldsNoPlacement() {
        XCTAssertNil(resolve(screens: [], cursor: CGPoint(x: 0, y: 0)))
    }

    // MARK: - Panel flags

    func testPanelCollectionBehaviorSupportsFullscreenSpaces() {
        let behavior = Overlay.panelCollectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        // .fullScreenAuxiliary only offers the pill to our OWN fullscreen window.
        // Following another app into its fullscreen Space needs this one.
        XCTAssertTrue(behavior.contains(.canJoinAllApplications))
        // .moveToActiveSpace is mutually exclusive with .canJoinAllSpaces;
        // macOS 26 raises an exception if both are set. canJoinAllSpaces
        // keeps the pill resident on every Space instead.
        XCTAssertFalse(behavior.contains(.moveToActiveSpace))
        XCTAssertFalse(behavior.contains(.stationary))
    }
}
