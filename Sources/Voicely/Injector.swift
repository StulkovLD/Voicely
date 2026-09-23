import AppKit
import Carbon

enum InjectionResult: Equatable, Sendable {
    /// Delivered at the caret, or possibly delivered ("don't know" never
    /// triggers a second attempt).
    case directInsert
    /// No caret to aim at, or the user chose the clipboard.
    case copiedOnly
    /// Every channel certainly failed; the transcript waits on the clipboard.
    case copiedForManualPaste
    case blockedSecureTarget
    case failed
}

/// Where a finished dictation lands — the user's menu choice.
enum DictationDestination: String, CaseIterable, Sendable {
    /// Insert at the caret; clipboard only when nothing can take the text.
    case atCursor = "cursor"
    /// Never touch the focused app: always place the text on the clipboard.
    case clipboardOnly = "clipboard"

    var menuTitle: String {
        switch self {
        case .atCursor: return "Insert at Cursor"
        case .clipboardOnly: return "Copy to Clipboard"
        }
    }
}

enum AXTargetSecurity {
    static func isSecure(
        role: String?,
        subrole: String?,
        secureEventInputEnabled: Bool = false
    ) -> Bool {
        secureEventInputEnabled
            || role == "AXSecureTextField"
            || subrole == "AXSecureTextField"
    }
}

/// The only thing carried over from dictation start: a password dictated into
/// a secure field must not reach the pasteboard after the user clicks away.
struct InjectionTargetToken {
    let startedSecure: Bool
}

/// Delivers a finished transcript to the caret {ДИЗАЙН insertion-2026-09-23 §4.1}.
///
///     probe focus {Accessibility as a sensor only} ─▶ InsertionPlanner
///        saveOnly ─▶ nothing leaves the disk
///        copyOnly ─▶ clipboard + toast
///        deliver  ─▶ [ax] ─▶ [paste] ─▶ [typing], next only on "certainly not delivered"
///     every dictation ─▶ one line in ~/Library/Logs/Voicely/insertion.jsonl
@MainActor
final class Injector {
    struct Timing: Sendable {
        /// How long to wait for the hotkey's modifiers to be released.
        var modifierCeiling: Duration = .milliseconds(600)
        var receiptCeiling: Duration = .milliseconds(1000)
        /// After the receipt, the user's pasteboard comes back this much later.
        var restoreGrace: Duration = .milliseconds(400)
        /// Second look after an Accessibility write that changed nothing.
        var axSettle: Duration = .milliseconds(150)
        var keyGap: Duration = .milliseconds(10)
        var typingGap: Duration = .milliseconds(2)
        var poll: Duration = .milliseconds(5)
    }

    private let pasteboard: NSPasteboard
    private let journal: InsertionJournal
    private let timing: Timing

    /// A delivered paste whose pasteboard has not been handed back yet.
    private var openPaste: (transaction: PasteboardTransaction, line: JournalLine)?
    private var pendingRestore: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        journal: InsertionJournal = .standard,
        timing: Timing = Timing()
    ) {
        self.pasteboard = pasteboard
        self.journal = journal
        self.timing = timing
    }

    /// Was the focus secure when dictation started?
    func captureTarget() -> InjectionTargetToken {
        let secureEventInputEnabled = IsSecureEventInputEnabled()
        guard let element = Self.focusedElement().element else {
            return InjectionTargetToken(startedSecure: secureEventInputEnabled)
        }
        return InjectionTargetToken(
            startedSecure: AXTargetSecurity.isSecure(
                role: Self.string(kAXRoleAttribute, of: element),
                subrole: Self.string(kAXSubroleAttribute, of: element),
                secureEventInputEnabled: secureEventInputEnabled
            )
        )
    }

    /// Put `text` where the caret is now. Returns once the outcome is known;
    /// the user's pasteboard comes back shortly after a paste.
    func deliver(
        text: String,
        target: InjectionTargetToken?,
        destination: DictationDestination = .atCursor
    ) async -> InjectionResult {
        closeOpenPaste()

        let front = NSWorkspace.shared.frontmostApplication
        let line = JournalLine(text: text, front: front)
        let probe = Self.probeFocus()
        let owner = probe.ownerPid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? front
        let engine = AppEngine.cached(bundleURL: owner?.bundleURL)
        let signals = InsertionSignals(
            destination: destination,
            startedSecure: target?.startedSecure ?? false,
            secureEventInput: IsSecureEventInputEnabled(),
            front: Self.frontKind(front),
            focus: probe.kind,
            engine: engine,
            inWebArea: probe.inWebArea
        )
        line.probe(probe, engine: engine, owner: owner, front: front)
        let plan = InsertionPlanner.plan(signals)

        switch plan {
        case .saveOnly:
            line.decision = "save_only"
            line.finish(channel: "none", outcome: "blocked_secure")
            journal.append(line.fields)
            return .blockedSecureTarget

        case .copyOnly(let reason):
            line.decision = "copy_only"
            line.reason = reason
            let copied = copyToClipboard(text, startedSecure: signals.startedSecure, currentSecure: probe.kind == .secure)
            line.clipboard = copied == .copiedOnly ? "copied" : nil
            line.finish(channel: "clipboard", outcome: Self.outcomeText(copied))
            journal.append(line.fields)
            return copied

        case .deliver(let channels):
            line.decision = "deliver"
            line.plan = channels.map(\.rawValue).joined(separator: ">")
            let runner = ChannelRunner(text: text, probe: probe, frontPid: front?.processIdentifier, injector: self, line: line)
            let outcome = await DeliveryChain.run(channels, with: runner)
            line.fallbackFrom = outcome.fallbackFrom.isEmpty ? nil : outcome.fallbackFrom.joined(separator: ",")

            guard let result = outcome.result, let channel = outcome.channel else {
                // Every channel certainly failed: the transcript waits on the
                // clipboard for a manual Cmd+V, and the pill says so.
                let copied = copyToClipboard(text, startedSecure: signals.startedSecure, currentSecure: false)
                line.clipboard = copied == .copiedOnly ? "left_transcript" : line.clipboard
                line.finish(channel: "clipboard", outcome: Self.outcomeText(copied))
                journal.append(line.fields)
                return copied == .copiedOnly ? .copiedForManualPaste : copied
            }

            let injection: InjectionResult
            switch result {
            case .delivered(let confirmation):
                line.confirm = confirmation.rawValue
                line.finish(channel: channel.rawValue, outcome: "delivered")
                injection = .directInsert
            case .unknown(let reason):
                line.reason = reason
                line.finish(channel: channel.rawValue, outcome: "unknown")
                injection = .directInsert
            case .blockedSecure:
                line.finish(channel: channel.rawValue, outcome: "blocked_secure")
                injection = .blockedSecureTarget
            case .notDelivered:
                line.finish(channel: channel.rawValue, outcome: "not_delivered")
                injection = .failed
            }

            if let open = runner.openTransaction {
                // The line is written when the user's pasteboard is back.
                openPaste = (open, line)
                let grace = timing.restoreGrace
                pendingRestore = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: grace)
                    self?.closeOpenPaste()
                }
            } else {
                journal.append(line.fields)
            }
            return injection
        }
    }

    /// A dictation whose text was saved but not delivered (the app is quitting).
    func recordSkipped(text: String, reason: String) {
        let line = JournalLine(text: text, front: NSWorkspace.shared.frontmostApplication)
        line.decision = "skip"
        line.reason = reason
        line.finish(channel: "none", outcome: "skipped")
        journal.append(line.fields)
    }

    /// Quit must not leave the transcript promised by a process that is gone.
    func settleForTermination() {
        closeOpenPaste()
    }

    /// Hand back the user's pasteboard now, if a paste still holds it.
    private func closeOpenPaste() {
        pendingRestore?.cancel()
        pendingRestore = nil
        guard let open = openPaste else { return }
        openPaste = nil
        open.line.clipboard = open.transaction.restore().rawValue
        journal.append(open.line.fields)
    }

    // MARK: - Channels

    /// Runs one channel at a time for `DeliveryChain`, and keeps what the
    /// journal needs to know about them.
    @MainActor
    private final class ChannelRunner: InsertionChannelRunner {
        let text: String
        let probe: FocusProbe
        let frontPid: pid_t?
        unowned let injector: Injector
        let line: JournalLine
        var openTransaction: PasteboardTransaction?
        private var keysReady: Bool?

        init(text: String, probe: FocusProbe, frontPid: pid_t?, injector: Injector, line: JournalLine) {
            self.text = text
            self.probe = probe
            self.frontPid = frontPid
            self.injector = injector
            self.line = line
        }

        func attempt(_ channel: InsertionChannel) async -> ChannelResult {
            switch channel {
            case .ax:
                return await injector.writeThroughAccessibility(text, probe: probe)
            case .paste:
                guard await keyChannelsReady() else { return .notDelivered(reason: "modifiers_held") }
                guard frontUnchanged() else { return .notDelivered(reason: "front_changed") }
                let attempt = await injector.paste(text)
                openTransaction = attempt.openTransaction
                line.receiptMs = attempt.receiptMilliseconds
                if let close = attempt.close { line.clipboard = close.rawValue }
                return attempt.result
            case .typing:
                guard await keyChannelsReady() else { return .notDelivered(reason: "modifiers_held") }
                guard frontUnchanged() else { return .notDelivered(reason: "front_changed") }
                return await injector.type(text)
            }
        }

        /// The hotkey's modifiers must be up before any synthetic key goes out:
        /// a held Option turns typed text into Meta sequences in a terminal.
        private func keyChannelsReady() async -> Bool {
            if let keysReady { return keysReady }
            let clock = ContinuousClock()
            let start = clock.now
            let deadline = start.advanced(by: injector.timing.modifierCeiling)
            var ready = !KeyboardSynth.physicalModifiersHeld()
            while !ready, clock.now < deadline {
                try? await Task.sleep(for: injector.timing.poll)
                ready = !KeyboardSynth.physicalModifiersHeld()
            }
            let waited = start.duration(to: clock.now).components
            line.modifierWaitMs = Int(waited.seconds * 1000 + waited.attoseconds / 1_000_000_000_000_000)
            keysReady = ready
            return ready
        }

        private func frontUnchanged() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPid
        }
    }

    fileprivate func paste(_ text: String) async -> PasteChannel.Attempt {
        let keyGap = timing.keyGap
        let environment = PasteEnvironment(
            pasteboard: pasteboard,
            sourceBundleID: Bundle.main.bundleIdentifier,
            secureInputEnabled: { IsSecureEventInputEnabled() },
            canPostEvents: { CGPreflightPostEventAccess() },
            postPaste: {
                let source = CGEventSource(stateID: .privateState)
                guard let events = KeyboardSynth.pasteEvents(keyCode: KeyboardSynth.pasteKeyCode(), source: source)
                else { return false }
                for (index, event) in events.enumerated() {
                    if index > 0 { try? await Task.sleep(for: keyGap) }
                    event.post(tap: .cghidEventTap)
                }
                return true
            },
            receiptCeiling: timing.receiptCeiling,
            poll: timing.poll
        )
        return await PasteChannel.run(text: text, environment: environment)
    }

    /// Unicode key events, a chunk at a time, with the main thread free
    /// between chunks so Voicely's own hotkey tap passes them on promptly.
    fileprivate func type(_ text: String) async -> ChannelResult {
        guard CGPreflightPostEventAccess() else { return .notDelivered(reason: "no_post_access") }
        guard !IsSecureEventInputEnabled() else { return .blockedSecure }
        let chunks = KeyboardSynth.typingChunks(of: KeyboardSynth.typingNormalized(text))
        guard !chunks.isEmpty else { return .notDelivered(reason: "empty") }
        let source = CGEventSource(stateID: .privateState)
        for (index, chunk) in chunks.enumerated() {
            if IsSecureEventInputEnabled() {
                return index == 0 ? .blockedSecure : .unknown(reason: "secure_input_mid_typing")
            }
            guard let pair = KeyboardSynth.typingEvents(chunk: chunk, source: source) else {
                return index == 0 ? .notDelivered(reason: "event_create_failed") : .unknown(reason: "typing_interrupted")
            }
            pair.down.post(tap: .cghidEventTap)
            pair.up.post(tap: .cghidEventTap)
            try? await Task.sleep(for: timing.typingGap)
        }
        return .delivered(.unverified)
    }

    /// Accessibility write, believed only when read back: native Cocoa writes
    /// synchronously, so "nothing moved, twice" means the text was dropped
    /// {WhatsApp answers success without an effect}.
    fileprivate func writeThroughAccessibility(_ text: String, probe: FocusProbe) async -> ChannelResult {
        guard let element = probe.element, let before = probe.range else {
            return .notDelivered(reason: "no_caret")
        }
        guard !IsSecureEventInputEnabled() else { return .blockedSecure }
        let length = (text as NSString).length
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        let verdict: () -> AXWriteCheck.Verdict = {
            AXWriteCheck.classify(
                before: before,
                after: Self.selectedRange(of: element),
                countBefore: probe.characterCount,
                countAfter: Self.characterCount(of: element),
                insertedLength: length
            )
        }
        switch status {
        case .success:
            break
        case .cannotComplete:
            // The app did not answer in time; the write may still land.
            try? await Task.sleep(for: timing.axSettle)
            switch verdict() {
            case .verified: return .delivered(.verified)
            case .changed: return .delivered(.unverified)
            case .unchanged, .unreadable: return .unknown(reason: "ax_timeout")
            }
        default:
            return .notDelivered(reason: "ax_error_\(status.rawValue)")
        }
        var result = verdict()
        if result == .unchanged {
            try? await Task.sleep(for: timing.axSettle)
            result = verdict()
        }
        switch result {
        case .verified: return .delivered(.verified)
        case .changed: return .delivered(.unverified)
        case .unchanged: return .notDelivered(reason: "ax_unchanged")
        case .unreadable: return .unknown(reason: "ax_unreadable")
        }
    }

    // MARK: - Clipboard

    /// The one place a transcript is written to the clipboard as plain text.
    /// Secure state is re-checked here because this write must fail closed.
    private func copyToClipboard(_ text: String, startedSecure: Bool, currentSecure: Bool) -> InjectionResult {
        guard !startedSecure, !currentSecure, !IsSecureEventInputEnabled() else {
            return .blockedSecureTarget
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              pasteboard.string(forType: .string) == text else {
            return .failed
        }
        return .copiedOnly
    }

    private static func outcomeText(_ result: InjectionResult) -> String {
        switch result {
        case .directInsert: return "delivered"
        case .copiedOnly, .copiedForManualPaste: return "copied"
        case .blockedSecureTarget: return "blocked_secure"
        case .failed: return "failed"
        }
    }

    // MARK: - Accessibility as a sensor

    struct FocusProbe {
        var kind: FocusKind
        var role: String?
        var axError: String?
        var ownerPid: pid_t?
        var inWebArea = false
        var element: AXUIElement?
        var range: TextRange?
        var characterCount: Int?
    }

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    private static let xtermInputClass = "xterm-helper-textarea"

    private static func probeFocus() -> FocusProbe {
        let focused = focusedElement()
        guard let element = focused.element else {
            return FocusProbe(kind: .silent, axError: focused.error.map(axErrorName))
        }
        var pid: pid_t = 0
        let ownerPid: pid_t? = AXUIElementGetPid(element, &pid) == .success ? pid : nil
        let role = string(kAXRoleAttribute, of: element)
        let subrole = string(kAXSubroleAttribute, of: element)
        if AXTargetSecurity.isSecure(role: role, subrole: subrole) {
            return FocusProbe(kind: .secure, role: role, ownerPid: ownerPid)
        }
        guard let role, textRoles.contains(role) else {
            return FocusProbe(kind: .other, role: role, ownerPid: ownerPid)
        }

        let owner = ownerPid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let engine = AppEngine.cached(bundleURL: owner?.bundleURL)
        if engine == .chromium, stringArray("AXDOMClassList", of: element).contains(xtermInputClass) {
            return FocusProbe(kind: .terminalInput, role: role, ownerPid: ownerPid)
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        // No readable range: an insert could not be told from a drop.
        guard settable.boolValue, let range = selectedRange(of: element) else {
            return FocusProbe(kind: .readOnlyText, role: role, ownerPid: ownerPid)
        }
        return FocusProbe(
            kind: .editableText,
            role: role,
            ownerPid: ownerPid,
            inWebArea: engine == .native ? isInsideWebArea(element) : true,
            element: element,
            range: range,
            characterCount: characterCount(of: element)
        )
    }

    private static func frontKind(_ app: NSRunningApplication?) -> FrontApp {
        guard let app else { return .none }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .voicely }
        if app.bundleIdentifier == "com.apple.finder" { return .finder }
        return .app
    }

    private static func focusedElement() -> (element: AXUIElement?, error: AXError?) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard status == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return (nil, status == .success ? .noValue : status)
        }
        return ((focusedRef as! AXUIElement), nil)
    }

    /// Web content keeps its own editing model: an Accessibility write can
    /// show text a React field never hears about.
    private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            switch string(kAXRoleAttribute, of: node) {
            case "AXWebArea": return true
            case "AXWindow", "AXApplication": return false
            default: break
            }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private static func selectedRange(of element: AXUIElement) -> TextRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return TextRange(location: range.location, length: range.length)
    }

    private static func characterCount(of element: AXUIElement) -> Int? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func stringArray(_ attribute: String, of element: AXUIElement) -> [String] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [String]) ?? []
    }

    private static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .cannotComplete: return "cannot_complete"
        case .noValue: return "no_value"
        case .apiDisabled: return "api_disabled"
        case .attributeUnsupported: return "attribute_unsupported"
        case .notImplemented: return "not_implemented"
        case .invalidUIElement: return "invalid_element"
        default: return "ax_\(error.rawValue)"
        }
    }
}

/// The journal line of one dictation, filled as the delivery goes. The text
/// itself is never a field — only its length.
@MainActor
final class JournalLine {
    let started = ContinuousClock.now
    let length: Int
    let app: String?
    let appName: String?
    var owner: String?
    var engine: String?
    var focus: String?
    var role: String?
    var axError: String?
    var decision: String?
    var plan: String?
    var channel: String?
    var outcome: String?
    var confirm: String?
    var reason: String?
    var fallbackFrom: String?
    var receiptMs: Int?
    var clipboard: String?
    var modifierWaitMs: Int?
    var milliseconds: Int?

    init(text: String, front: NSRunningApplication?) {
        length = text.count
        app = front?.bundleIdentifier
        appName = front?.localizedName
    }

    func probe(_ probe: Injector.FocusProbe, engine: AppEngine, owner: NSRunningApplication?, front: NSRunningApplication?) {
        self.engine = engine.rawValue
        focus = probe.kind.rawValue
        role = probe.role
        axError = probe.axError
        if let owner, owner.processIdentifier != front?.processIdentifier {
            self.owner = owner.bundleIdentifier
        }
    }

    func finish(channel: String, outcome: String) {
        self.channel = channel
        self.outcome = outcome
        let elapsed = started.duration(to: ContinuousClock.now).components
        milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }

    var fields: [(String, InsertionJournal.Value)] {
        [
            ("app", .string(app)),
            ("app_name", .string(appName)),
            ("owner", .string(owner)),
            ("engine", .string(engine)),
            ("focus", .string(focus)),
            ("role", .string(role)),
            ("ax_error", .string(axError)),
            ("decision", .string(decision)),
            ("plan", .string(plan)),
            ("channel", .string(channel)),
            ("outcome", .string(outcome)),
            ("confirm", .string(confirm)),
            ("receipt_ms", .int(receiptMs)),
            ("reason", .string(reason)),
            ("fallback_from", .string(fallbackFrom)),
            ("clipboard", .string(clipboard)),
            ("mods_wait_ms", .int(modifierWaitMs)),
            ("len", .int(length)),
            ("ms", .int(milliseconds)),
            ("version", .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)),
        ]
    }
}
