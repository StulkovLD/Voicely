import XCTest
@testable import Voicely

/// One hotkey press, judged in the current position. Lived: "tap and release"
/// did nothing because the 300 ms debounce swallowed the stop, and a session
/// could not be stopped once the model stopped being ready.
final class DictationToggleDecisionTests: XCTestCase {
    private func decide(
        state: AppState,
        modelReady: Bool = true,
        hasModel: Bool = true,
        sinceLastToggle: TimeInterval = 1
    ) -> AppDelegate.DictationToggleDecision {
        AppDelegate.dictationToggleDecision(
            state: state,
            modelReady: modelReady,
            hasModel: hasModel,
            sinceLastToggle: sinceLastToggle
        )
    }

    func testStopIsNeverDebouncedWhileRecording() {
        XCTAssertEqual(decide(state: .recording, sinceLastToggle: 0.05), .stop)
    }

    func testStopIsReachableWithoutAReadyModel() {
        XCTAssertEqual(decide(state: .recording, modelReady: false, sinceLastToggle: 0.05), .stop)
    }

    func testStartWithinDebounceWindowIsDropped() {
        XCTAssertEqual(decide(state: .idle, sinceLastToggle: 0.1), .dropped)
    }

    func testDiscardWithinDebounceWindowIsDropped() {
        XCTAssertEqual(decide(state: .transcribing, sinceLastToggle: 0.1), .dropped)
    }

    func testStartWithoutAReadyModelIsRefused() {
        XCTAssertEqual(decide(state: .idle, modelReady: false), .refused("Model loading..."))
        XCTAssertEqual(decide(state: .idle, modelReady: false, hasModel: false), .refused("Select a model"))
    }

    func testStartAndTranscribingPressPassTheGate() {
        XCTAssertEqual(decide(state: .idle), .start)
        XCTAssertEqual(decide(state: .transcribing), .transcribingPress)
    }

    func testCallStatesAreNotDictation() {
        XCTAssertEqual(decide(state: .callRecording), .callSessionPress)
        XCTAssertEqual(decide(state: .callStarting), .callSessionPress)
        XCTAssertEqual(decide(state: .callTranscribing), .callSessionPress)
    }
}
