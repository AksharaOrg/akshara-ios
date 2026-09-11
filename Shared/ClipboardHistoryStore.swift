import Foundation
import UIKit

/// Recent and pinned text clipboard items shared by the host app and keyboard
/// extension. Pinned items live separately from the rolling history, so they
/// are only removed through an explicit delete action.
/// Contents are never logged. While Clipboard History is enabled and the
/// keyboard is visible, new pasteboard text is captured automatically.
/// iOS may show a paste-confirmation prompt when the pasteboard is read.
enum ClipboardHistoryStore {
    static let maximumItems = 10
    static let maximumItemLength = 10_000

    private static let itemsKey = "clipboardHistoryItems"
    private static let pinnedItemsKey = "clipboardHistoryPinnedItems"
    private static let changeCountKey = "clipboardHistoryChangeCount"

    private static var defaults: UserDefaults { KeyboardPreferences.defaults }

    static func items() -> [String] {
        defaults.stringArray(forKey: itemsKey) ?? []
    }

    static func pinnedItems() -> [String] {
        defaults.stringArray(forKey: pinnedItemsKey) ?? []
    }

    /// Clears only the rolling clipboard history. Pinned clips are intentionally
    /// retained until the user deletes them one by one.
    static func clearHistory() {
        let store = defaults
        store.removeObject(forKey: itemsKey)
        store.removeObject(forKey: changeCountKey)
    }

    /// Used only for an explicit full reset of all keyboard data.
    static func clearAll() {
        clearHistory()
        defaults.removeObject(forKey: pinnedItemsKey)
    }

    static func remove(at index: Int) {
        var current = items()
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        persist(current)
    }

    static func pin(at index: Int) {
        var recent = items()
        guard recent.indices.contains(index) else { return }
        let item = recent.remove(at: index)
        var pinned = pinnedItems()
        pinned.removeAll { $0 == item }
        pinned.insert(item, at: 0)
        persist(recent)
        persistPinned(pinned)
    }

    static func removePinned(at index: Int) {
        var pinned = pinnedItems()
        guard pinned.indices.contains(index) else { return }
        pinned.remove(at: index)
        persistPinned(pinned)
    }

    /// Reads the general pasteboard when allowed and records a new text item.
    /// Returns `true` when the stored list changed.
    @discardableResult
    static func captureFromPasteboardIfNeeded(
        hasFullAccess: Bool,
        isSecureField: Bool
    ) -> Bool {
        guard KeyboardPreferences.clipboardHistoryEnabled() else { return false }
        guard hasFullAccess, !isSecureField else { return false }

        let board = UIPasteboard.general
        let changeCount = board.changeCount
        if defaults.object(forKey: changeCountKey) as? Int == changeCount {
            return false
        }
        defaults.set(changeCount, forKey: changeCountKey)

        guard let string = board.string else {
            return false
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let stored: String
        if string.count > maximumItemLength {
            stored = String(string.prefix(maximumItemLength))
        } else {
            stored = string
        }
        return record(stored)
    }

    @discardableResult
    private static func record(_ text: String) -> Bool {
        var current = items()
        current.removeAll { $0 == text }
        current.insert(text, at: 0)
        if current.count > maximumItems {
            current = Array(current.prefix(maximumItems))
        }
        persist(current)
        return true
    }

    private static func persist(_ items: [String]) {
        defaults.set(items, forKey: itemsKey)
    }

    private static func persistPinned(_ items: [String]) {
        defaults.set(items, forKey: pinnedItemsKey)
    }
}
