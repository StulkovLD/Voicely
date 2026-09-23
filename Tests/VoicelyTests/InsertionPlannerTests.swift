import XCTest
@testable import Voicely

/// The decision "where and by which channels" as a table. Text goes wherever
/// the caret is at commit time; secure beats everything; Chromium apps never
/// get an Accessibility write (it answers success and drops the text).
final class InsertionPlannerTests: XCTestCase {
    private func plan(
        destination: DictationDestination = .atCursor,
        startedSecure: Bool = false,
        sei: Bool = false,
        front: FrontApp = .app,
        focus: FocusKind = .editableText,
        engine: AppEngine = .native,
        inWebArea: Bool = false
    ) -> InsertionPlan {
        InsertionPlanner.plan(InsertionSignals(
            destination: destination,
            startedSecure: startedSecure,
            secureEventInput: sei,
            front: front,
            focus: focus,
            engine: engine,
            inWebArea: inWebArea
        ))
    }

    // MARK: - Secure beats everything

    /// A password dictated at start must never be pasted, typed or copied later,
    /// whatever the focus is at commit — including "no caret" and the explicit
    /// clipboard destination.
    func testSecureWinsOverEveryOtherInput() {
        let focuses: [FocusKind] = [.silent, .secure, .editableText, .readOnlyText, .terminalInput, .other]
        for destination in DictationDestination.allCases {
            for front in [FrontApp.none, .voicely, .finder, .app] {
                for focus in focuses {
                    for engine in [AppEngine.native, .chromium] {
                        XCTAssertEqual(
                            plan(destination: destination, startedSecure: true, front: front, focus: focus, engine: engine),
                            .saveOnly
                        )
                        XCTAssertEqual(
                            plan(destination: destination, sei: true, front: front, focus: focus, engine: engine),
                            .saveOnly
                        )
                    }
                }
            }
        }
    }

    func testSecureFocusAtCommitIsRefused() {
        XCTAssertEqual(plan(focus: .secure), .saveOnly)
        XCTAssertEqual(plan(destination: .clipboardOnly, focus: .secure), .saveOnly)
    }

    func testSecureAXTargetIsDetectedByRoleOrSubrole() {
        XCTAssertTrue(AXTargetSecurity.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(AXTargetSecurity.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(AXTargetSecurity.isSecure(role: "AXTextArea", subrole: nil, secureEventInputEnabled: true))
        XCTAssertFalse(AXTargetSecurity.isSecure(role: "AXTextArea", subrole: nil))
    }

    // MARK: - No caret to aim at

    func testClipboardDestinationNeverTouchesTheFocusedApp() {
        XCTAssertEqual(plan(destination: .clipboardOnly), .copyOnly(reason: "destination"))
        XCTAssertEqual(plan(destination: .clipboardOnly, focus: .silent, engine: .chromium), .copyOnly(reason: "destination"))
    }

    /// The desktop stays clipboard {owner's word: "это правильно"}: typing at
    /// Finder type-selects files, Cmd+V there pastes a file.
    func testFinderWithoutACaretCopies() {
        for focus in [FocusKind.silent, .readOnlyText, .other, .terminalInput] {
            XCTAssertEqual(plan(front: .finder, focus: focus), .copyOnly(reason: "desktop"))
        }
    }

    /// Renaming a file is a real caret in a native field.
    func testFinderRenameFieldIsAnEditableNativeField() {
        XCTAssertEqual(plan(front: .finder, focus: .editableText), .deliver([.ax, .paste, .typing]))
    }

    func testNoFrontAppOrVoicelyItselfCopies() {
        XCTAssertEqual(plan(front: .none, focus: .silent), .copyOnly(reason: "no_front_app"))
        XCTAssertEqual(plan(front: .voicely), .copyOnly(reason: "voicely_front"))
    }

    // MARK: - Channels by class

    /// Native Cocoa text outside web content: Accessibility first, because its
    /// read-back is honest there; a write that changed nothing hands over.
    func testNativeEditableTextTriesAccessibilityThenPaste() {
        XCTAssertEqual(plan(focus: .editableText, engine: .native), .deliver([.ax, .paste, .typing]))
    }

    /// The owner's 94 %: VS Code, Chrome, Claude, Codex. Whatever their AX tree
    /// says today, the text goes by Cmd+V.
    func testChromiumNeverGetsAnAccessibilityWrite() {
        for focus in [FocusKind.editableText, .readOnlyText, .silent] {
            let result = plan(focus: focus, engine: .chromium)
            XCTAssertEqual(result, .deliver([.paste, .typing]), "focus \(focus)")
        }
        XCTAssertEqual(plan(focus: .other, engine: .chromium), .deliver([.paste]))
    }

    /// Safari and Firefox fields: an AX write can show text a React field never
    /// hears about, so web content is pasted even in a native browser.
    func testWebContentInANativeBrowserIsPasted() {
        XCTAssertEqual(plan(focus: .editableText, engine: .native, inWebArea: true), .deliver([.paste, .typing]))
    }

    /// Terminal.app, iTerm2, Qt fields: text surfaces AX cannot write take typed text.
    func testNativeReadOnlyTextSurfaceIsTyped() {
        XCTAssertEqual(plan(focus: .readOnlyText, engine: .native), .deliver([.typing]))
    }

    /// VS Code's terminal, when its AX tree is on and names xterm's textarea.
    func testXtermInputIsTyped() {
        XCTAssertEqual(plan(focus: .terminalInput, engine: .chromium), .deliver([.typing]))
    }

    /// Silent AX (VS Code by default): the terminal and the editor look alike.
    /// Cmd+V first; typing only if no app read the transcript at all.
    func testSilentFocusPastesThenTypes() {
        XCTAssertEqual(plan(focus: .silent, engine: .chromium), .deliver([.paste, .typing]))
        XCTAssertEqual(plan(focus: .silent, engine: .native), .deliver([.paste, .typing]))
    }

    /// A focused list, canvas or page body: typing would fire single-key
    /// shortcuts, so only Cmd+V is tried.
    func testNonTextFocusIsNeverTyped() {
        for engine in [AppEngine.native, .chromium] {
            guard case .deliver(let channels) = plan(focus: .other, engine: engine) else {
                return XCTFail("non-text focus must still try a paste")
            }
            XCTAssertFalse(channels.contains(.typing))
            XCTAssertFalse(channels.contains(.ax))
        }
    }

    /// Every plan that delivers ends with a channel that does not depend on AX.
    func testEveryDeliveringPlanHasAKeyChannel() {
        let focuses: [FocusKind] = [.silent, .editableText, .readOnlyText, .terminalInput, .other]
        for focus in focuses {
            for engine in [AppEngine.native, .chromium] {
                for inWebArea in [false, true] {
                    if case .deliver(let channels) = plan(focus: focus, engine: engine, inWebArea: inWebArea) {
                        XCTAssertTrue(channels.contains(.paste) || channels.contains(.typing), "\(focus) \(engine)")
                        if engine == .chromium { XCTAssertFalse(channels.contains(.ax)) }
                        if inWebArea { XCTAssertFalse(channels.contains(.ax)) }
                    }
                }
            }
        }
    }
}
