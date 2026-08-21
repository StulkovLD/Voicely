import XCTest
@testable import VoicelyCore

final class WhisperModelCatalogTests: XCTestCase {
    /// The whole line-up is one model — the owner's call (2026-08-19).
    /// Re-adding a model must be a deliberate data change reflected here.
    func testCatalogMatchesRequestedProductLine() {
        XCTAssertEqual(
            WhisperModel.all.map(\.variant),
            ["parakeet-tdt-0.6b-v3"]
        )
    }

    func testAvailabilityFollowsRAMThresholds() {
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 8).map(\.variant),
            ["parakeet-tdt-0.6b-v3"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 24).map(\.variant),
            ["parakeet-tdt-0.6b-v3"]
        )
    }

    func testRecommendationIsParakeetOnEveryTier() {
        for ram: UInt64 in [8, 16, 24] {
            XCTAssertEqual(
                WhisperModel.recommended(forSystemRAMGB: ram, availableDiskBytes: nil).variant,
                "parakeet-tdt-0.6b-v3"
            )
        }
    }

    func testModelCapabilitiesMatchActualBackends() throws {
        let parakeet = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .parakeetTDTV3 }
        )
        XCTAssertEqual(parakeet.capabilities.supportedLanguages?.count, 25)
        XCTAssertTrue(parakeet.capabilities.supportedLanguages?.contains("ru") ?? false)
        XCTAssertTrue(parakeet.capabilities.supportedLanguages?.contains("en") ?? false)
        XCTAssertTrue(parakeet.capabilities.supportsLanguageDetection)
        XCTAssertFalse(parakeet.capabilities.supportsTranslationToEnglish)
        XCTAssertEqual(parakeet.capabilities.minimumMacOSMajorVersion, 14)
        XCTAssertNotNil(parakeet.requestValidationError(translateToEnglish: true, language: nil))
        XCTAssertNotNil(parakeet.requestValidationError(translateToEnglish: false, language: "ja"))
        XCTAssertNil(parakeet.requestValidationError(translateToEnglish: false, language: "de"))
        XCTAssertNil(parakeet.requestValidationError(translateToEnglish: false, language: "ru"))
    }

    func testParakeetLabelStatesSpeedAndCoverage() throws {
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .parakeetTDTV3 }
        )
        let label = model.userFacingLabel(isRecommended: false)
        XCTAssertTrue(label.contains("Fastest"), label)
        XCTAssertTrue(label.contains("25 European languages"), label)
    }

    /// `available()` already filters by RAM, so stating RAM in a label is
    /// noise the reader has to look past.
    func testLabelsCarryNoFactTrueOfEveryModel() {
        for model in WhisperModel.all {
            let label = model.userFacingLabel(isRecommended: false)
            XCTAssertFalse(label.contains("punctuated"), label)
            XCTAssertFalse(label.contains("RAM"), label)
        }
    }
}
