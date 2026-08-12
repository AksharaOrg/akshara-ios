import Foundation

/// Preferences shared by the containing app and the keyboard extension.
/// Both targets require the same App Group entitlement for this store.
enum KeyboardPreferences {
    static let appGroupIdentifier = "group.lk.org.akshara.keyboard"
    static let layoutKey = "selectedKeyboardLayout"

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
}
