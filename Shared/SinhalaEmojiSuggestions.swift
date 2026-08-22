import Foundation

/// Offline Sinhala word → emoji suggestions compiled from Unicode CLDR
/// annotations plus a colloquial overlay. Returns at most two emoji for the
/// right suggestion column.
enum SinhalaEmojiSuggestions {
    private static let maximumResults = 2

    private static let index: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "SinhalaEmojiIndex", withExtension: "json"),
              let loaded = loadIndex(from: url) else {
            return [:]
        }
        return loaded
    }()

    /// Test / script entry point that bypasses the extension bundle.
    static func loadIndex(from url: URL) -> [String: [String]]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return nil
        }
        return decoded
    }

    static func emoji(
        forComposing composing: String,
        bestWord: String?,
        index: [String: [String]]? = nil
    ) -> [String] {
        let table = index ?? Self.index
        guard !composing.isEmpty, !table.isEmpty else { return [] }

        if let exact = lookup(composing, in: table), !exact.isEmpty {
            return Array(exact.prefix(maximumResults))
        }

        // While the user is still typing, surface emoji for the best dictionary
        // completion when the composing text is a leading substring of it.
        if let bestWord,
           !bestWord.isEmpty,
           bestWord != composing,
           bestWord.unicodeScalars.starts(with: composing.unicodeScalars),
           let fromBest = lookup(bestWord, in: table),
           !fromBest.isEmpty {
            return Array(fromBest.prefix(maximumResults))
        }

        return []
    }

    private static func lookup(_ query: String, in table: [String: [String]]) -> [String]? {
        if let exact = table[query], !exact.isEmpty {
            return exact
        }
        // Prefix match mirrors emoji-picker search: "හින" finds "හිනා".
        // Compare Unicode scalars — not Characters — because Sinhala vowel
        // signs fold into grapheme clusters (හර vs හරි would otherwise miss).
        let queryScalars = Array(query.unicodeScalars)
        guard queryScalars.count >= 2 else { return nil }
        var bestKey: String?
        var bestValues: [String] = []
        var bestLength = Int.max
        for (token, values) in table {
            guard !values.isEmpty else { continue }
            let tokenScalars = Array(token.unicodeScalars)
            guard tokenScalars.count >= queryScalars.count,
                  tokenScalars.starts(with: queryScalars) else { continue }
            let length = tokenScalars.count
            if bestKey == nil
                || length < bestLength
                || (length == bestLength && token < bestKey!) {
                bestKey = token
                bestValues = values
                bestLength = length
            }
        }
        return bestValues.isEmpty ? nil : bestValues
    }

    /// Unique emoji count in the active index (for tests / diagnostics).
    static func uniqueEmojiCount(index: [String: [String]]? = nil) -> Int {
        let table = index ?? Self.index
        return Set(table.values.flatMap { $0 }).count
    }
}
