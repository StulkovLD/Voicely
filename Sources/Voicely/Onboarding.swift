import AppKit
import Foundation

/// Screen Recording, asked on demand at the first call recording. Microphone
/// and Accessibility belong to `PermissionGate`.
@MainActor
final class Onboarding {

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
        // macOS's "Quit & Reopen" action is flaky for our unsigned LSUIElement
        // menubar app: it may terminate Voicely but fail to launch it again.
        // Arm a short-lived external watcher before requesting access so that,
        // if the system quits this process, the installed bundle is reopened.
        armRelaunchWatcherAfterPermissionQuit()
        _ = CGRequestScreenCaptureAccess()
        return false
    }

    nonisolated static func makeRelaunchWatcherScript(
        appPath: String,
        pid: Int32,
        timeoutSeconds: Int = 120
    ) -> String {
        let quotedAppPath = shellSingleQuote(appPath)
        return """
        pid=\(pid)
        app=\(quotedAppPath)
        i=0
        while [ "$i" -lt \(timeoutSeconds) ]; do
          if ! kill -0 "$pid" 2>/dev/null; then
            sleep 1
            /usr/bin/open "$app" >/dev/null 2>&1 || true
            exit 0
          fi
          i=$((i + 1))
          sleep 1
        done
        exit 0
        """
    }

    private func armRelaunchWatcherAfterPermissionQuit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.makeRelaunchWatcherScript(
                appPath: Bundle.main.bundlePath,
                pid: ProcessInfo.processInfo.processIdentifier
            ),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[Voicely] Failed to arm Screen Recording relaunch watcher: %@", error.localizedDescription)
        }
    }

    private nonisolated static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
