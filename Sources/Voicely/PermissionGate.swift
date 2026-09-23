import AppKit
import ApplicationServices
import AVFoundation

// MARK: - What Voicely needs from macOS

/// Microphone access as macOS reports it. `restricted` (MDM) reads as denied.
enum MicrophoneAccess: Sendable, Equatable {
    case granted
    case notDetermined
    case denied
}

/// The two grants dictation at the cursor stands on: the microphone hears,
/// Accessibility runs the hotkey and types into the focused app.
struct PermissionStatus: Sendable, Equatable {
    var microphone: MicrophoneAccess
    var accessibility: Bool

    var isComplete: Bool { microphone == .granted && accessibility }
}

/// A privacy service whose entry Voicely may clear for itself.
enum PrivacyService: String, Sendable, Equatable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
}

/// What the gate does next. Pure; pinned by PermissionGateTests.
enum PermissionStep: Sendable, Equatable {
    /// Ask macOS to show its microphone prompt.
    case askMicrophone
    /// The prompt was answered but macOS has not settled yet; keep watching.
    case waitMicrophone
    /// Denied before this session (or a leftover of an older copy): clear
    /// Voicely's own entry so macOS can ask again.
    case clearMicrophone
    /// Denied in this session: only the person can switch it on in Settings.
    case microphoneSettings
    /// Clear Voicely's own Accessibility entry (an entry left by an older copy
    /// shows as switched on yet grants nothing) and show the system prompt.
    case askAccessibility
    /// The prompt is up or Settings is open; watch until the switch is on.
    case waitAccessibility
    case done
}

enum PermissionPlan {
    static func next(
        status: PermissionStatus,
        askedMicrophone: Bool,
        clearedMicrophone: Bool,
        askedAccessibility: Bool
    ) -> PermissionStep {
        switch status.microphone {
        case .notDetermined:
            return askedMicrophone ? .waitMicrophone : .askMicrophone
        case .denied:
            return askedMicrophone || clearedMicrophone ? .microphoneSettings : .clearMicrophone
        case .granted:
            break
        }
        if !status.accessibility {
            return askedAccessibility ? .waitAccessibility : .askAccessibility
        }
        return .done
    }

    /// Whether a dictation may start. Without the microphone nothing is heard;
    /// without Accessibility nothing reaches the cursor, which used to fail
    /// silently. Clipboard-only output needs the microphone alone.
    static func canDictate(status: PermissionStatus, destination: DictationDestination) -> Bool {
        guard status.microphone == .granted else { return false }
        return destination == .clipboardOnly || status.accessibility
    }
}

// MARK: - Words on the window

/// The permission window's text, English or Russian by the system language.
struct PermissionCopy: Sendable, Equatable {
    let title: String
    let microphoneRow: String
    let accessibilityRow: String
    let askMicrophone: String
    let microphoneOff: String
    let turnOnAccessibility: String
    let ready: String
    let allowMicrophoneButton: String
    let openMicrophoneButton: String
    let openAccessibilityButton: String
    let doneButton: String

    static let english = PermissionCopy(
        title: "Voicely needs two permissions",
        microphoneRow: "Microphone – to hear you",
        accessibilityRow: "Accessibility – to type at your cursor",
        askMicrophone: "Click Allow in the macOS prompt.",
        microphoneOff: "Microphone access is off. Open Settings and switch Voicely on.",
        turnOnAccessibility: "Switch Voicely on in the list that opens. This window closes by itself.",
        ready: "All set. Voicely is ready.",
        allowMicrophoneButton: "Allow Microphone",
        openMicrophoneButton: "Open Microphone Settings",
        openAccessibilityButton: "Open Accessibility Settings",
        doneButton: "Done"
    )

    static let russian = PermissionCopy(
        title: "Voicely нужны два разрешения",
        microphoneRow: "Микрофон – чтобы слышать вас",
        accessibilityRow: "Универсальный доступ – чтобы печатать у курсора",
        askMicrophone: "Нажмите «Разрешить» в окне macOS.",
        microphoneOff: "Доступ к микрофону выключен. Откройте настройки и включите Voicely.",
        turnOnAccessibility: "Включите Voicely в открывшемся списке. Это окно закроется само.",
        ready: "Готово. Voicely работает.",
        allowMicrophoneButton: "Разрешить микрофон",
        openMicrophoneButton: "Открыть настройки микрофона",
        openAccessibilityButton: "Открыть Универсальный доступ",
        doneButton: "Готово"
    )

    static func forLanguages(_ preferredLanguages: [String]) -> PermissionCopy {
        guard let first = preferredLanguages.first?.lowercased() else { return .english }
        return first.hasPrefix("ru") ? .russian : .english
    }
}

/// What the single button does.
enum PermissionButtonAction: Sendable, Equatable {
    case requestMicrophone
    case openSettings(PrivacyService)
    case close
}

/// Everything the window shows for one state. Pure.
struct PermissionScreen: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        let label: String
        let granted: Bool
    }

    let title: String
    let rows: [Row]
    let message: String
    let buttonTitle: String
    let buttonAction: PermissionButtonAction

    static func make(
        status: PermissionStatus,
        step: PermissionStep,
        copy: PermissionCopy
    ) -> PermissionScreen {
        let rows = [
            Row(label: copy.microphoneRow, granted: status.microphone == .granted),
            Row(label: copy.accessibilityRow, granted: status.accessibility),
        ]
        let message: String
        let buttonTitle: String
        let action: PermissionButtonAction
        switch step {
        case .askMicrophone, .waitMicrophone, .clearMicrophone:
            message = copy.askMicrophone
            buttonTitle = copy.allowMicrophoneButton
            action = .requestMicrophone
        case .microphoneSettings:
            message = copy.microphoneOff
            buttonTitle = copy.openMicrophoneButton
            action = .openSettings(.microphone)
        case .askAccessibility, .waitAccessibility:
            message = copy.turnOnAccessibility
            buttonTitle = copy.openAccessibilityButton
            action = .openSettings(.accessibility)
        case .done:
            message = copy.ready
            buttonTitle = copy.doneButton
            action = .close
        }
        return PermissionScreen(
            title: copy.title,
            rows: rows,
            message: message,
            buttonTitle: buttonTitle,
            buttonAction: action
        )
    }
}

// MARK: - macOS behind a seam

@MainActor
protocol PermissionSystem: AnyObject {
    func status() -> PermissionStatus
    func requestMicrophone() async -> Bool
    /// Shows the system Accessibility prompt and adds Voicely to the list.
    func promptAccessibility()
    /// Clears only Voicely's own entry for one service.
    func clearOwnEntry(_ service: PrivacyService) async
    func openSettings(_ service: PrivacyService)
}

@MainActor
protocol PermissionPresenter: AnyObject {
    var onButton: (() -> Void)? { get set }
    var closedByPerson: Bool { get }
    func show()
    func render(_ screen: PermissionScreen)
    func close()
}

@MainActor
final class MacPermissionSystem: PermissionSystem {
    private let bundleIdentifier: String?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.bundleIdentifier = bundleIdentifier
    }

    func status() -> PermissionStatus {
        let microphone: MicrophoneAccess
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        case .denied, .restricted: microphone = .denied
        @unknown default: microphone = .denied
        }
        return PermissionStatus(microphone: microphone, accessibility: AXIsProcessTrusted())
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func promptAccessibility() {
        // The option's documented key, spelled out: the imported global is a
        // mutable C variable that Swift 6 refuses to read across isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The one identity whose entries Voicely may clear: its own. Unbundled
    /// runs (swift run, tests) have none and must never reset anything.
    nonisolated static func resettableIdentity(_ bundleIdentifier: String?) -> String? {
        bundleIdentifier == "art.voicely.app" ? bundleIdentifier : nil
    }

    func clearOwnEntry(_ service: PrivacyService) async {
        guard let identity = Self.resettableIdentity(bundleIdentifier) else { return }
        let arguments = ["reset", service.rawValue, identity]
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("[Voicely] tccutil reset %@ failed: %@", arguments[1], error.localizedDescription)
            }
        }.value
    }

    func openSettings(_ service: PrivacyService) {
        let anchor = service == .microphone ? "Privacy_Microphone" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - The gate

/// Brings Voicely to full access by asking macOS itself: the person answers
/// the system prompts and flips one switch; nothing to read, nothing to find.
/// Shows a small window while anything is missing and closes it once both
/// grants are on.
@MainActor
final class PermissionGate {
    private let system: PermissionSystem
    private let copy: PermissionCopy
    private let pollInterval: Duration
    private let doneLinger: Duration
    private let makePresenter: @MainActor (PermissionCopy) -> PermissionPresenter
    private var running: Task<PermissionStatus, Never>?

    init(
        system: PermissionSystem,
        copy: PermissionCopy = .forLanguages(Locale.preferredLanguages),
        pollInterval: Duration = .milliseconds(500),
        doneLinger: Duration = .milliseconds(900),
        makePresenter: @escaping @MainActor (PermissionCopy) -> PermissionPresenter = {
            PermissionWindowController(copy: $0)
        }
    ) {
        self.system = system
        self.copy = copy
        self.pollInterval = pollInterval
        self.doneLinger = doneLinger
        self.makePresenter = makePresenter
    }

    func currentStatus() -> PermissionStatus {
        system.status()
    }

    /// Returns when both grants are on, or when the person closes the window.
    /// Concurrent callers share one window and one answer.
    func ensure() async -> PermissionStatus {
        if let running {
            return await running.value
        }
        let task = Task { await self.run() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    private func run() async -> PermissionStatus {
        var status = system.status()
        guard !status.isComplete else { return status }

        let presenter = makePresenter(copy)
        var askedMicrophone = false
        var clearedMicrophone = false
        var askedAccessibility = false
        var buttonAction: PermissionButtonAction = .close
        presenter.onButton = { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            switch buttonAction {
            case .requestMicrophone:
                Task { _ = await self.system.requestMicrophone() }
            case .openSettings(let service):
                self.system.openSettings(service)
            case .close:
                presenter.close()
            }
        }
        presenter.show()

        while true {
            status = system.status()
            let step = PermissionPlan.next(
                status: status,
                askedMicrophone: askedMicrophone,
                clearedMicrophone: clearedMicrophone,
                askedAccessibility: askedAccessibility
            )
            let screen = PermissionScreen.make(status: status, step: step, copy: copy)
            buttonAction = screen.buttonAction
            presenter.render(screen)

            switch step {
            case .done:
                try? await Task.sleep(for: doneLinger)
                presenter.close()
                return system.status()
            case .askMicrophone:
                askedMicrophone = true
                _ = await system.requestMicrophone()
                continue
            case .clearMicrophone:
                clearedMicrophone = true
                await system.clearOwnEntry(.microphone)
                continue
            case .askAccessibility:
                askedAccessibility = true
                await system.clearOwnEntry(.accessibility)
                system.promptAccessibility()
            case .waitMicrophone, .microphoneSettings, .waitAccessibility:
                break
            }

            if presenter.closedByPerson {
                return system.status()
            }
            try? await Task.sleep(for: pollInterval)
            if presenter.closedByPerson {
                return system.status()
            }
        }
    }
}

// MARK: - The window

@MainActor
final class PermissionWindowController: NSObject, NSWindowDelegate, PermissionPresenter {
    var onButton: (() -> Void)?
    private(set) var closedByPerson = false

    let window: NSPanel
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var rowIcons: [NSImageView] = []
    private var rowLabels: [NSTextField] = []
    private(set) var rowGranted: [Bool] = [false, false]
    private var closingProgrammatically = false

    init(copy: PermissionCopy) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Voicely"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        titleField.font = .boldSystemFont(ofSize: 15)
        titleField.stringValue = copy.title
        messageField.font = .systemFont(ofSize: 13)
        messageField.textColor = .secondaryLabelColor
        messageField.preferredMaxLayoutWidth = 412

        var rowViews: [NSView] = []
        for label in [copy.microphoneRow, copy.accessibilityRow] {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 13)
            let row = NSStackView(views: [icon, text])
            row.orientation = .horizontal
            row.spacing = 8
            rowIcons.append(icon)
            rowLabels.append(text)
            rowViews.append(row)
        }

        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(buttonPressed)
        let buttonRow = NSStackView(views: [NSView(), button])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [titleField] + rowViews + [messageField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: titleField)
        stack.setCustomSpacing(14, after: rowViews[rowViews.count - 1])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            messageField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        window.contentView = content
    }

    var titleText: String { titleField.stringValue }
    var messageText: String { messageField.stringValue }
    var buttonTitle: String { button.title }
    var rowTexts: [String] { rowLabels.map(\.stringValue) }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func render(_ screen: PermissionScreen) {
        titleField.stringValue = screen.title
        messageField.stringValue = screen.message
        button.title = screen.buttonTitle
        for (index, row) in screen.rows.enumerated() where index < rowIcons.count {
            rowLabels[index].stringValue = row.label
            let symbol = row.granted ? "checkmark.circle.fill" : "circle.dashed"
            rowIcons[index].image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            rowIcons[index].contentTintColor = row.granted ? .systemGreen : .tertiaryLabelColor
            rowIcons[index].setAccessibilityLabel(row.granted ? "on" : "off")
        }
        rowGranted = screen.rows.map(\.granted)
    }

    func close() {
        closingProgrammatically = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingProgrammatically {
            closedByPerson = true
        }
    }

    @objc private func buttonPressed() {
        onButton?()
    }
}
