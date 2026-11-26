import Foundation

/// The languages each store accepts for release notes.
public enum StoreLanguages {
    /// App Store Connect locales (App Store versions and TestFlight What to Test).
    public static let appStore = [
        "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR",
        "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sv",
        "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Google Play languages for a release's What's new.
    public static let play = [
        "af", "am", "ar", "az-AZ", "be", "bg", "bn-BD", "ca", "cs-CZ", "da-DK", "de-DE", "el-GR", "en-AU", "en-CA", "en-GB",
        "en-IN", "en-SG", "en-US", "en-ZA", "es-419", "es-ES", "es-US", "et", "eu-ES", "fa", "fi-FI", "fil", "fr-CA", "fr-FR",
        "gl-ES", "hi-IN", "hr", "hu-HU", "hy-AM", "id", "is-IS", "it-IT", "iw-IL", "ja-JP", "ka-GE", "kk", "km-KH", "kn-IN",
        "ko-KR", "ky-KG", "lo-LA", "lt", "lv", "mk-MK", "ml-IN", "mn-MN", "mr-IN", "ms", "ms-MY", "my-MM", "ne-NP", "nl-NL",
        "no-NO", "pa", "pl-PL", "pt-BR", "pt-PT", "rm", "ro", "ru-RU", "si-LK", "sk", "sl", "sq", "sr", "sv-SE", "sw", "ta-IN",
        "te-IN", "th", "tr-TR", "uk", "ur", "uz", "vi", "zh-CN", "zh-HK", "zh-TW", "zu",
    ]

    /// "Arabic (Saudi Arabia)" for "ar-SA", in English.
    public static func name(_ code: String) -> String {
        let id = code == "iw-IL" ? "he-IL" : code == "fil" ? "fil-PH" : code
        return Locale(identifier: "en").localizedString(forIdentifier: id) ?? code
    }

    public static func isRightToLeft(_ code: String) -> Bool {
        ["ar", "he", "iw", "fa", "ur"].contains { code == $0 || code.hasPrefix($0 + "-") }
    }
}
