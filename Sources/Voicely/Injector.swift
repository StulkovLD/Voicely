import AppKit

enum InjectionResult: Sendable {
    case directInsert
    case clipboardPaste
    case failed
}

@MainActor
final class Injector {

    /// Pending clipboard restoration (so we can restore on quit)
    private var pendingRestore: DispatchWorkItem?
    private var savedClipboard: [[(NSPasteboard.PasteboardType, Data)]] = []

    /// Immediately restore clipboard if a paste is pending (call on app quit)
    func restoreClipboardNow() {
        pendingRestore?.cancel()
        pendingRestore = nil
        guard !savedClipboard.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        for itemData in savedClipboard {
            let item = NSPasteboardItem()
            for (type, data) in itemData { item.setData(data, forType: type) }
            items.append(item)
        }
        pasteboard.writeObjects(items)
        savedClipboard = []
    }

    /// Inject text at the current cursor position.
    @discardableResult
    func inject(text: String) -> InjectionResult {
        // 1. Try AX insert on current focused element
        if tryAXInsertCurrent(text) {
            AppDelegate.debugLog("Injector: AX insert succeeded")
            return .directInsert
        }

        // 2. Clipboard + Cmd+V
        AppDelegate.debugLog("Injector: AX failed, trying clipboard paste")
        return clipboardPaste(text) ? .clipboardPaste : .failed
    }

    // MARK: - Accessibility API

    private func tryAXInsertCurrent(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return false }
        // Safe: guard above ensures focusedRef is non-nil and .success
        let element = focusedRef as! AXUIElement

        // Skip password fields - never inject into secure text inputs
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == "AXSecureTextField" { return false }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .success
    }

    // MARK: - Clipboard paste

    private func clipboardPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        let savedItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Verify pasteboard was set correctly before attempting Cmd+V
        guard pasteboard.string(forType: .string) == text else {
            AppDelegate.debugLog("Injector: pasteboard verification failed")
            return false
        }

        let pasteChangeCount = pasteboard.changeCount

        let keyCode: CGKeyCode = 9 // 'v'
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms delay for apps to process keyDown
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)

        // Store original clipboard for restore, but don't overwrite if a previous
        // paste's original is still pending (rapid dictations would lose the original)
        if savedClipboard.isEmpty {
            savedClipboard = savedItems
        }
        pendingRestore?.cancel()

        // Restore clipboard: fall back to 1.5s for slow Electron apps,
        // but try early restore after 100ms if the target app consumed the paste.
        // Use self.savedClipboard (not captured savedItems) to always restore the
        // ORIGINAL clipboard, even if multiple rapid pastes occurred.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.savedClipboard.isEmpty else { return }
                guard pasteboard.changeCount == pasteChangeCount else {
                    self.savedClipboard = []
                    self.pendingRestore = nil
                    return
                }
                pasteboard.clearContents()
                var restoredItems: [NSPasteboardItem] = []
                for itemData in self.savedClipboard {
                    let item = NSPasteboardItem()
                    for (type, data) in itemData {
                        item.setData(data, forType: type)
                    }
                    restoredItems.append(item)
                }
                pasteboard.writeObjects(restoredItems)
                self.savedClipboard = []
                self.pendingRestore = nil
            }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)

        // Early restore: if changeCount changed within 100ms, the app already consumed the paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard pasteboard.changeCount != pasteChangeCount else { return }
                work.cancel()
                self?.savedClipboard = []
                self?.pendingRestore = nil
            }
        }

        return true
    }
}
