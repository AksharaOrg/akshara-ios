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
    static let doubleSpacePeriodKey = "doubleSpacePeriodEnabled"
    static let numberRowKey = "numberRowEnabled"
    static let longPressPunctuationKey = "longPressPunctuationEnabled"
    static let smartQuotesKey = "smartQuotesEnabled"
    static let characterPreviewKey = "characterPreviewEnabled"

    static let supportsSuggestions = true

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    /// The app and keyboard extension are separate processes. Flush each
    /// small preference update through the App Group so an extension opened
    /// immediately after a toggle observes the new value rather than a
    /// buffered copy from the containing app.
    private static func persist(_ value: Any, forKey key: String) {
        let store = defaults
        store.set(value, forKey: key)
        store.synchronize()
    }

    static func selectedMode() -> SinhalaEngine.Mode {
        guard let rawValue = defaults.string(forKey: layoutKey),
              let mode = SinhalaEngine.Mode(rawValue: rawValue) else { return .sls }
        return mode
    }

    static func setSelectedMode(_ mode: SinhalaEngine.Mode) {
        persist(mode.rawValue, forKey: layoutKey)
    }

    static func emojiEnabled() -> Bool {
        defaults.object(forKey: emojiKey) as? Bool ?? true
    }

    static func setEmojiEnabled(_ enabled: Bool) {
        persist(enabled, forKey: emojiKey)
    }

    static func hapticsEnabled() -> Bool {
        defaults.object(forKey: hapticsKey) as? Bool ?? false
    }

    static func setHapticsEnabled(_ enabled: Bool) {
        persist(enabled, forKey: hapticsKey)
    }

    /// The containing app cannot query a keyboard extension's `hasFullAccess`
    /// property itself. The extension records a successful check whenever it
    /// becomes visible, allowing the app to enable features that need it.
    static func fullAccessConfirmed() -> Bool {
        defaults.object(forKey: fullAccessKey) as? Bool ?? false
    }

    static func setFullAccessConfirmed(_ confirmed: Bool) {
        persist(confirmed, forKey: fullAccessKey)
    }

    static func suggestionsEnabled() -> Bool {
        supportsSuggestions && (defaults.object(forKey: suggestionsKey) as? Bool ?? true)
    }

    static func setSuggestionsEnabled(_ enabled: Bool) {
        persist(enabled, forKey: suggestionsKey)
    }

    static func selectedPredictionProvider() -> String {
        defaults.string(forKey: predictionProviderKey) ?? "uom-frequency-list-v1"
    }

    static func setSelectedPredictionProvider(_ identifier: String) {
        persist(identifier, forKey: predictionProviderKey)
    }

    static func doubleSpacePeriodEnabled() -> Bool {
        defaults.object(forKey: doubleSpacePeriodKey) as? Bool ?? true
    }

    static func setDoubleSpacePeriodEnabled(_ enabled: Bool) {
        persist(enabled, forKey: doubleSpacePeriodKey)
    }

    static func numberRowEnabled() -> Bool {
        defaults.object(forKey: numberRowKey) as? Bool ?? false
    }

    static func setNumberRowEnabled(_ enabled: Bool) {
        persist(enabled, forKey: numberRowKey)
    }

    static func longPressPunctuationEnabled() -> Bool {
        defaults.object(forKey: longPressPunctuationKey) as? Bool ?? true
    }

    static func setLongPressPunctuationEnabled(_ enabled: Bool) {
        persist(enabled, forKey: longPressPunctuationKey)
    }

    static func smartQuotesEnabled() -> Bool {
        defaults.object(forKey: smartQuotesKey) as? Bool ?? true
    }

    static func setSmartQuotesEnabled(_ enabled: Bool) {
        persist(enabled, forKey: smartQuotesKey)
    }

    /// Apple calls this "Character Preview". The system preference isn't
    /// available to third-party keyboard extensions, so keep an equivalent
    /// app-group setting for Akshara instead.
    static func characterPreviewEnabled() -> Bool {
        defaults.object(forKey: characterPreviewKey) as? Bool ?? false
    }

    static func setCharacterPreviewEnabled(_ enabled: Bool) {
        persist(enabled, forKey: characterPreviewKey)
    }
}
