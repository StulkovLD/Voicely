import AppKit
import Carbon

enum InjectionResult: Equatable, Sendable {
    case directInsert
    case copiedOnly
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
    /// nothing does — or always, when the user chose the clipboard destination.
    @discardableResult
    func inject(
        text: String,
        target: InjectionTargetToken?,
        destination: DictationDestination = .atCursor
    ) -> InjectionResult {
        let startedSecure = target?.startedSecure ?? false
        let probe = probeCaret()

        // The user's explicit choice: never touch the focused app. The secure
        // gates still apply — a dictation that started in a password field must
        // not reach the general pasteboard.
        if destination == .clipboardOnly {
            return copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
        }

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
            // No writable caret. Two shapes land here and both accept synthetic
            // typing: a terminal (text surface, read-only scrollback), and an
            // Electron app whose AX bridge does not answer the focus probe at
            // all (VS Code returns kAXErrorCannotComplete, measured live
            // 2026-08-19 — the probe sees "nothing focused" while the user's
            // caret blinks in its terminal). The desktop must stay clipboard:
            // typing at Finder would spray type-select. So: type when the
            // focus is a text surface, or when the frontmost app is a real
            // app that is not Finder and not us.
            let copied = copyOnly(text, startedSecure: startedSecure, currentSecure: probe.isSecure)
            guard copied == .copiedOnly else { return copied }
            if probe.isTextSurface || Self.frontmostAppAcceptsTyping() {
                if typeUnicode(text) {
                    AppDelegate.debugLog("Injector: typed via unicode key events (textSurface=\(probe.isTextSurface))")
                    return .directInsert
                }
            } else {
                AppDelegate.debugLog("Injector: no caret, no typing target; clipboard only")
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
        /// accepts synthetic typing. Measured: VS Code's xterm.js (canvas
        /// inside Electron) swallows a synthetic Cmd+V, which is why typing
        /// unicode key events is the transport here.
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

    /// Type `text` at the focused element as synthetic unicode keyboard
    /// events. This is the transport for text surfaces with no writable AX
    /// caret: terminals accept typed input by nature, and it replaced the
    /// synthetic Cmd+V because canvas surfaces (VS Code's xterm.js) swallow
    /// that Cmd+V while still accepting typed events. Only ever called with
    /// the transcript already verified onto the clipboard, so a failure here
    /// still leaves the user one manual paste away.
    private func typeUnicode(_ text: String) -> Bool {
        guard CGPreflightPostEventAccess() else {
            AppDelegate.debugLog("Injector: no post-event access; leaving text on the clipboard")
            return false
        }
        guard !IsSecureEventInputEnabled() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        for var chunk in Self.utf16Chunks(of: text, maxLength: 20) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// The user aimed their caret at a real app, even if its AX bridge won't
    /// say so. Finder means "the desktop" (typing there would type-select
    /// files), and our own process never receives dictation.
    private static func frontmostAppAcceptsTyping() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if front.bundleIdentifier == "com.apple.finder" { return false }
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
        return true
    }

    /// UTF-16 chunks that never split a surrogate pair: when the boundary
    /// lands right after a high surrogate, the low surrogate is pulled into
    /// the same chunk, so a chunk may run one unit over `maxLength`.
    nonisolated static func utf16Chunks(of text: String, maxLength: Int) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty, maxLength > 0 else { return units.isEmpty ? [] : [units] }
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxLength, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end += 1
            }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
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
