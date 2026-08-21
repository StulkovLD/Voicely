import XCTest
@testable import VoicelyCore

final class WhisperModelCatalogTests: XCTestCase {
    func testCatalogMatchesRequestedProductLine() {
        XCTAssertEqual(
            WhisperModel.all.map(\.variant),
            [
                "gigaam-v3-e2e-rnnt",
                "gigaam-multilingual-ctc",
                "large-v3-v20240930_turbo_632MB",
                "large-v3_turbo",
                "medium",
            ]
        )
    }

    func testAvailabilityFollowsRAMThresholds() {
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 8).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "gigaam-multilingual-ctc", "large-v3-v20240930_turbo_632MB"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 16).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "gigaam-multilingual-ctc", "large-v3-v20240930_turbo_632MB", "medium"]
        )
        XCTAssertEqual(
            WhisperModel.available(forSystemRAMGB: 24).map(\.variant),
            ["gigaam-v3-e2e-rnnt", "gigaam-multilingual-ctc", "large-v3-v20240930_turbo_632MB", "large-v3_turbo", "medium"]
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
        let label = model.userFacingLabel(isRecommended: false)
        XCTAssertTrue(label.contains("Best in Russian"), label)
        XCTAssertTrue(label.contains("RU only"), "must state it speaks nothing else: \(label)")
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

        let multilingual = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .gigaAMMultilingualCTC }
        )
        XCTAssertEqual(multilingual.capabilities.supportedLanguages, ["ru", "en", "kk", "ky", "uz"])
        XCTAssertTrue(multilingual.capabilities.supportsLanguageDetection)
        XCTAssertFalse(multilingual.capabilities.supportsTranslationToEnglish)
        XCTAssertEqual(multilingual.capabilities.minimumMacOSMajorVersion, 15)
        XCTAssertNotNil(multilingual.requestValidationError(translateToEnglish: true, language: nil))
        XCTAssertNotNil(multilingual.requestValidationError(translateToEnglish: false, language: "de"))
        XCTAssertNil(multilingual.requestValidationError(translateToEnglish: false, language: "en"))
        XCTAssertNil(multilingual.requestValidationError(translateToEnglish: false, language: "ru"))
        XCTAssertNil(multilingual.requestValidationError(translateToEnglish: false, language: nil))
    }

    func testMultilingualLabelStatesItsCapabilityBoundary() throws {
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.variant == "gigaam-multilingual-ctc" }
        )
        let label = model.userFacingLabel(isRecommended: false)
        XCTAssertTrue(label.contains("Best in Russian"), label)
        XCTAssertTrue(label.contains("RU/EN/KK/KY/UZ"), label)
    }

    func testWhisperKitModelsAreLabeledForAnyLanguage() throws {
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.backend == .whisperKit }
        )
        XCTAssertTrue(model.userFacingLabel(isRecommended: false).contains("Any language"))
    }

    /// Every model punctuates and `available()` already filters by RAM, so
    /// neither fact distinguishes anything — they only cost the reader a scan.
    func testLabelsCarryNoFactTrueOfEveryModel() {
        for model in WhisperModel.all {
            let label = model.userFacingLabel(isRecommended: false)
            XCTAssertFalse(label.contains("punctuated"), label)
            XCTAssertFalse(label.contains("RAM"), label)
        }
    }

    /// The two GigaAM models sit at the same size and both lead in Russian;
    /// coverage is the only thing that tells them apart, so it must be visible.
    func testTheTwoGigaAMModelsAreToldApartByCoverage() throws {
        let ru = try XCTUnwrap(WhisperModel.all.first { $0.backend == .gigaAMV3E2ERNNT })
        let multi = try XCTUnwrap(WhisperModel.all.first { $0.backend == .gigaAMMultilingualCTC })

        XCTAssertNotEqual(
            ru.userFacingLabel(isRecommended: false),
            multi.userFacingLabel(isRecommended: false)
        )
        XCTAssertNotEqual(ru.onboardingHint, multi.onboardingHint)
    }
}
