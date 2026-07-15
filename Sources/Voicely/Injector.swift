import AppKit
import Carbon

enum InjectionResult: Equatable, Sendable {
    case directInsert
    case copiedOnly
    case blockedSecureTarget
    case failed
}

enum AXInsertionAttempt: Equatable {
    case inserted
    case secureTarget
    case targetChanged
    case failed
}

struct InjectionTargetIdentity: Equatable, Sendable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let identifier: String?
    let domIdentifier: String?
    let isSecure: Bool
}

enum InjectionTargetValidation: Equatable, Sendable {
    case sameTarget
    case targetChanged
    case originalSecure
    case currentSecure
    case invalid
}

enum InjectionTargetFallback: Equatable, Sendable {
    case directInsert
    case copyOnly
    case saveOnly
}

enum InjectionTargetPolicy {
    static func validate(
        original: InjectionTargetIdentity?,
        current: InjectionTargetIdentity?,
        sameAXElement: Bool,
        originalSecureEventInputEnabled: Bool = false,
        currentSecureEventInputEnabled: Bool = false
    ) -> InjectionTargetValidation {
        if originalSecureEventInputEnabled || original?.isSecure == true {
            return .originalSecure
        }
        if currentSecureEventInputEnabled || current?.isSecure == true {
            return .currentSecure
        }
        guard let original,
              let current,
              original.pid > 0,
              current.pid > 0,
              original.role != nil,
              current.role != nil else {
            return .invalid
        }
        guard sameAXElement,
              original.pid == current.pid,
              original.role == current.role,
              original.subrole == current.subrole,
              original.identifier == current.identifier,
              original.domIdentifier == current.domIdentifier else {
            return .targetChanged
        }
        return .sameTarget
    }

    static func fallback(
        for validation: InjectionTargetValidation
    ) -> InjectionTargetFallback {
        switch validation {
        case .sameTarget:
            return .directInsert
        case .targetChanged, .invalid:
            return .copyOnly
        case .originalSecure, .currentSecure:
            return .saveOnly
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

struct InjectionTargetToken {
    fileprivate let element: AXUIElement?
    let identity: InjectionTargetIdentity?
    let secureEventInputEnabled: Bool
}

@MainActor
final class Injector {
    /// Capture the exact focused AX target at dictation start. A missing target
    /// is still represented by a token so commit fails closed to copy-only.
    func captureTarget() -> InjectionTargetToken {
        let secureEventInputEnabled = IsSecureEventInputEnabled()
        let snapshot = focusedTargetSnapshot(
            secureEventInputEnabled: secureEventInputEnabled
        )
        return InjectionTargetToken(
            element: snapshot?.element,
            identity: snapshot?.identity,
            secureEventInputEnabled: secureEventInputEnabled
        )
    }

    /// Inject text only into the target captured when dictation started.
    @discardableResult
    func inject(
        text: String,
        target: InjectionTargetToken?
    ) -> InjectionResult {
        let initialValidation = resolve(target).validation
        switch InjectionTargetPolicy.fallback(for: initialValidation) {
        case .saveOnly:
            AppDelegate.debugLog("Injector: original or current target is secure")
            return .blockedSecureTarget
        case .copyOnly:
            return copyOnly(text, target: target)
        case .directInsert:
            break
        }

        // 1. Try AX insert on the captured target.
        switch tryAXInsert(text, target: target) {
        case .inserted:
            AppDelegate.debugLog("Injector: AX insert succeeded")
            return .directInsert
        case .secureTarget:
            AppDelegate.debugLog("Injector: secure AX target; clipboard fallback blocked")
            return .blockedSecureTarget
        case .targetChanged:
            return copyOnly(text, target: target)
        case .failed:
            AppDelegate.debugLog("Injector: AX insert unavailable; copying for manual paste")
            return copyOnly(text, target: target)
        }
    }

    // MARK: - Accessibility API

    private func tryAXInsert(
        _ text: String,
        target: InjectionTargetToken?
    ) -> AXInsertionAttempt {
        let initial = resolve(target)
        switch initial.validation {
        case .originalSecure, .currentSecure:
            return .secureTarget
        case .targetChanged, .invalid:
            return .targetChanged
        case .sameTarget:
            break
        }
        guard let element = initial.element else { return .targetChanged }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return .failed }

        // AX queries above can run arbitrary target-side code. Resolve again at
        // the commit boundary and write only to that revalidated element.
        let commit = resolve(target)
        switch commit.validation {
        case .originalSecure, .currentSecure:
            return .secureTarget
        case .targetChanged, .invalid:
            return .targetChanged
        case .sameTarget:
            break
        }
        guard let commitElement = commit.element else { return .targetChanged }
        guard !IsSecureEventInputEnabled() else { return .secureTarget }
        let result = AXUIElementSetAttributeValue(
            commitElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return result == .success ? .inserted : .failed
    }

    private struct FocusedTargetSnapshot {
        let element: AXUIElement
        let identity: InjectionTargetIdentity
    }

    private struct ResolvedTarget {
        let validation: InjectionTargetValidation
        let element: AXUIElement?
    }

    private func resolve(_ target: InjectionTargetToken?) -> ResolvedTarget {
        let secureEventInputEnabled = IsSecureEventInputEnabled()
        let current = focusedTargetSnapshot(
            secureEventInputEnabled: secureEventInputEnabled
        )
        let sameElement: Bool
        if let originalElement = target?.element,
           let currentElement = current?.element {
            sameElement = CFEqual(originalElement, currentElement)
        } else {
            sameElement = false
        }
        let validation = InjectionTargetPolicy.validate(
            original: target?.identity,
            current: current?.identity,
            sameAXElement: sameElement,
            originalSecureEventInputEnabled: target?.secureEventInputEnabled ?? false,
            currentSecureEventInputEnabled: secureEventInputEnabled
        )
        return ResolvedTarget(
            validation: validation,
            element: validation == .sameTarget ? current?.element : nil
        )
    }

    private func focusedTargetSnapshot(
        secureEventInputEnabled: Bool
    ) -> FocusedTargetSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let identity = InjectionTargetIdentity(
            pid: pid,
            role: role,
            subrole: subrole,
            identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element),
            // AXWebConstants.h defines this stable attribute name, but older
            // Xcode SDKs do not import the kAXDOMIdentifierAttribute symbol.
            domIdentifier: stringAttribute("AXDOMIdentifier" as CFString, from: element),
            isSecure: AXTargetSecurity.isSecure(
                role: role,
                subrole: subrole,
                secureEventInputEnabled: secureEventInputEnabled
            )
        )
        return FocusedTargetSnapshot(element: element, identity: identity)
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

    private func copyOnly(
        _ text: String,
        target: InjectionTargetToken?
    ) -> InjectionResult {
        let pasteboard = NSPasteboard.general

        // Re-resolve immediately before the only clipboard mutation. Secure
        // targets and Secure Event Input always fail closed to save-only.
        switch InjectionTargetPolicy.fallback(for: resolve(target).validation) {
        case .saveOnly:
            return .blockedSecureTarget
        case .directInsert, .copyOnly:
            break
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
