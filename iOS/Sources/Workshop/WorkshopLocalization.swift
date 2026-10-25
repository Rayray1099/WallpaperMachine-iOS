import Foundation

/// The languages the Workshop surface ships in. The rest of the iOS app owns its
/// `*.lproj` catalogs; the Workshop keeps its own strings here so this module can be
/// reviewed and compiled without touching the UI Agent's resources.
enum WorkshopLanguage: String, Sendable {
    case english
    case traditionalChinese
}

/// English and Traditional Chinese text for the Workshop surface.
///
/// Every string is written beside its translation at the call site (`WS("Search", "搜尋")`),
/// so a String cannot be added without both languages. Values that Steam itself supplies
/// (titles, creator names, tags, descriptions) are shown with `Text(verbatim:)` and never
/// become translation keys.
enum WorkshopL10n {
    /// The language the Workshop renders in. The app's preferred-language list is used,
    /// which is also what iOS changes when someone picks a per-app language. A test or a
    /// SwiftUI preview can override it with the `WMWorkshopLanguage` default.
    static var language: WorkshopLanguage {
        if let forced = UserDefaults.standard.string(forKey: "WMWorkshopLanguage"),
           let parsed = WorkshopLanguage(rawValue: forced) {
            return parsed
        }
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") {
                // Only Traditional Chinese is shipped. Simplified falls back to English
                // rather than showing a machine conversion of the Traditional text.
                if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk")
                    || lower.contains("-mo") {
                    return .traditionalChinese
                }
                return .english
            }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }

    static var locale: Locale {
        switch language {
        case .english: Locale(identifier: "en_US")
        case .traditionalChinese: Locale(identifier: "zh_Hant")
        }
    }

    /// The one translation helper. Keep both arguments literal at the call site so the
    /// text is greppable and reviewable.
    @inline(__always)
    static func text(_ english: String, _ traditionalChinese: String) -> String {
        language == .traditionalChinese ? traditionalChinese : english
    }
}

/// Short spelling for the helper above. The Workshop module uses it everywhere a person
/// can read the result; `WS` is module-internal and documented here to avoid collisions
/// with the app's own `L`/`String(localized:)` helpers.
@inline(__always)
func WS(_ english: String, _ traditionalChinese: String) -> String {
    WorkshopL10n.text(english, traditionalChinese)
}

/// Number, size and date formatting that follows the language chosen above rather than
/// an environment locale the embedding view may not have propagated.
enum WorkshopFormat {
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(WorkshopL10n.locale))
    }

    static func bytes(_ value: Int64) -> String {
        var style = ByteCountFormatStyle(style: .file)
        style.locale = WorkshopL10n.locale
        return style.format(value)
    }

    static func date(_ value: Date) -> String {
        value.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(WorkshopL10n.locale))
    }

    static func resultCount(_ count: Int) -> String {
        count == 1 ? WS("1 result", "1 個結果") : String(format: WS("%d results", "%d 個結果"), count)
    }

    static func subscribedCount(_ count: Int) -> String {
        count == 1
            ? WS("1 subscribed", "1 個訂閱")
            : String(format: WS("%d subscribed", "%d 個訂閱"), count)
    }
}

/// A small log seam. The Workshop never logs cookie values, refresh tokens, passwords or
/// response bodies; only categories, status codes and counts.
enum WorkshopLog {
    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Workshop] \(message())")
        #endif
    }

    static func warn(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Workshop] warning: \(message())")
        #endif
    }
}
