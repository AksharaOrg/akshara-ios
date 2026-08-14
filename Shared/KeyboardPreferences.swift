import Foundation

/// Preferences shared by the containing app and the keyboard extension.
/// Both targets require the same App Group entitlement for this store.
enum KeyboardPreferences {
    static let appGroupIdentifier = "group.lk.org.akshara.keyboard"
    static let layoutKey = "selectedKeyboardLayout"
    static let emojiKey = "emojiPickerEnabled"
    static let hapticsKey = "keyboardHapticsEnabled"
    static let fullAccessKey = "keyboardFullAccessConfirmed"
    static let suggestionsKey = "keyboardSuggestionsEnabled"
    static let predictionProviderKey = "selectedPredictionProvider"

    static let supportsSuggestions = true

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
        defaults.object(forKey: hapticsKey) as? Bool ?? false
    }

    static func setHapticsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: hapticsKey)
    }

    /// The containing app cannot query a keyboard extension's `hasFullAccess`
    /// property itself. The extension records a successful check whenever it
    /// becomes visible, allowing the app to enable features that need it.
    static func fullAccessConfirmed() -> Bool {
        defaults.object(forKey: fullAccessKey) as? Bool ?? false
    }

    static func setFullAccessConfirmed(_ confirmed: Bool) {
        defaults.set(confirmed, forKey: fullAccessKey)
        // The keyboard and containing app run in separate processes. Flush
        // this small status handoff so the app can reflect a just-enabled
        // Full Access setting as soon as it returns to the foreground.
        defaults.synchronize()
    }

    static func suggestionsEnabled() -> Bool {
        supportsSuggestions && (defaults.object(forKey: suggestionsKey) as? Bool ?? true)
    }

    static func setSuggestionsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: suggestionsKey)
    }

    static func selectedPredictionProvider() -> String {
        defaults.string(forKey: predictionProviderKey) ?? "uom-frequency-list-v1"
    }

    static func setSelectedPredictionProvider(_ identifier: String) {
        defaults.set(identifier, forKey: predictionProviderKey)
    }
}
