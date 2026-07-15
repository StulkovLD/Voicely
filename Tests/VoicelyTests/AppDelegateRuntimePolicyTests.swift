import AVFoundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

private final class RuntimePolicyEngine: TranscriberEngine, SampleTranscribing,
    @unchecked Sendable {
    func transcribe(
        audio _: AVAudioPCMBuffer,
        translate _: Bool,
        language _: String?
    ) async throws -> String {
        "ok"
    }

    func transcribeSamples(
        _: [Float],
        translate _: Bool,
        language _: String?
    ) async throws -> WhisperTranscription {
        WhisperTranscription(text: "ok", segments: [], detectedLanguage: "en")
    }
}

@MainActor
final class AppDelegateRuntimePolicyTests: XCTestCase {
    func testRuntimeMutationsRequireCompletelyIdleProduct() {
        XCTAssertTrue(AppDelegate.runtimeMutationsAllowed(
            appState: .idle,
            fileWorkActive: false
        ))
        XCTAssertFalse(AppDelegate.runtimeMutationsAllowed(
            appState: .idle,
            fileWorkActive: true
        ))
        for state in [
            AppState.recording,
            .transcribing,
            .callStarting,
            .callRecording,
            .callTranscribing,
        ] {
            XCTAssertFalse(AppDelegate.runtimeMutationsAllowed(
                appState: state,
                fileWorkActive: false
            ))
        }
    }

    func testFileTranscriptionStartsOnlyWithReadyEngineAndIdleCaptureState() {
        XCTAssertTrue(AppDelegate.canStartFileTranscription(
            modelReady: true,
            appState: .idle
        ))
        XCTAssertFalse(AppDelegate.canStartFileTranscription(
            modelReady: false,
            appState: .idle
        ))
        XCTAssertFalse(AppDelegate.canStartFileTranscription(
            modelReady: true,
            appState: .recording
        ))
        XCTAssertFalse(AppDelegate.canStartFileTranscription(
            modelReady: true,
            appState: .callRecording
        ))
    }

    func testGigaAMAvailabilityAndLanguageModesMatchCapabilities() throws {
        let giga = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .gigaAMV3E2ERNNT }
        )
        let whisper = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .whisperKit }
        )
        let macOS14 = OperatingSystemVersion(
            majorVersion: 14,
            minorVersion: 7,
            patchVersion: 0
        )
        let macOS15 = OperatingSystemVersion(
            majorVersion: 15,
            minorVersion: 0,
            patchVersion: 0
        )

        XCTAssertEqual(
            AppDelegate.availableModels(
                from: [giga, whisper],
                operatingSystemVersion: macOS14
            ),
            [whisper]
        )
        XCTAssertEqual(
            AppDelegate.availableModels(
                from: [giga, whisper],
                operatingSystemVersion: macOS15
            ),
            [giga, whisper]
        )
        XCTAssertEqual(AppDelegate.compatibleLanguageModes(for: giga), [.russian])
        XCTAssertEqual(
            AppDelegate.normalizedLanguageMode(.translateToEnglish, for: giga),
            .russian
        )
        XCTAssertEqual(
            AppDelegate.normalizedLanguageMode(.auto, for: giga),
            .russian
        )
        XCTAssertEqual(
            AppDelegate.compatibleLanguageModes(for: whisper),
            [.auto, .translateToEnglish]
        )
    }

    func testMultilingualCTCLanguageModesFollowCapabilities() throws {
        let multilingual = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .gigaAMMultilingualCTC }
        )
        XCTAssertFalse(multilingual.isSupported(on: OperatingSystemVersion(
            majorVersion: 14, minorVersion: 7, patchVersion: 0
        )))
        XCTAssertTrue(multilingual.isSupported(on: OperatingSystemVersion(
            majorVersion: 15, minorVersion: 0, patchVersion: 0
        )))
        XCTAssertEqual(AppDelegate.compatibleLanguageModes(for: multilingual), [.auto])
        XCTAssertEqual(
            AppDelegate.normalizedLanguageMode(.translateToEnglish, for: multilingual),
            .auto
        )
        XCTAssertEqual(
            AppDelegate.normalizedLanguageMode(.auto, for: multilingual),
            .auto
        )
    }

    func testFileQueueProductionWiringUsesRawEngineAndSharedCoordinator() throws {
        let coordinator = TranscriptionCoordinator()
        let engine = RuntimePolicyEngine()
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .whisperKit }
        )
        let transcriber = Transcriber(
            coordinator: coordinator,
            selectedModel: model,
            engineFactory: { _, _ in engine }
        )
        transcriber.translateToEnglish = true
        transcriber.preferredLanguage = "ru"
        _ = try transcriber.makeSession(priority: .file)

        let wiring = try XCTUnwrap(
            AppDelegate.fileTranscriptionRuntimeWiring(for: transcriber)
        )

        XCTAssertTrue((wiring.engine as? RuntimePolicyEngine) === engine)
        XCTAssertTrue(wiring.coordinator === coordinator)
        XCTAssertEqual(wiring.modelName, model.displayName)
        XCTAssertEqual(wiring.requestSettings.modelName, model.displayName)
        XCTAssertTrue(wiring.requestSettings.translateToEnglish)
        XCTAssertEqual(wiring.requestSettings.preferredLanguage, "ru")
    }

    func testClearingModelSelectionRemovesPersistedChoice() throws {
        let suite = "AppDelegateRuntimePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .whisperKit }
        )
        defaults.set(model.variant, forKey: "whisperModel")

        XCTAssertEqual(
            WhisperModel.savedSelection(
                in: defaults,
                systemRAMGB: model.minRAMGB,
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 0,
                    patchVersion: 0
                )
            ),
            model
        )
        WhisperModel.clearSavedSelection(in: defaults)
        XCTAssertNil(WhisperModel.savedSelection(in: defaults))
    }

    func testHotkeyRuntimeStateDistinguishesPermissionAndTapFailure() {
        XCTAssertEqual(
            HotkeyRuntimeState.classify(isTrusted: false, isTapActive: false),
            .permissionMissing
        )
        XCTAssertEqual(
            HotkeyRuntimeState.classify(isTrusted: true, isTapActive: false),
            .eventTapUnavailable
        )
        XCTAssertEqual(
            HotkeyRuntimeState.classify(isTrusted: true, isTapActive: true),
            .active
        )
    }

    func testModelProgressAndHotkeyFailureComposeInMenuBarTitle() {
        XCTAssertEqual(
            AppDelegate.composedMenuBarTitle(
                modelStatus: " 42%",
                hotkeyRuntimeState: .permissionMissing
            ),
            " 42% (grant access)"
        )
        XCTAssertEqual(
            AppDelegate.composedMenuBarTitle(
                modelStatus: " ...",
                hotkeyRuntimeState: .eventTapUnavailable
            ),
            " ... (hotkey retrying)"
        )
        XCTAssertEqual(
            AppDelegate.composedMenuBarTitle(
                modelStatus: " 100%",
                hotkeyRuntimeState: .active
            ),
            " 100%"
        )
    }
}
