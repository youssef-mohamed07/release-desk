/// The languages each store accepts for release notes.
abstract final class StoreLanguages {
  /// App Store Connect locales (App Store versions and TestFlight What to Test).
  static const appStore = [
    'ar-SA', 'ca', 'cs', 'da', 'de-DE', 'el', 'en-AU', 'en-CA', 'en-GB', 'en-US', 'es-ES', 'es-MX', 'fi', 'fr-CA', 'fr-FR', //
    'he', 'hi', 'hr', 'hu', 'id', 'it', 'ja', 'ko', 'ms', 'nl-NL', 'no', 'pl', 'pt-BR', 'pt-PT', 'ro', 'ru', 'sk', 'sv', //
    'th', 'tr', 'uk', 'vi', 'zh-Hans', 'zh-Hant',
  ];

  /// Google Play languages for a release's What's new.
  static const play = [
    'af', 'am', 'ar', 'az-AZ', 'be', 'bg', 'bn-BD', 'ca', 'cs-CZ', 'da-DK', 'de-DE', 'el-GR', 'en-AU', 'en-CA', 'en-GB', //
    'en-IN', 'en-SG', 'en-US', 'en-ZA', 'es-419', 'es-ES', 'es-US', 'et', 'eu-ES', 'fa', 'fi-FI', 'fil', 'fr-CA', 'fr-FR', //
    'gl-ES', 'hi-IN', 'hr', 'hu-HU', 'hy-AM', 'id', 'is-IS', 'it-IT', 'iw-IL', 'ja-JP', 'ka-GE', 'kk', 'km-KH', 'kn-IN', //
    'ko-KR', 'ky-KG', 'lo-LA', 'lt', 'lv', 'mk-MK', 'ml-IN', 'mn-MN', 'mr-IN', 'ms', 'ms-MY', 'my-MM', 'ne-NP', 'nl-NL', //
    'no-NO', 'pa', 'pl-PL', 'pt-BR', 'pt-PT', 'rm', 'ro', 'ru-RU', 'si-LK', 'sk', 'sl', 'sq', 'sr', 'sv-SE', 'sw', 'ta-IN', //
    'te-IN', 'th', 'tr-TR', 'uk', 'ur', 'uz', 'vi', 'zh-CN', 'zh-HK', 'zh-TW', 'zu',
  ];

  /// "Arabic (Saudi Arabia)" for "ar-SA" (or the Microsoft Store's "ar-sa"),
  /// in English. Unknown codes come back as they are.
  static String name(String code) {
    final id = code == 'iw-IL' ? 'he-IL' : (code == 'fil' ? 'fil-PH' : code);
    for (final e in _special.entries) {
      if (e.key.toLowerCase() == id.toLowerCase()) return e.value;
    }
    final parts = id.split('-');
    final language = _languages[parts.first == 'iw' ? 'he' : parts.first.toLowerCase()];
    if (language == null) return code;
    if (parts.length < 2) return language;
    return '$language (${_regions[parts[1].toUpperCase()] ?? parts[1]})';
  }

  static bool isRightToLeft(String code) => const ['ar', 'he', 'iw', 'fa', 'ur'].any((l) => code == l || code.startsWith('$l-'));

  static const _special = {'zh-Hans': 'Chinese, Simplified', 'zh-Hant': 'Chinese, Traditional'};

  static const _languages = {
    'af': 'Afrikaans', 'am': 'Amharic', 'ar': 'Arabic', 'az': 'Azerbaijani', 'be': 'Belarusian', 'bg': 'Bulgarian', 'bn': 'Bangla', //
    'ca': 'Catalan', 'cs': 'Czech', 'da': 'Danish', 'de': 'German', 'el': 'Greek', 'en': 'English', 'es': 'Spanish', 'et': 'Estonian', //
    'eu': 'Basque', 'fa': 'Persian', 'fi': 'Finnish', 'fil': 'Filipino', 'fr': 'French', 'gl': 'Galician', 'he': 'Hebrew', 'hi': 'Hindi', //
    'hr': 'Croatian', 'hu': 'Hungarian', 'hy': 'Armenian', 'id': 'Indonesian', 'is': 'Icelandic', 'it': 'Italian', 'ja': 'Japanese', //
    'ka': 'Georgian', 'kk': 'Kazakh', 'km': 'Khmer', 'kn': 'Kannada', 'ko': 'Korean', 'ky': 'Kyrgyz', 'lo': 'Lao', 'lt': 'Lithuanian', //
    'lv': 'Latvian', 'mk': 'Macedonian', 'ml': 'Malayalam', 'mn': 'Mongolian', 'mr': 'Marathi', 'ms': 'Malay', 'my': 'Burmese', //
    'ne': 'Nepali', 'nl': 'Dutch', 'no': 'Norwegian', 'pa': 'Punjabi', 'pl': 'Polish', 'pt': 'Portuguese', 'rm': 'Romansh', //
    'ro': 'Romanian', 'ru': 'Russian', 'si': 'Sinhala', 'sk': 'Slovak', 'sl': 'Slovenian', 'sq': 'Albanian', 'sr': 'Serbian', //
    'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil', 'te': 'Telugu', 'th': 'Thai', 'tr': 'Turkish', 'uk': 'Ukrainian', 'ur': 'Urdu', //
    'uz': 'Uzbek', 'vi': 'Vietnamese', 'zh': 'Chinese', 'zu': 'Zulu',
  };

  static const _regions = {
    '419': 'Latin America', 'AE': 'United Arab Emirates', 'AM': 'Armenia', 'AU': 'Australia', 'AZ': 'Azerbaijan', 'BD': 'Bangladesh', //
    'BR': 'Brazil', 'CA': 'Canada', 'CN': 'China mainland', 'CZ': 'Czechia', 'DE': 'Germany', 'DK': 'Denmark', 'EG': 'Egypt', //
    'ES': 'Spain', 'FI': 'Finland', 'FR': 'France', 'GB': 'United Kingdom', 'GE': 'Georgia', 'GR': 'Greece', 'HK': 'Hong Kong', //
    'HU': 'Hungary', 'IL': 'Israel', 'IN': 'India', 'IS': 'Iceland', 'IT': 'Italy', 'JP': 'Japan', 'KG': 'Kyrgyzstan', 'KH': 'Cambodia', //
    'KR': 'South Korea', 'LA': 'Laos', 'LK': 'Sri Lanka', 'MK': 'North Macedonia', 'MM': 'Myanmar', 'MN': 'Mongolia', 'MX': 'Mexico', //
    'MY': 'Malaysia', 'NL': 'Netherlands', 'NO': 'Norway', 'NP': 'Nepal', 'PH': 'Philippines', 'PL': 'Poland', 'PT': 'Portugal', //
    'RU': 'Russia', 'SA': 'Saudi Arabia', 'SE': 'Sweden', 'SG': 'Singapore', 'TR': 'Türkiye', 'TW': 'Taiwan', 'US': 'United States', //
    'ZA': 'South Africa',
  };
}

/// The notes worth sending: chosen languages with some text.
Map<String, String> notesIn(Map<String, String> notes, List<String> locales) => {
  for (final e in notes.entries)
    if (locales.contains(e.key) && e.value.trim().isNotEmpty) e.key: e.value,
};
