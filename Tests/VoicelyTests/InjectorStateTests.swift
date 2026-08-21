import XCTest
@testable import Voicely

/// Dictation inserts wherever the caret is at commit time — it is a stand-in for
/// typing, and typing lands where the caret is.
///
/// These replace the capture-at-start pinning tests. Those were not worthless:
/// they were the executable spec of a design that pinned the target captured
/// when dictation began. That spec was retired deliberately — its failure mode
/// was that one stray AX timeout downgraded every healthy target to "changed",
/// so nothing pasted anywhere, in any app. Live-caret's failure mode is "text
/// goes where you were looking", which the user sees and can undo.
final class InjectorStateTests: XCTestCase {

    // MARK: - The three rules

    func testCaretPresentInserts() {
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: false,
                currentSecure: false,
                secureEventInputAtCommit: false,
                caretPresent: true
            ),
            .insert
        )
    }

    /// No caret blinking anywhere ⇒ clipboard, never a silent write.
    func testNoCaretAnywhereCopiesInstead() {
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: false,
                currentSecure: false,
                secureEventInputAtCommit: false,
                caretPresent: false
            ),
            .copyOnly
        )
    }

    // MARK: - Secure beats everything

    /// The one bit kept from capture-at-start. Without it, dictating a password
    /// and then clicking away sees a harmless target at commit and writes the
    /// password to the general pasteboard.
    func testSecureAtStartNeverReachesTheClipboardEvenIfFocusMovedSomewhereSafe() {
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: true,
                currentSecure: false,
                secureEventInputAtCommit: false,
                caretPresent: true
            ),
            .saveOnly,
            "a password dictated at start must never be pasted or copied later"
        )
    }

    func testSecureTargetAtCommitIsRefused() {
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: false,
                currentSecure: true,
                secureEventInputAtCommit: false,
                caretPresent: true
            ),
            .saveOnly
        )
    }

    func testSecureEventInputAtCommitIsRefused() {
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: false,
                currentSecure: false,
                secureEventInputAtCommit: true,
                caretPresent: true
            ),
            .saveOnly
        )
    }

    /// Secure must win over every combination, including "no caret" — otherwise
    /// a password would fall through to the clipboard branch.
    func testSecureWinsOverEveryOtherInput() {
        for currentSecure in [true, false] {
            for sei in [true, false] {
                for caret in [true, false] {
                    XCTAssertEqual(
                        CaretPolicy.decide(
                            startedSecure: true,
                            currentSecure: currentSecure,
                            secureEventInputAtCommit: sei,
                            caretPresent: caret
                        ),
                        .saveOnly,
                        "startedSecure must dominate (current:\(currentSecure) sei:\(sei) caret:\(caret))"
                    )
                }
            }
        }
    }

    // MARK: - Secure detection

    func testSecureAXTargetIsDetectedByRoleOrSubrole() {
        XCTAssertTrue(AXTargetSecurity.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(AXTargetSecurity.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(
            AXTargetSecurity.isSecure(role: "AXTextArea", subrole: nil, secureEventInputEnabled: true)
        )
        XCTAssertFalse(AXTargetSecurity.isSecure(role: "AXTextArea", subrole: nil))
    }

    /// The secure predicate is pure, so it passes whether or not anything calls
    /// it — deleting its wiring would leave this suite green while passwords
    /// leak. This pins the DECISION, not the predicate.
    func testSecureDetectionIsActuallyWiredIntoTheDecision() {
        let secureRole = AXTargetSecurity.isSecure(role: "AXSecureTextField", subrole: nil)
        XCTAssertEqual(
            CaretPolicy.decide(
                startedSecure: false,
                currentSecure: secureRole,
                secureEventInputAtCommit: false,
                caretPresent: true
            ),
            .saveOnly,
            "a secure role must reach a refusal, not merely evaluate to true in isolation"
        )
    }
}
