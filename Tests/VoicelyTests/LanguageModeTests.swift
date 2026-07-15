import XCTest
@testable import Voicely

final class LanguageModeTests: XCTestCase {
    func testVisibleLanguageModesAreOnlyAutoAndTranslateToEnglish() {
        XCTAssertEqual(LanguageMode.visibleCases, [.auto, .translateToEnglish])
    }

    func testFixedLanguageSettingsSurviveForCapabilityConstrainedModels() {
        let defaults = UserDefaults(suiteName: "LanguageModeTests.legacy")!
        defaults.removePersistentDomain(forName: "LanguageModeTests.legacy")

        defaults.set("ru", forKey: "voicelyLanguage")
        XCTAssertEqual(LanguageMode.restored(from: defaults), .russian)

        defaults.set("en", forKey: "voicelyLanguage")
        XCTAssertEqual(LanguageMode.restored(from: defaults), .english)
    }

    func testAutoDoesNotForceLanguageOrTranslate() {
        XCTAssertNil(LanguageMode.auto.preferredLanguage)
        XCTAssertFalse(LanguageMode.auto.translateToEnglish)
    }

    func testTranslateToEnglishTranslatesWithoutForcedLanguage() {
        XCTAssertNil(LanguageMode.translateToEnglish.preferredLanguage)
        XCTAssertTrue(LanguageMode.translateToEnglish.translateToEnglish)
    }
}
