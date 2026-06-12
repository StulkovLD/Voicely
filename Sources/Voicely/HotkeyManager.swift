import Foundation
import Quartz

// MARK: - Hotkey Combo

struct HotkeyCombo: Equatable, Codable {
    let keyCode: Int64
    let modifiers: UInt64

    var displayName: String {
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }

        let keyNames: [Int64: String] = [
            // Special keys
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            53: "Esc", 126: "↑", 125: "↓", 123: "←", 124: "→",
            // Letters
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J",
            40: "K", 41: ";", 45: "N", 46: "M",
            // Numbers
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        parts.append(keyNames[keyCode] ?? "Key\(keyCode)")
        return parts.joined()
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return self.keyCode == keyCode && flags.intersection(mask) == CGEventFlags(rawValue: modifiers).intersection(mask)
    }

    /// Convert NSEvent.modifierFlags to CGEventFlags raw value without raw-value cast.
    static func cgEventFlags(from nsFlags: NSEvent.ModifierFlags) -> UInt64 {
        var flags: CGEventFlags = []
        if nsFlags.contains(.command) { flags.insert(.maskCommand) }
        if nsFlags.contains(.option) { flags.insert(.maskAlternate) }
        if nsFlags.contains(.shift) { flags.insert(.maskShift) }
        if nsFlags.contains(.control) { flags.insert(.maskControl) }
        return flags.rawValue
    }
}

// MARK: - Presets

struct HotkeyPreset {
    let name: String
    let combo: HotkeyCombo

    static let all: [HotkeyPreset] = [
        HotkeyPreset(name: "⌥ Space (default)", combo: HotkeyCombo(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue)),
        HotkeyPreset(name: "⌃ Space", combo: HotkeyCombo(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue)),
    ]
}

// MARK: - Manager

/// Hotkey conflict detection (e.g. system shortcuts, Input Sources) is the caller's responsibility.
final class HotkeyManager: @unchecked Sendable {
    private var callback: (() -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let comboLock = NSLock()
    private var _combo: HotkeyCombo
    var onAccessibilityLost: (@Sendable () -> Void)?
    private var accessibilityCheckTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    /// Thread-safe access to current hotkey combo (read from event tap thread, written from main).
    private(set) var combo: HotkeyCombo {
        get { comboLock.withLock { _combo } }
        set { comboLock.withLock { _combo = newValue }; save() }
    }

    /// Whether the event tap exists and is currently enabled.
    var isActive: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    init() {
        _combo = Self.loadCombo()
        observeSleepWake()
    }

    /// Whether accessibility permission is currently granted
    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    deinit {
        accessibilityCheckTimer?.invalidate()
        removeSleepWakeObservers()
        stopTap()
    }

    // MARK: - Public API

    /// Register a hotkey callback and start the event tap.
    /// Returns `true` if the tap was created successfully.
    @discardableResult
    func register(callback: @escaping () -> Void) -> Bool {
        self.callback = callback
        return startTap()
    }

    /// Retry starting the tap if it's not already active.
    /// Useful after the user grants Accessibility permission at runtime.
    @discardableResult
    func retryIfNeeded() -> Bool {
        if isActive { return true }

        guard AXIsProcessTrusted() else {
            print("[Voicely] retryIfNeeded: Accessibility permission still not granted.")
            return false
        }

        if startTap() { return true }

        // #59: Right after granting Accessibility, tapCreate can fail once. Retry after 1s.
        scheduleDelayedRetry()
        return false
    }

    /// One delayed retry for event tap creation (#59).
    private func scheduleDelayedRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isActive else { return }
            if self.startTap() {
                print("[Voicely] Event tap succeeded on delayed retry.")
            } else {
                print("[Voicely] Event tap still failed after delayed retry.")
            }
        }
    }

    /// Start periodic check for accessibility revocation (every 30s)
    func startAccessibilityMonitor() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            if !AXIsProcessTrusted() {
                self.stopTap()
                self.onAccessibilityLost?()
                self.accessibilityCheckTimer?.invalidate()
                self.accessibilityCheckTimer = nil
            }
        }
    }

    /// Update the hotkey combo. Tap stays the same - matching logic uses self.combo.
    func updateHotkey(_ newCombo: HotkeyCombo) {
        combo = newCombo
    }

    // MARK: - Sleep/Wake Handling (#38)

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopTap()
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildTap()
        }
        sessionObserver = center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildTap()
        }
    }

    private func removeSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs) }
        if let obs = wakeObserver { center.removeObserver(obs) }
        if let obs = sessionObserver { center.removeObserver(obs) }
        sleepObserver = nil
        wakeObserver = nil
        sessionObserver = nil
    }

    /// Tear down and re-create the event tap after sleep/wake or Fast User Switching.
    private func rebuildTap() {
        guard callback != nil else { return }
        stopTap()
        _ = startTap()
        print("[Voicely] Event tap rebuilt after wake/session resume.")
    }

    // MARK: - Persistence

    private static let comboKey = "hotkeyCombo"

    private func save() {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.comboKey)
        }
    }

    private static func loadCombo() -> HotkeyCombo {
        if let data = UserDefaults.standard.data(forKey: comboKey),
           let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            return combo
        }
        // Default: Option+Space
        return HotkeyCombo(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue)
    }

    // MARK: - Event Tap

    private func startTap() -> Bool {
        stopTap()

        guard AXIsProcessTrusted() else {
            print("[Voicely] Cannot create event tap - Accessibility permission not granted. "
                + "Enable it in System Settings > Privacy & Security > Accessibility.")
            return false
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if the system disabled it (#64)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        print("[Voicely] Event tap re-enabled after system disable")
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else { return Unmanaged.passUnretained(event) }

                // Ignore key repeat events (held key generates repeats via HID driver)
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return Unmanaged.passUnretained(event)
                }

                // #106: Skip matching when callback has been cleared
                guard let cb = manager.callback else { return Unmanaged.passUnretained(event) }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                if manager.combo.matches(keyCode: keyCode, flags: flags) {
                    DispatchQueue.main.async {
                        cb()
                    }
                    return nil // consume event
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Voicely] CGEvent.tapCreate() failed despite AXIsProcessTrusted() == true.")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("[Voicely] Failed to create run loop source from event tap.")
            return false
        }

        self.eventTap = tap
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[Voicely] Event tap registered for \(combo.displayName).")
        return true
    }

    /// Stop the event tap. Disables tap first to prevent callbacks, then removes from run loop.
    private func stopTap() {
        // #40: Disable tap first so no callbacks fire during teardown
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        // Invalidate mach port to fully release resources
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }
}
