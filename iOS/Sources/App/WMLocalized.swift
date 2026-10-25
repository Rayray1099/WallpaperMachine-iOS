import Foundation

/// Localized strings for places that need a `String` rather than a `Text`
/// (alerts, accessibility values, formatted counts and error messages).
enum WMLocalized {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }
}
