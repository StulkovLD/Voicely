import AppKit
import AVFoundation

/// First-run setup wizard. Checks permissions and guides user through setup.
@MainActor
final class Onboarding {

    enum PermissionState {
        case granted, denied, notDetermined
    }

    /// Result of the onboarding flow. AppDelegate uses this to decide which features to enable.
    struct OnboardingResult {
        let microphoneGranted: Bool
        let accessibilityGranted: Bool
    }

    /// Returns true if core permissions (mic, accessibility) are granted.
    /// Speech Recognition is NOT required - WhisperKit uses CoreML directly.
    var isReady: Bool {
        get async {
            let mic = await micPermission()
            let accessibility = accessibilityPermission()
            return mic == .granted && accessibility == .granted
        }
    }

    // MARK: - Main Flow

    /// Run onboarding flow. Shows dialogs for missing permissions.
    /// Returns an `OnboardingResult` so AppDelegate knows what was granted.
    ///
    /// Total onboarding flow is bounded: mic request (~2s) + accessibility poll (30s max).
    ///
    /// Screen Recording is NOT requested here - it is only needed for Call Recording
    /// and should be requested on demand via `requestScreenRecording()`.
    @discardableResult
    func runIfNeeded() async -> OnboardingResult {
        // --- Microphone ---
        var micGranted = await micPermission() == .granted
        if !micGranted {
            micGranted = await requestMicPermission()
        }

        // --- Accessibility (can't request programmatically, must guide user) ---
        var accessGranted = accessibilityPermission() == .granted
        if !accessGranted {
            showAccessibilityDialog()
            // Poll every 2s, max 15 iterations = 30s
            for remaining in stride(from: 14, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(2))
                if AXIsProcessTrusted() {
                    accessGranted = true
                    break
                }
                if remaining > 0 {
                    print("[Voicely] Waiting for Accessibility permission... \(remaining * 2)s remaining")
                }
            }
            if !accessGranted {
                showAlert(
                    title: "Accessibility Not Granted",
                    message: "Voicely can still launch, but the hotkey and text pasting won't work until Accessibility is enabled.\n\nYou can grant it later in System Settings > Privacy & Security > Accessibility.",
                    button: "OK",
                    action: {}
                )
            }
        }

        let result = OnboardingResult(
            microphoneGranted: micGranted,
            accessibilityGranted: accessGranted
        )

        // NOTE: Don't show "ready" notification here - model hasn't loaded yet.
        // AppDelegate.showReadyNotification() fires after model is actually ready.

        return result
    }

    // MARK: - On-Demand: Screen Recording

    /// Request Screen Recording permission. Call this when the user first clicks "Record Call".
    /// Returns `true` if permission is granted.
    /// CGRequestScreenCaptureAccess() adds the app to the Screen Recording list in System Settings
    /// and shows the system dialog on first call. User just needs to toggle it on.
    func requestScreenRecording() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // Adds Voicely to Screen Recording list and shows system dialog
        // with "Open System Settings" button. No custom alert needed.
        _ = CGRequestScreenCaptureAccess()
        return false
    }

    // MARK: - Snapshot

    /// Synchronous snapshot of current permission states. Does not request anything.
    func checkAllPermissions() -> OnboardingResult {
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        default: mic = false
        }

        let accessibility = AXIsProcessTrusted()

        return OnboardingResult(
            microphoneGranted: mic,
            accessibilityGranted: accessibility
        )
    }

    // MARK: - Microphone

    private func micPermission() async -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Returns `true` if permission was granted after the request.
    private func requestMicPermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
            showAlert(
                title: "Microphone Access Required",
                message: "Voicely needs microphone access to transcribe your speech.\n\nOpen System Settings > Privacy & Security > Microphone and enable Voicely.",
                button: "Open Settings",
                action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            )
        }
        return granted
    }

    // MARK: - Accessibility

    private func accessibilityPermission() -> PermissionState {
        let trusted = AXIsProcessTrusted()
        return trusted ? .granted : .denied
    }

    private func showAccessibilityDialog() {
        let trusted = AXIsProcessTrusted()

        if !trusted {
            showAlert(
                title: "Accessibility Access Required",
                message: "Voicely needs Accessibility to detect your hotkey and paste transcribed text.\n\nSystem Settings will open. Add Voicely to the Accessibility list and enable it.\n\nVoicely will wait up to 30 seconds for you to grant permission.",
                button: "Open Settings",
                action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
            )
        }
    }

    // MARK: - UI

    private func showAlert(title: String, message: String, button: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            action()
        }
    }
}
