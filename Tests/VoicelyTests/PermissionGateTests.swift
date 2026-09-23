import AppKit
import XCTest
@testable import Voicely

// MARK: - Plan and copy (pure)

final class PermissionPlanTests: XCTestCase {
    private func status(_ microphone: MicrophoneAccess, _ accessibility: Bool) -> PermissionStatus {
        PermissionStatus(microphone: microphone, accessibility: accessibility)
    }

    private func next(
        _ status: PermissionStatus,
        askedMicrophone: Bool = false,
        clearedMicrophone: Bool = false,
        askedAccessibility: Bool = false
    ) -> PermissionStep {
        PermissionPlan.next(
            status: status,
            askedMicrophone: askedMicrophone,
            clearedMicrophone: clearedMicrophone,
            askedAccessibility: askedAccessibility
        )
    }

    func testCompleteAccessIsDone() {
        XCTAssertEqual(next(status(.granted, true)), .done)
    }

    func testMicrophoneComesFirstAndIsAskedOnce() {
        XCTAssertEqual(next(status(.notDetermined, false)), .askMicrophone)
        XCTAssertEqual(next(status(.notDetermined, false), askedMicrophone: true), .waitMicrophone)
    }

    func testEarlierDenialIsClearedSoMacOSCanAskAgain() {
        XCTAssertEqual(next(status(.denied, true)), .clearMicrophone)
    }

    func testDenialAfterAskingOrClearingLeadsToSettings() {
        XCTAssertEqual(next(status(.denied, true), clearedMicrophone: true), .microphoneSettings)
        XCTAssertEqual(next(status(.denied, true), askedMicrophone: true), .microphoneSettings)
    }

    func testMissingAccessibilityIsClearedAndPromptedOnceThenWatched() {
        XCTAssertEqual(next(status(.granted, false)), .askAccessibility)
        XCTAssertEqual(next(status(.granted, false), askedAccessibility: true), .waitAccessibility)
    }

    func testDictationNeedsMicrophoneAndAtCursorNeedsAccessibility() {
        XCTAssertTrue(PermissionPlan.canDictate(status: status(.granted, true), destination: .atCursor))
        XCTAssertFalse(PermissionPlan.canDictate(status: status(.granted, false), destination: .atCursor))
        XCTAssertTrue(PermissionPlan.canDictate(status: status(.granted, false), destination: .clipboardOnly))
        XCTAssertFalse(PermissionPlan.canDictate(status: status(.denied, true), destination: .atCursor))
        XCTAssertFalse(PermissionPlan.canDictate(status: status(.notDetermined, true), destination: .clipboardOnly))
    }

    func testCopyFollowsTheFirstPreferredLanguage() {
        XCTAssertEqual(PermissionCopy.forLanguages(["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(PermissionCopy.forLanguages(["RU"]), .russian)
        XCTAssertEqual(PermissionCopy.forLanguages(["en-US", "ru-RU"]), .english)
        XCTAssertEqual(PermissionCopy.forLanguages(["uk-UA"]), .english)
        XCTAssertEqual(PermissionCopy.forLanguages([]), .english)
    }

    /// Owner's word 2026-09-23: nothing to read and no list surgery. The
    /// window never tells anyone to remove and re-add Voicely.
    func testCopyNeverAsksForListSurgery() {
        for copy in [PermissionCopy.english, .russian] {
            let texts = [
                copy.title, copy.microphoneRow, copy.accessibilityRow, copy.askMicrophone,
                copy.microphoneOff, copy.turnOnAccessibility, copy.ready,
                copy.allowMicrophoneButton, copy.openMicrophoneButton,
                copy.openAccessibilityButton, copy.doneButton,
            ]
            for text in texts {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains("+"), text)
                XCTAssertFalse(text.contains("−"), text)
                XCTAssertFalse(text.lowercased().contains("remove"), text)
                XCTAssertFalse(text.lowercased().contains("удал"), text)
            }
        }
    }

    func testScreenButtonMatchesTheStep() {
        let missing = status(.notDetermined, false)
        let copy = PermissionCopy.english
        XCTAssertEqual(
            PermissionScreen.make(status: missing, step: .askMicrophone, copy: copy).buttonAction,
            .requestMicrophone
        )
        XCTAssertEqual(
            PermissionScreen.make(status: status(.denied, false), step: .microphoneSettings, copy: copy).buttonAction,
            .openSettings(.microphone)
        )
        let accessibility = PermissionScreen.make(status: status(.granted, false), step: .waitAccessibility, copy: copy)
        XCTAssertEqual(accessibility.buttonAction, .openSettings(.accessibility))
        XCTAssertEqual(accessibility.message, copy.turnOnAccessibility)
        XCTAssertEqual(accessibility.rows.map(\.granted), [true, false])
        let done = PermissionScreen.make(status: status(.granted, true), step: .done, copy: copy)
        XCTAssertEqual(done.buttonAction, .close)
        XCTAssertEqual(done.rows.map(\.granted), [true, true])
    }
}

// MARK: - The gate against a scripted macOS

@MainActor
private final class ScriptedSystem: PermissionSystem {
    var current: PermissionStatus
    var calls: [String] = []
    /// What the person answers in the microphone prompt.
    var microphoneAnswer: MicrophoneAccess = .granted
    /// What clearing Voicely's microphone entry leaves behind.
    var microphoneAfterClear: MicrophoneAccess = .notDetermined
    /// Status reads after the Accessibility prompt until the person flips the switch.
    var accessibilityOnAfterReads: Int?
    private var readsSincePrompt = 0
    private var prompted = false

    init(_ current: PermissionStatus) {
        self.current = current
    }

    func status() -> PermissionStatus {
        if prompted, let reads = accessibilityOnAfterReads {
            readsSincePrompt += 1
            if readsSincePrompt >= reads { current.accessibility = true }
        }
        return current
    }

    func requestMicrophone() async -> Bool {
        calls.append("requestMicrophone")
        current.microphone = microphoneAnswer
        return microphoneAnswer == .granted
    }

    func promptAccessibility() {
        calls.append("promptAccessibility")
        prompted = true
    }

    func clearOwnEntry(_ service: PrivacyService) async {
        calls.append("clear:\(service.rawValue)")
        if service == .microphone { current.microphone = microphoneAfterClear }
    }

    func openSettings(_ service: PrivacyService) {
        calls.append("open:\(service.rawValue)")
    }
}

@MainActor
private final class RecordingPresenter: PermissionPresenter {
    var onButton: (() -> Void)?
    var closedByPerson = false
    var shown = 0
    var closed = 0
    var screens: [PermissionScreen] = []
    var onRender: ((PermissionScreen, RecordingPresenter) -> Void)?

    func show() { shown += 1 }
    func render(_ screen: PermissionScreen) {
        screens.append(screen)
        onRender?(screen, self)
    }
    func close() { closed += 1 }
}

@MainActor
private final class PresenterLog {
    var made: [RecordingPresenter] = []
}

@MainActor
final class PermissionGateTests: XCTestCase {
    private func makeGate(
        _ system: ScriptedSystem,
        presenters: @escaping @MainActor (RecordingPresenter) -> Void = { _ in }
    ) -> (PermissionGate, () -> [RecordingPresenter]) {
        let log = PresenterLog()
        let gate = PermissionGate(
            system: system,
            copy: .english,
            pollInterval: .milliseconds(5),
            doneLinger: .zero,
            makePresenter: { _ in
                let presenter = RecordingPresenter()
                presenters(presenter)
                log.made.append(presenter)
                return presenter
            }
        )
        return (gate, { log.made })
    }

    func testCompleteAccessShowsNothing() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .granted, accessibility: true))
        let (gate, presenters) = makeGate(system)
        let result = await gate.ensure()
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(presenters().isEmpty)
        XCTAssertTrue(system.calls.isEmpty)
    }

    /// First launch, and the update from an ad-hoc build after the installer
    /// cleared the old entries: two system prompts, one switch, window closes.
    func testFreshMachineAsksMacOSAndClosesWhenBothAreOn() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .notDetermined, accessibility: false))
        system.accessibilityOnAfterReads = 3
        let (gate, presenters) = makeGate(system)
        let result = await gate.ensure()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(system.calls, ["requestMicrophone", "clear:Accessibility", "promptAccessibility"])
        let presenter = try? XCTUnwrap(presenters().first)
        XCTAssertEqual(presenters().count, 1)
        XCTAssertEqual(presenter?.shown, 1)
        XCTAssertEqual(presenter?.closed, 1)
        XCTAssertEqual(presenter?.screens.last?.buttonAction, .close)
        XCTAssertEqual(presenter?.screens.last?.rows.map(\.granted), [true, true])
    }

    /// The case the owner hit: the switch shows "on" for an older copy, yet
    /// macOS no longer trusts this one. Voicely clears its own entry once and
    /// asks again; it never loops on clearing while it waits.
    func testStaleAccessibilityEntryIsClearedOnceAndPromptedOnce() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .granted, accessibility: false))
        system.accessibilityOnAfterReads = 12
        let (gate, _) = makeGate(system)
        let result = await gate.ensure()

        XCTAssertTrue(result.accessibility)
        XCTAssertEqual(system.calls.filter { $0 == "clear:Accessibility" }.count, 1)
        XCTAssertEqual(system.calls.filter { $0 == "promptAccessibility" }.count, 1)
        XCTAssertFalse(system.calls.contains("clear:Microphone"))
    }

    func testEarlierMicrophoneDenialIsClearedAndAskedAgain() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .denied, accessibility: true))
        let (gate, _) = makeGate(system)
        let result = await gate.ensure()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(system.calls, ["clear:Microphone", "requestMicrophone"])
    }

    func testDenialInThisSessionOffersSettingsAndStopsWhenThePersonCloses() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .notDetermined, accessibility: true))
        system.microphoneAnswer = .denied
        let (gate, presenters) = makeGate(system) { presenter in
            presenter.onRender = { screen, presenter in
                guard screen.buttonAction == .openSettings(.microphone) else { return }
                presenter.onButton?()
                presenter.closedByPerson = true
            }
        }
        let result = await gate.ensure()

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(system.calls, ["requestMicrophone", "open:Microphone"])
        XCTAssertEqual(presenters().first?.closed, 0, "the person closed it; the gate must not close it again")
    }

    func testConcurrentCallersShareOneWindow() async {
        let system = ScriptedSystem(PermissionStatus(microphone: .granted, accessibility: false))
        system.accessibilityOnAfterReads = 4
        let (gate, presenters) = makeGate(system)
        async let first = gate.ensure()
        async let second = gate.ensure()
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy(\.isComplete))
        XCTAssertEqual(presenters().count, 1)
        XCTAssertEqual(system.calls.filter { $0 == "promptAccessibility" }.count, 1)
    }

    func testOnlyVoicelysOwnIdentityIsEverReset() {
        XCTAssertEqual(MacPermissionSystem.resettableIdentity("art.voicely.app"), "art.voicely.app")
        XCTAssertNil(MacPermissionSystem.resettableIdentity(nil), "unbundled runs reset nothing")
        XCTAssertNil(MacPermissionSystem.resettableIdentity("com.apple.dt.xctest.tool"))
        XCTAssertNil(MacPermissionSystem.resettableIdentity("art.voicely.appx"))
    }
}

// MARK: - The window

@MainActor
final class PermissionWindowTests: XCTestCase {
    func testWindowShowsTheScreenInTheSystemLanguage() {
        let controller = PermissionWindowController(copy: .russian)
        let screen = PermissionScreen.make(
            status: PermissionStatus(microphone: .granted, accessibility: false),
            step: .waitAccessibility,
            copy: .russian
        )
        controller.render(screen)

        XCTAssertEqual(controller.titleText, "Voicely нужны два разрешения")
        XCTAssertEqual(controller.rowTexts, [PermissionCopy.russian.microphoneRow, PermissionCopy.russian.accessibilityRow])
        XCTAssertEqual(controller.rowGranted, [true, false])
        XCTAssertEqual(controller.messageText, PermissionCopy.russian.turnOnAccessibility)
        XCTAssertEqual(controller.buttonTitle, PermissionCopy.russian.openAccessibilityButton)
    }

    func testTheOneButtonRunsTheCurrentAction() throws {
        let controller = PermissionWindowController(copy: .english)
        var pressed = 0
        controller.onButton = { pressed += 1 }
        let button = try XCTUnwrap(Self.buttons(in: controller.window.contentView).first)
        button.performClick(nil)
        XCTAssertEqual(pressed, 1)
        XCTAssertEqual(Self.buttons(in: controller.window.contentView).count, 1, "one button, no choices")
    }

    func testClosingByHandIsTheOnlyCloseThatCountsAsThePersons() {
        let byHand = PermissionWindowController(copy: .english)
        byHand.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertTrue(byHand.closedByPerson)

        let byGate = PermissionWindowController(copy: .english)
        byGate.close()
        XCTAssertFalse(byGate.closedByPerson)
    }

    func testLongestTextsFitWithoutTruncation() {
        for copy in [PermissionCopy.english, .russian] {
            let controller = PermissionWindowController(copy: copy)
            controller.render(PermissionScreen.make(
                status: PermissionStatus(microphone: .denied, accessibility: false),
                step: .microphoneSettings,
                copy: copy
            ))
            controller.window.contentView?.layoutSubtreeIfNeeded()
            let fitting = controller.window.contentView?.fittingSize ?? .zero
            XCTAssertLessThanOrEqual(fitting.width, 520, "window grows too wide for \(copy.title)")
            XCTAssertLessThanOrEqual(fitting.height, 320, "window grows too tall for \(copy.title)")
        }
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }
}
