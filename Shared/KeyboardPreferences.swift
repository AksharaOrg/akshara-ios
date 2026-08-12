import Foundation

/// Preferences shared by the containing app and the keyboard extension.
/// Both targets require the same App Group entitlement for this store.
enum KeyboardPreferences {
    static let appGroupIdentifier = "group.lk.org.akshara.keyboard"
    static let layoutKey = "selectedKeyboardLayout"
    static let emojiKey = "emojiPickerEnabled"
    static let hapticsKey = "keyboardHapticsEnabled"
    static let suggestionsKey = "keyboardSuggestionsEnabled"

    /// The dictionary is still a small proof of concept. Keep suggestions
    /// unavailable until the full licensed corpus and ranking pass land.
    static let supportsSuggestions = false

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func selectedMode() -> SinhalaEngine.Mode {
        guard let rawValue = defaults.string(forKey: layoutKey),
              let mode = SinhalaEngine.Mode(rawValue: rawValue) else { return .sls }
        return mode
    }

    static func setSelectedMode(_ mode: SinhalaEngine.Mode) {
        defaults.set(mode.rawValue, forKey: layoutKey)
    }

    static func emojiEnabled() -> Bool {
        defaults.object(forKey: emojiKey) as? Bool ?? true
    }

    static func setEmojiEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: emojiKey)
    }

    static func hapticsEnabled() -> Bool {
        defaults.object(forKey: hapticsKey) as? Bool ?? true
    }

    static func setHapticsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: hapticsKey)
    }

    static func suggestionsEnabled() -> Bool {
        supportsSuggestions && (defaults.object(forKey: suggestionsKey) as? Bool ?? false)
    }
}
