import AppKit
import Carbon

enum InjectionResult: Equatable, Sendable {
    case directInsert
    case copiedOnly
    case blockedSecureTarget
    case failed
}

/// What to do with a finished transcript.
///
/// Text goes wherever the caret is at commit time — dictation is a stand-in for
/// typing, and typing lands where the caret is. The previous design pinned the
/// target captured at dictation start and refused to write anywhere else; that
/// pin is what turned a single stray AX timeout into "nothing pastes, anywhere",
/// because one false negative downgraded every healthy target to "changed".
enum InjectionDecision: Equatable, Sendable {
    case insert
    case copyOnly
    case saveOnly
}

enum CaretPolicy {
    /// Secure beats everything; otherwise the caret decides.
    ///
    /// `startedSecure` is the one thing worth remembering from dictation start:
    /// without it, dictating into a password field and then clicking away would
    /// see a non-secure target at commit and copy the password to the general
    /// pasteboard.
    static func decide(
        startedSecure: Bool,
        currentSecure: Bool,
        secureEventInputAtCommit: Bool,
        caretPresent: Bool
    ) -> InjectionDecision {
        if startedSecure || currentSecure || secureEventInputAtCommit {
            return .saveOnly
        }
        return caretPresent ? .insert : .copyOnly
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

/// The only thing carried over from dictation start. See `CaretPolicy.decide`:
/// it exists so a password dictated into a secure field cannot reach the
/// pasteboard after the user clicks away.
struct InjectionTargetToken {
    let startedSecure: Bool
}

@MainActor
final class Injector {
    /// Was the focus secure when dictation started?
    func captureTarget() -> InjectionTargetToken {
        let secureEventInputEnabled = IsSecureEventInputEnabled()
        guard let element = focusedElement() else {
            return InjectionTargetToken(startedSecure: secureEventInputEnabled)
        }
        return InjectionTargetToken(
            startedSecure: AXTargetSecurity.isSecure(
                role: stringAttribute(kAXRoleAttribute as CFString, from: element),
                subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element),
                secureEventInputEnabled: secureEventInputEnabled
            )
        )
    }

    /// Insert into whatever holds the caret right now; clipboard only when
    /// nothing does.
    @discardableResult
    func inject(
        text: String,
        target: InjectionTargetToken?
    ) -> InjectionResult {
        let startedSecure = target?.startedSecure ?? false
        let probe = probeCaret()

        let decision = CaretPolicy.decide(
            startedSecure: startedSecure,
            currentSecure: probe.isSecure,
            secureEventInputAtCommit: IsSecureEventInputEnabled(),
            caretPresent: probe.caret != nil
        )

        switch decision {
        case .saveOnly:
            AppDelegate.debugLog("Injector: secure target; saved to disk only")
            return .blockedSecureTarget
        case .copyOnly:
            // A terminal is a text surface with no writable caret: its
            // scrollback is read-only, so AX has nothing to insert into, but it
            // takes a real Cmd+V. Only do this for a text surface — pressing
            // Cmd+V blind would paste into whatever else has focus (a Finder
            // window would happily paste a file).
            let copied = copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
            guard copied == .copiedOnly, probe.isTextSurface else {
                if !probe.isTextSurface {
                    AppDelegate.debugLog("Injector: no caret and not a text surface; clipboard only")
                }
                return copied
            }
            if postPaste() {
                AppDelegate.debugLog("Injector: pasted into text surface via Cmd+V")
                return .directInsert
            }
            return copied
        case .insert:
            break
        }

        guard let caret = probe.caret else {
            return copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
        }
        // Re-check in the same run-loop turn as the write: the reads above can
        // run target-side code, and secure state must not be stale.
        guard !IsSecureEventInputEnabled() else { return .blockedSecureTarget }

        let wrote = AXUIElementSetAttributeValue(
            caret.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard wrote == .success else {
            AppDelegate.debugLog("Injector: AX write refused; copying for manual paste")
            return copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
        }

        // Chrome reports the attribute settable, returns .success, and discards
        // the text (measured 6/6); Terminal.app's read-only scrollback lies the
        // same way. Believe the write only if the selection actually moved.
        //
        // Deliberately asymmetric: ONLY "nothing moved at all" counts as
        // discarded. An app that inserts but repositions the caret its own way
        // (autocorrect, IME, length caps) still counts as inserted — a stale
        // clipboard is visible and recoverable, silent text loss is not.
        if let after = selectedTextRange(of: caret.element),
           after.location == caret.range.location,
           after.length == caret.range.length {
            AppDelegate.debugLog("Injector: target swallowed the write; copying for manual paste")
            return copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
        }
        AppDelegate.debugLog("Injector: AX insert succeeded")
        return .directInsert
    }

    // MARK: - Accessibility API

    private struct Caret {
        let element: AXUIElement
        let range: CFRange
    }

    private struct CaretProbe {
        let caret: Caret?
        let isSecure: Bool
        /// Focus is a text surface that refuses AX writes — a terminal. Its
        /// scrollback is read-only, so there is no caret to write into, but it
        /// takes a real Cmd+V. Measured: Terminal.app accepts a synthetic
        /// paste; VS Code's xterm.js swallows it (canvas inside Electron).
        let isTextSurface: Bool
    }

    /// Is there a caret blinking somewhere right now?
    ///
    /// `kAXSelectedText` settability is the test, and it is measured, not
    /// assumed: an editable NSTextView reports it settable, a non-editable one
    /// does not. `kAXSelectedTextRange` is NOT a caret test — it is settable on
    /// read-only text too (you can select it), so it would call Terminal
    /// scrollback a caret. It serves only to verify the write afterwards.
    private func probeCaret() -> CaretProbe {
        guard let element = focusedElement() else {
            return CaretProbe(caret: nil, isSecure: false, isTextSurface: false)
        }

        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        if AXTargetSecurity.isSecure(role: role, subrole: subrole) {
            return CaretProbe(caret: nil, isSecure: true, isTextSurface: false)
        }

        let isTextSurface = role == "AXTextArea" || role == "AXTextField"

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else {
            return CaretProbe(caret: nil, isSecure: false, isTextSurface: isTextSurface)
        }
        // No readable range means no way to tell an insert from a swallow, so
        // there is no verifiable contract — treat it as no caret.
        guard let range = selectedTextRange(of: element) else {
            return CaretProbe(caret: nil, isSecure: false, isTextSurface: isTextSurface)
        }
        return CaretProbe(
            caret: Caret(element: element, range: range),
            isSecure: false,
            isTextSurface: isTextSurface
        )
    }

    /// Key that means "paste".
    ///
    /// Resolved against the ASCII-capable layout, not the user's current one,
    /// because that is how macOS itself matches Cmd-shortcuts. Measured: on a
    /// Russian layout `vk 9` produces "м", yet Cmd+V still pastes — so testing
    /// the current layout would switch this off for layouts where it works
    /// perfectly. Falls back to 9 (V on ANSI) when a layout exposes no data,
    /// which is the case for IMEs.
    private static func pasteKeyCode() -> CGKeyCode {
        let ansiV: CGKeyCode = 9
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiV }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data

        for code in CGKeyCode(0)...CGKeyCode(127) {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &length, &chars
                )
            }
            if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                return code
            }
        }
        return ansiV
    }

    /// Press Cmd+V at whatever is focused. Only ever called with the transcript
    /// already verified onto the clipboard.
    private func postPaste() -> Bool {
        guard CGPreflightPostEventAccess() else {
            AppDelegate.debugLog("Injector: no post-event access; leaving text on the clipboard")
            return false
        }
        guard !IsSecureEventInputEnabled() else { return false }
        let key = Self.pasteKeyCode()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef else { return nil }
        return (focusedRef as! AXUIElement)
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    // MARK: - Manual clipboard fallback

    /// `startedSecure` and `currentSecure` come from the caller's probe rather
    /// than a second AX round-trip; the SEI check is repeated here because this
    /// is the only clipboard mutation and it must fail closed.
    private func copyOnly(
        _ text: String,
        startedSecure: Bool,
        currentSecure: Bool
    ) -> InjectionResult {
        let pasteboard = NSPasteboard.general

        guard !startedSecure, !currentSecure else {
            AppDelegate.debugLog("Injector: secure target; refusing clipboard write")
            return .blockedSecureTarget
        }

        guard !IsSecureEventInputEnabled() else {
            AppDelegate.debugLog("Injector: Secure Event Input enabled before clipboard write")
            return .blockedSecureTarget
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              pasteboard.string(forType: .string) == text else {
            AppDelegate.debugLog("Injector: pasteboard verification failed")
            return .failed
        }
        AppDelegate.debugLog("Injector: transcript copied for manual paste")
        return .copiedOnly
    }
}
