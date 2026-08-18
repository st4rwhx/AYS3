// AppLanguage.swift — UI localization.
//
// Ported from AYS2. The mechanism is faithful; the string tables are seeded
// empty and filled progressively. English keys ARE the source text, so English
// is complete by construction and any missing translation falls back to English
// rather than showing a raw key. RTL is handled for Arabic.

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case arabic
    case spanish
    case french
    case german
    case italian
    case portuguese
    case japanese
    case korean

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System Default"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .arabic: return "العربية"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    static func resolvedSystemLanguage() -> AppLanguage {
        switch (Locale.current.language.languageCode?.identifier.lowercased() ?? "en") {
        case "zh": return .simplifiedChinese
        case "ar": return .arabic
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ja": return .japanese
        case "ko": return .korean
        default:   return .english
        }
    }

    var resolved: AppLanguage { self == .system ? Self.resolvedSystemLanguage() : self }
    var layoutDirection: LayoutDirection { resolved == .arabic ? .rightToLeft : .leftToRight }

    /// Look up a key in the resolved language, falling back to English (the key).
    func localized(_ key: String) -> String {
        Self.translations[resolved]?[key] ?? key
    }

    /// Per-language string tables. Seeded empty — English needs none (keys are
    /// English), other languages are filled over time. A missing entry returns
    /// the English key, so the UI never shows a raw identifier.
    // Filled progressively, e.g. [.french: ["Games": "Jeux", …]].
    private static let translations: [AppLanguage: [String: String]] = [:]
}
