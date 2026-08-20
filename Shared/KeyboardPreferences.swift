import Foundation

/// Preferences shared by the containing app and the keyboard extension.
/// Both targets require the same App Group entitlement for this store.
enum KeyboardPreferences {
    enum TopRow: String, CaseIterable, Identifiable {
        case disabled, numbers, emoji

        var id: String { rawValue }

        var title: String {
            switch self {
            case .disabled: return "Off"
            case .numbers: return "123"
            case .emoji: return "Emoji"
            }
        }
    }

    enum KeySpacing: String, CaseIterable, Identifiable {
        case compact, standard, spacious
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var detail: String {
            switch self {
            case .compact: "Tighter gaps fit more around each key."
            case .standard: "Balanced spacing for everyday typing."
            case .spacious: "Wider gaps give each key more separation."
            }
        }
        var horizontalGap: Double { self == .compact ? 4 : (self == .spacious ? 8 : 6) }
        var verticalAdjustment: Double { self == .compact ? -1 : (self == .spacious ? 1 : 0) }
    }

    enum OneHandedPosition: String, CaseIterable, Identifiable {
        case centered, left, right
        var id: String { rawValue }
        var title: String { self == .centered ? "Center" : rawValue.capitalized }
        var detail: String {
            switch self {
            case .centered: "Uses the full available keyboard width."
            case .left: "Narrows the key grid and aligns it to the left."
            case .right: "Narrows the key grid and aligns it to the right."
            }
        }
    }

    enum HapticStrength: String, CaseIterable, Identifiable {
        case light, standard, strong
        var id: String { rawValue }
        var title: String { self == .standard ? "Standard" : rawValue.capitalized }
        var intensity: Double { self == .light ? 0.45 : (self == .strong ? 1 : 0.75) }
    }

    enum DeleteRepeatSpeed: String, CaseIterable, Identifiable {
        case slow, standard, fast
        var id: String { rawValue }
        var title: String { self == .standard ? "Standard" : rawValue.capitalized }
        var interval: Double { self == .slow ? 0.12 : (self == .fast ? 0.05 : 0.08) }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum EmojiSkinTone: String, CaseIterable, Identifiable {
        case standard, light, mediumLight, medium, mediumDark, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "Default"
            case .light: return "Light"
            case .mediumLight: return "Medium-Light"
            case .medium: return "Medium"
            case .mediumDark: return "Medium-Dark"
            case .dark: return "Dark"
            }
        }

        var preview: String {
            switch self {
            case .standard: return "👍"
            case .light: return "👍🏻"
            case .mediumLight: return "👍🏼"
            case .medium: return "👍🏽"
            case .mediumDark: return "👍🏾"
            case .dark: return "👍🏿"
            }
        }

        var modifierScalar: UnicodeScalar? {
            switch self {
            case .standard: return nil
            case .light: return UnicodeScalar(0x1F3FB)
            case .mediumLight: return UnicodeScalar(0x1F3FC)
            case .medium: return UnicodeScalar(0x1F3FD)
            case .mediumDark: return UnicodeScalar(0x1F3FE)
            case .dark: return UnicodeScalar(0x1F3FF)
            }
        }
    }

    static let appGroupIdentifier = "group.lk.org.akshara.keyboard"
    static let layoutKey = "selectedKeyboardLayout"
    static let emojiKey = "emojiPickerEnabled"
    static let hapticsKey = "keyboardHapticsEnabled"
    static let fullAccessKey = "keyboardFullAccessConfirmed"
    static let suggestionsKey = "keyboardSuggestionsEnabled"
    static let predictionProviderKey = "selectedPredictionProvider"
    static let doubleSpacePeriodKey = "doubleSpacePeriodEnabled"
    static let numberRowKey = "numberRowEnabled"
    static let topRowKey = "keyboardTopRow"
    static let longPressPunctuationKey = "longPressPunctuationEnabled"
    static let smartQuotesKey = "smartQuotesEnabled"
    static let smartPunctuationSpacingKey = "smartPunctuationSpacingEnabled"
    static let englishForOneWordKey = "englishForOneWordEnabled"
    static let characterPreviewKey = "characterPreviewEnabled"
    static let keySpacingKey = "keyboardKeySpacing"
    static let oneHandedPositionKey = "keyboardOneHandedPosition"
    static let hapticStrengthKey = "keyboardHapticStrength"
    static let keyClicksKey = "keyboardKeyClicksEnabled"
    static let deleteRepeatSpeedKey = "keyboardDeleteRepeatSpeed"
    static let appearanceKey = "keyboardAppearance"
    static let highContrastKey = "keyboardHighContrastEnabled"
    static let emojiSkinToneKey = "keyboardEmojiSkinTone"
    static let showTouchAreasKey = "keyboardShowTouchAreas"
    static let predictiveTouchAreasKey = "keyboardPredictiveTouchAreas"

    static let supportsSuggestions = true

    /// Values read on every keypress / hit-test. `reload()` refreshes this
    /// snapshot so the typing path never opens the App Group suite mid-tap.
    struct HotPathCache {
        var hapticsEnabled = false
        var hapticIntensity = 0.75
        var keyClicksEnabled = true
        var keySpacing = KeySpacing.standard
        var keySpacingHorizontalGap = 6.0
        var longPressPunctuationEnabled = true
        var characterPreviewEnabled = false
        var doubleSpacePeriodEnabled = true
        var smartQuotesEnabled = true
        var smartPunctuationSpacingEnabled = true
        var deleteRepeatInterval = 0.08
        var highContrastEnabled = false
        var showTouchAreas = false
        var predictiveTouchAreas = false
    }

    private(set) static var hotPath = HotPathCache()

    /// Opening the App Group suite is measurable work in a keyboard's hot
    /// path. Keep one process-local handle; `reload()` still synchronizes it
    /// whenever the extension becomes visible.
    static let defaults: UserDefaults = {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }()

    /// The keyboard extension runs in a separate process from the settings
    /// app. Refresh its App Group cache as it becomes visible so changes made
    /// in the app are reflected before the extension rebuilds its layout.
    static func reload() {
        defaults.synchronize()
        refreshHotPathCache()
    }

    static func refreshHotPathCache() {
        let spacing = keySpacing()
        let strength = hapticStrength()
        hotPath = HotPathCache(
            hapticsEnabled: hapticsEnabled(),
            hapticIntensity: strength.intensity,
            keyClicksEnabled: keyClicksEnabled(),
            keySpacing: spacing,
            keySpacingHorizontalGap: spacing.horizontalGap,
            longPressPunctuationEnabled: longPressPunctuationEnabled(),
            characterPreviewEnabled: characterPreviewEnabled(),
            doubleSpacePeriodEnabled: doubleSpacePeriodEnabled(),
            smartQuotesEnabled: smartQuotesEnabled(),
            smartPunctuationSpacingEnabled: smartPunctuationSpacingEnabled(),
            deleteRepeatInterval: deleteRepeatSpeed().interval,
            highContrastEnabled: highContrastEnabled(),
            showTouchAreas: showTouchAreas(),
            predictiveTouchAreas: predictiveTouchAreas()
        )
    }

    /// The app and keyboard extension are separate processes. Flush each
    /// small preference update through the App Group so an extension opened
    /// immediately after a toggle observes the new value rather than a
    /// buffered copy from the containing app.
    private static func persist(_ value: Any, forKey key: String) {
        let store = defaults
        store.set(value, forKey: key)
        store.synchronize()
        refreshHotPathCache()
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

    static func emojiSkinTone() -> EmojiSkinTone {
        guard let value = defaults.string(forKey: emojiSkinToneKey),
              let tone = EmojiSkinTone(rawValue: value) else { return .standard }
        return tone
    }

    static func setEmojiSkinTone(_ tone: EmojiSkinTone) {
        persist(tone.rawValue, forKey: emojiSkinToneKey)
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

    /// Migrates the former number-row toggle without making an existing user
    /// choose a setting again. New writes use the mutually exclusive value.
    static func topRow() -> TopRow {
        if let value = defaults.string(forKey: topRowKey), let row = TopRow(rawValue: value) {
            return row
        }
        return numberRowEnabled() ? .numbers : .disabled
    }

    static func setTopRow(_ row: TopRow) {
        persist(row.rawValue, forKey: topRowKey)
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

    static func smartPunctuationSpacingEnabled() -> Bool {
        defaults.object(forKey: smartPunctuationSpacingKey) as? Bool ?? true
    }

    static func setSmartPunctuationSpacingEnabled(_ enabled: Bool) {
        persist(enabled, forKey: smartPunctuationSpacingKey)
    }

    static func englishForOneWordEnabled() -> Bool {
        defaults.object(forKey: englishForOneWordKey) as? Bool ?? false
    }

    static func setEnglishForOneWordEnabled(_ enabled: Bool) {
        persist(enabled, forKey: englishForOneWordKey)
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

    static func keySpacing() -> KeySpacing { enumValue(forKey: keySpacingKey, default: .standard) }
    static func setKeySpacing(_ value: KeySpacing) { persist(value.rawValue, forKey: keySpacingKey) }

    static func oneHandedPosition() -> OneHandedPosition { enumValue(forKey: oneHandedPositionKey, default: .centered) }
    static func setOneHandedPosition(_ value: OneHandedPosition) { persist(value.rawValue, forKey: oneHandedPositionKey) }

    static func hapticStrength() -> HapticStrength { enumValue(forKey: hapticStrengthKey, default: .standard) }
    static func setHapticStrength(_ value: HapticStrength) { persist(value.rawValue, forKey: hapticStrengthKey) }

    static func keyClicksEnabled() -> Bool { defaults.object(forKey: keyClicksKey) as? Bool ?? true }
    static func setKeyClicksEnabled(_ enabled: Bool) { persist(enabled, forKey: keyClicksKey) }

    static func deleteRepeatSpeed() -> DeleteRepeatSpeed { enumValue(forKey: deleteRepeatSpeedKey, default: .standard) }
    static func setDeleteRepeatSpeed(_ value: DeleteRepeatSpeed) { persist(value.rawValue, forKey: deleteRepeatSpeedKey) }

    static func appearance() -> Appearance { enumValue(forKey: appearanceKey, default: .system) }
    static func setAppearance(_ value: Appearance) { persist(value.rawValue, forKey: appearanceKey) }

    static func highContrastEnabled() -> Bool { defaults.object(forKey: highContrastKey) as? Bool ?? false }
    static func setHighContrastEnabled(_ enabled: Bool) { persist(enabled, forKey: highContrastKey) }

    static func showTouchAreas() -> Bool { defaults.object(forKey: showTouchAreasKey) as? Bool ?? false }
    static func setShowTouchAreas(_ enabled: Bool) { persist(enabled, forKey: showTouchAreasKey) }

    static func predictiveTouchAreas() -> Bool { defaults.object(forKey: predictiveTouchAreasKey) as? Bool ?? false }
    static func setPredictiveTouchAreas(_ enabled: Bool) { persist(enabled, forKey: predictiveTouchAreasKey) }

    private static func enumValue<Value: RawRepresentable>(forKey key: String, default defaultValue: Value) -> Value where Value.RawValue == String {
        defaults.string(forKey: key).flatMap(Value.init(rawValue:)) ?? defaultValue
    }
}
