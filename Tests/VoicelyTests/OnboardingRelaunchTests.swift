import XCTest
@testable import Voicely

final class OnboardingRelaunchTests: XCTestCase {
    func testRelaunchWatcherScriptWaitsForProcessExitThenOpensBundle() {
        let script = Onboarding.makeRelaunchWatcherScript(
            appPath: "/Applications/Voicely.app",
            pid: 1234,
            timeoutSeconds: 9
        )

        XCTAssertTrue(script.contains("pid=1234"))
        XCTAssertTrue(script.contains("while [ \"$i\" -lt 9 ]; do"))
        XCTAssertTrue(script.contains("kill -0 \"$pid\""))
        XCTAssertTrue(script.contains("/usr/bin/open \"$app\""))
    }

    func testRelaunchWatcherScriptQuotesBundlePathSafely() {
        let script = Onboarding.makeRelaunchWatcherScript(
            appPath: "/tmp/Voice ly's.app",
            pid: 1,
            timeoutSeconds: 1
        )

        XCTAssertTrue(script.contains("app='/tmp/Voice ly'\"'\"'s.app'"))
    }

    func testPreloadCompletionClearsOnlyTheTaskThatOwnsTheSlot() {
        let initialTask = UUID()
        let replacementTask = UUID()

        XCTAssertTrue(
            AppDelegate.preloadTaskCompletionOwnsSlot(
                completingOwner: initialTask,
                currentOwner: initialTask
            )
        )
        XCTAssertFalse(
            AppDelegate.preloadTaskCompletionOwnsSlot(
                completingOwner: initialTask,
                currentOwner: replacementTask
            )
        )
    }
}
