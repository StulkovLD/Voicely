import Foundation

enum LanguageMode: String, CaseIterable, Sendable {
    case auto = "auto"
    case russian = "ru"
    case english = "en"
    case translateToEnglish = "translate_en"

    static let visibleCases: [LanguageMode] = [.auto, .translateToEnglish]

    var menuTitle: String {
        switch self {
        case .auto:
            return "Auto"
        case .russian:
            return "Russian"
        case .english:
            return "English"
        case .translateToEnglish:
            return "Translate to English"
        }
    }

    var preferredLanguage: String? {
        switch self {
        case .russian:
            return "ru"
        case .english:
            return "en"
        case .auto, .translateToEnglish:
            return nil
        }
    }

    var translateToEnglish: Bool {
        self == .translateToEnglish
    }

    static func restored(from defaults: UserDefaults = .standard) -> LanguageMode {
        guard let raw = defaults.string(forKey: "voicelyLanguage"),
              let mode = LanguageMode(rawValue: raw) else {
            return .auto
        }
        return mode
    }
}
