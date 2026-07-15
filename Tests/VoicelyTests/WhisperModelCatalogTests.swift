import XCTest
@testable import VoicelyCore

final class WhisperModelCatalogTests: XCTestCase {
    func testCatalogMatchesRequestedProductLine() {
        XCTAssertEqual(
            WhisperModel.all.map(\.variant),
            [
                "gigaam-v3-e2e-rnnt",
                "large-v3-v20240930_turbo_632MB",
                "large-v3_turbo",
                "medium",
            ]
        )
    }

    func testAvailabilityFollowsRAMThresholds() {
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 8).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "large-v3-v20240930_turbo_632MB"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 16).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "large-v3-v20240930_turbo_632MB", "medium"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 24).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "large-v3-v20240930_turbo_632MB", "large-v3_turbo", "medium"]
        )
    }

    func testRecommendationFollowsProductTiers() {
        XCTAssertEqual(
            WhisperModel.recommended(forSystemRAMGB: 8, availableDiskBytes: nil).variant,
            "large-v3-v20240930_turbo_632MB"
        )
        XCTAssertEqual(
            WhisperModel.recommended(forSystemRAMGB: 16, availableDiskBytes: nil).variant,
            "medium"
        )
        XCTAssertEqual(
            WhisperModel.recommended(forSystemRAMGB: 24, availableDiskBytes: nil).variant,
            "large-v3_turbo"
        )
    }

    func testGigaAMLabelStatesItsFullProductCapabilityBoundary() {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        XCTAssertEqual(model.ramRequirementLabel, "8 GB RAM")
        let label = model.userFacingLabel(isRecommended: false)
        XCTAssertTrue(label.contains("Russian only"))
        XCTAssertTrue(label.contains("no translation"))
        XCTAssertTrue(label.contains("macOS 15+"))
    }

    func testModelCapabilitiesMatchActualBackends() throws {
        let giga = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .gigaAMV3E2ERNNT }
        )
        XCTAssertEqual(giga.capabilities.supportedLanguages, ["ru"])
        XCTAssertFalse(giga.capabilities.supportsLanguageDetection)
        XCTAssertFalse(giga.capabilities.supportsTranslationToEnglish)
        XCTAssertNotNil(giga.requestValidationError(translateToEnglish: true, language: nil))
        XCTAssertNotNil(giga.requestValidationError(translateToEnglish: false, language: "en"))
        XCTAssertNil(giga.requestValidationError(translateToEnglish: false, language: "ru"))

        let whisper = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .whisperKit }
        )
        XCTAssertNil(whisper.capabilities.supportedLanguages)
        XCTAssertTrue(whisper.capabilities.supportsLanguageDetection)
        XCTAssertTrue(whisper.capabilities.supportsTranslationToEnglish)
        XCTAssertNil(whisper.requestValidationError(translateToEnglish: true, language: nil))
        XCTAssertNil(whisper.requestValidationError(translateToEnglish: false, language: "en"))
    }
}
