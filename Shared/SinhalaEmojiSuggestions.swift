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

    private static let prefixIndex = SinhalaEmojiPrefixIndex(index: index)

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
        let lookupIndex = index.map { SinhalaEmojiPrefixIndex(index: $0) } ?? Self.prefixIndex
        guard !composing.isEmpty else { return [] }

        if let exact = lookupIndex.lookup(composing), !exact.isEmpty {
            return Array(exact.prefix(maximumResults))
        }

        // While the user is still typing, surface emoji for the best dictionary
        // completion when the composing text is a leading substring of it.
        if let bestWord,
           !bestWord.isEmpty,
           bestWord != composing,
           bestWord.unicodeScalars.starts(with: composing.unicodeScalars),
           let fromBest = lookupIndex.lookup(bestWord),
           !fromBest.isEmpty {
            return Array(fromBest.prefix(maximumResults))
        }

        return []
    }

    /// Unique emoji count in the active index (for tests / diagnostics).
    static func uniqueEmojiCount(index: [String: [String]]? = nil) -> Int {
        let table = index ?? Self.index
        return Set(table.values.flatMap { $0 }).count
    }
}

/// Sort by raw Unicode scalars to preserve the old prefix-matching semantics.
struct SinhalaEmojiPrefixIndex {
    private struct Entry { let token: String; let scalars: [UInt32]; let values: [String] }
    private let exact: [String: [String]]
    private let entries: [Entry]
    init(index: [String: [String]]) {
        exact = index
        entries = index.filter { !$0.value.isEmpty }.map { token, values in
            Entry(token: token, scalars: token.unicodeScalars.map(\.value), values: values)
        }.sorted { $0.scalars.lexicographicallyPrecedes($1.scalars) }
    }
    func lookup(_ query: String) -> [String]? {
        if let hit = exact[query], !hit.isEmpty { return hit }
        let prefix = query.unicodeScalars.map(\.value)
        guard prefix.count >= 2 else { return nil }
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].scalars.lexicographicallyPrecedes(prefix) { low = middle + 1 }
            else { high = middle }
        }
        var best: Entry?
        for entry in entries[low...] {
            guard entry.scalars.starts(with: prefix) else { break }
            if best == nil || entry.scalars.count < best!.scalars.count
                || (entry.scalars.count == best!.scalars.count && entry.token < best!.token) { best = entry }
        }
        return best?.values
    }
}
