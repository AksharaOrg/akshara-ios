import Foundation
import SQLite3

enum KeyboardLanguage: String { case sinhala, english }

/// A bounded, transient editor snapshot. It is never persisted in the model.
struct EnglishWordContext: Equatable {
    let before: String
    let after: String
    let hasSelection: Bool
    let prefix: String
    let suffix: String
    let preceding: [String]

    init(before: String, after: String, hasSelection: Bool = false) {
        self.before = String(before.suffix(256))
        self.after = String(after.prefix(64))
        self.hasSelection = hasSelection
        prefix = String(self.before.reversed().prefix(while: Self.isWordCharacter).reversed())
        suffix = String(self.after.prefix(while: Self.isWordCharacter))
        let context = self.before.dropLast(prefix.count)
        // Only adjacent English words form English context; never bridge a
        // Sinhala word or sentence boundary to invent a continuation.
        let sentence = context.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? ""
        preceding = Array(sentence.split(whereSeparator: { $0.isWhitespace }).suffix(2))
            .map(String.init).reversed().prefix(while: EnglishPredictionProvider.isWord).reversed()
    }

    static func isWordCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "'" || char == "’" || char == "-" || char == "_"
    }

    var wholeWord: String { prefix + suffix }

    func replacementSpan(for replacement: String) -> (advance: Int, text: String) {
        let includesSpace = replacement.hasSuffix(" ") && after.dropFirst(suffix.count).first == " "
        return (suffix.count + (includesSpace ? 1 : 0), wholeWord + (includesSpace ? " " : ""))
    }

    /// Candidate taps may replace the token on both sides of the caret.
    var canReplaceWholeWord: Bool { !hasSelection }
    /// Boundary autocorrection remains stricter: the caret must be at the end
    /// so Space/Return never rewrites a fragment inside an existing word.
    var canAutocorrectAtBoundary: Bool { !hasSelection && suffix.isEmpty }
    var canReplace: Bool { canAutocorrectAtBoundary }
}

/// A query-only connection to the prebuilt index. Keeping words, deletion
/// keys, bigrams, and emoji in SQLite prevents the keyboard extension from
/// expanding a few compact resources into tens of megabytes of Swift objects.
private final class EnglishPredictionDatabase {
    private var handle: OpaquePointer?
    // Access is serialized by the provider lock. Bound the cache because
    // correction queries have different placeholder counts for word lengths.
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL?) {
        guard let url else { return nil }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            return nil
        }
        sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close(handle) }
    }

    func prepare() {
        // Touch the word index while the keyboard is idle so the first typed
        // prefix does not have to fault in the database's root pages.
        _ = rank(of: "the")
    }

    func completions(prefix: String, limit: Int) -> [(word: String, rank: Int)] {
        guard !prefix.isEmpty else { return [] }
        return rows(
            sql: "SELECT word, rank FROM words WHERE word >= ? AND word < ? ORDER BY rank LIMIT ?",
            bindings: [.text(prefix), .text(prefix + "{"), .int(limit)]
        ).compactMap { row in
            guard row.count == 2, let word = row[0].text, let rank = row[1].int else { return nil }
            return (word, rank)
        }
    }

    func followers(after previous: String, prefix: String, limit: Int) -> [(word: String, count: Int, rank: Int)] {
        let sql: String
        let bindings: [Binding]
        if prefix.isEmpty {
            sql = """
                SELECT b.next, b.count, COALESCE(w.rank, 100000)
                FROM bigrams b LEFT JOIN words w ON w.word = b.next
                WHERE b.previous = ? ORDER BY b.count DESC, COALESCE(w.rank, 100000), b.next LIMIT ?
                """
            bindings = [.text(previous), .int(limit)]
        } else {
            sql = """
                SELECT b.next, b.count, COALESCE(w.rank, 100000)
                FROM bigrams b LEFT JOIN words w ON w.word = b.next
                WHERE b.previous = ? AND b.next >= ? AND b.next < ?
                ORDER BY b.count DESC, COALESCE(w.rank, 100000), b.next LIMIT ?
                """
            bindings = [.text(previous), .text(prefix), .text(prefix + "{"), .int(limit)]
        }
        return rows(sql: sql, bindings: bindings).compactMap { row in
            guard row.count == 3, let word = row[0].text,
                  let count = row[1].int, let rank = row[2].int else { return nil }
            return (word, count, rank)
        }
    }

    func rank(of word: String) -> Int? {
        scalarInt(sql: "SELECT rank FROM words WHERE word = ?", bindings: [.text(word)])
    }

    func count(of word: String, after previous: String) -> Int {
        scalarInt(sql: "SELECT count FROM bigrams WHERE previous = ? AND next = ?",
                  bindings: [.text(previous), .text(word)]) ?? 0
    }

    func correctionCandidates(for word: String) -> [String] {
        let deleted = EnglishPredictionProvider.deletionKeys(word)
        let deletionLookups = [word] + deleted
        let deletionMarks = Array(repeating: "?", count: deletionLookups.count).joined(separator: ",")
        let wordMarks = Array(repeating: "?", count: deleted.count).joined(separator: ",")
        var sql = "SELECT word FROM deletions WHERE deletion IN (\(deletionMarks))"
        var bindings = deletionLookups.map(Binding.text)
        if !deleted.isEmpty {
            sql += " UNION SELECT word FROM words WHERE word IN (\(wordMarks))"
            bindings += deleted.map(Binding.text)
        }
        return rows(sql: sql, bindings: bindings).compactMap { $0.first?.text }
    }

    func emoji(for token: String) -> [String] {
        rows(
            sql: "SELECT emoji FROM emoji WHERE token = ? ORDER BY ordinal LIMIT 2",
            bindings: [.text(token)]
        ).compactMap { $0.first?.text }
    }

    private enum Binding {
        case text(String)
        case int(Int)
    }

    private enum Value {
        case text(String)
        case int(Int)

        var text: String? { if case let .text(value) = self { return value }; return nil }
        var int: Int? { if case let .int(value) = self { return value }; return nil }
    }

    private func scalarInt(sql: String, bindings: [Binding]) -> Int? {
        rows(sql: sql, bindings: bindings).first?.first?.int
    }

    private func rows(sql: String, bindings: [Binding]) -> [[Value]] {
        guard let handle else { return [] }
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK,
                  let prepared else { return [] }
            if statements.count >= 32, let key = statements.keys.first,
               let old = statements.removeValue(forKey: key) {
                sqlite3_finalize(old)
            }
            statements[sql] = prepared
            statement = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, index, value, -1, transient)
            case let .int(value):
                sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            }
        }
        var result: [[Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_INTEGER {
                    row.append(.int(Int(sqlite3_column_int64(statement, column))))
                } else if let text = sqlite3_column_text(statement, column) {
                    row.append(.text(String(cString: text)))
                }
            }
            result.append(row)
        }
        return result
    }
}

/// All model operations run on the prediction worker. The lock also permits
/// standalone tests and persistence callbacks without exposing mutable state.
final class EnglishPredictionProvider: SinhalaPredictionProviding {
    let identifier = "english-wordfreq-v1"
    private let lock = NSLock()
    private let database: EnglishPredictionDatabase?
    private let defaults: UserDefaults
    private var learned: [String: Int]
    private var learnedNext: [String: [String: Int]]
    private var cache: [SinhalaPredictionRequest: [SinhalaPredictionCandidate]] = [:]
    private var cacheOrder: [SinhalaPredictionRequest] = []
    private var persistence: DispatchWorkItem?
    private var hasUnsavedLearning = false
    private static let wordsKey = "prediction.english.words.v1"
    private static let nextKey = "prediction.english.followers.v1"

    init(databaseURL: URL? = Bundle.main.url(forResource: "EnglishPrediction", withExtension: "sqlite3"),
         defaults: UserDefaults = KeyboardPreferences.defaults) {
        database = EnglishPredictionDatabase(url: databaseURL)
        self.defaults = defaults
        learned = defaults.dictionary(forKey: Self.wordsKey) as? [String: Int] ?? [:]
        learnedNext = defaults.dictionary(forKey: Self.nextKey) as? [String: [String: Int]] ?? [:]
    }

    static func isWord(_ word: String) -> Bool {
        !word.isEmpty && word.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    static func cased(_ word: String, like source: String) -> String {
        if !source.isEmpty, source.count > 1, source == source.uppercased() { return word.uppercased() }
        if source.first?.isUppercase == true { return word.prefix(1).uppercased() + word.dropFirst() }
        return word == "i" ? "I" : word
    }

    func prepareIfNeeded() { lock.lock(); defer { lock.unlock() }; database?.prepare() }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        lock.lock(); defer { lock.unlock() }
        guard request.maximumResults > 0 else { return [] }
        if let cached = cache[request] { return cached }
        let prefix = request.composingText.lowercased()
        guard prefix.isEmpty || Self.isWord(prefix) else { return [] }
        let previous = request.precedingWords.last?.lowercased() ?? ""
        let localNext = learnedNext[previous] ?? [:]
        let bundled = database?.followers(after: previous, prefix: prefix, limit: 48) ?? []
        let bundledNext = Dictionary(uniqueKeysWithValues: bundled.map { ($0.word, $0.count) })
        var bundledRanks = Dictionary(uniqueKeysWithValues: bundled.map { ($0.word, $0.rank) })
        var pool = Set(localNext.keys).union(bundledNext.keys).union(learned.keys)
        if !prefix.isEmpty {
            for completion in database?.completions(prefix: prefix, limit: 48) ?? [] {
                pool.insert(completion.word)
                bundledRanks[completion.word] = completion.rank
            }
        } else {
            // No generic opener rail. Empty-prefix results require context.
            pool = Set(localNext.keys).union(bundledNext.keys)
        }
        var ranked: [SinhalaPredictionCandidate] = []
        for word in pool where word.hasPrefix(prefix) {
            let personalContext = Double(localNext[word, default: 0]) * 100_000_000.0
            // A learned word may rank above the SQL shortlist. Preserve its
            // corpus score even if it was outside the first 48 followers.
            let count = bundledNext[word] ?? database?.count(of: word, after: previous) ?? 0
            let corpusContext = Double(count) * 1_000.0
            let personalFrequency = Double(learned[word, default: 0]) * 100.0
            let rank = bundledRanks[word] ?? database?.rank(of: word) ?? 100_000
            let frequency = 1.0 / Double(rank + 1)
            ranked.append(.init(text: Self.cased(word, like: request.composingText),
                                score: personalContext + corpusContext + personalFrequency + frequency))
        }
        ranked.sort { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
        let result = Array(ranked.prefix(min(request.maximumResults, 24)))
        if cacheOrder.count == 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheOrder.append(request); cache[request] = result
        return result
    }

    func correction(for source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let word = source.lowercased()
        guard word.count >= 3, Self.isWord(word), database?.rank(of: word) == nil, learned[word] == nil,
              source == word || source == source.uppercased() || source == Self.cased(word, like: "A"),
              !KeyboardPreferences.isAutocorrectProtected(word) else { return nil }
        let pool = Set(database?.correctionCandidates(for: word) ?? [])
        // Never truncate the index before counting: that can make an ambiguous
        // typo appear to have a unique correction.
        let matches = pool.filter { Self.oneEdit(word, $0) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return Self.cased(match, like: source)
    }

    fileprivate static func deletionKeys(_ word: String) -> [String] {
        let chars = Array(word)
        return chars.indices.map { index in String(chars[..<index] + chars[(index + 1)...]) }
    }
    private static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if a.count >= b.count { i += 1 }; if b.count >= a.count { j += 1 }
        }
        return edits + a.count - i + b.count - j == 1
    }

    func emoji(for prefix: String, bestWord: String?) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard prefix.count >= 2 else { return [] }
        let exact = database?.emoji(for: prefix.lowercased()) ?? []
        if !exact.isEmpty { return exact }
        return database?.emoji(for: bestWord?.lowercased() ?? "") ?? []
    }

    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String]) -> [String: Double] {
        let prefix = latinBuffer.lowercased()
        guard !prefix.isEmpty else { return [:] }
        var weights: [String: Double] = [:]
        for (index, candidate) in ranked.enumerated() {
            let word = candidate.text.lowercased()
            guard word.hasPrefix(prefix), word.count > prefix.count else { continue }
            let key = String(word.dropFirst(prefix.count).prefix(1))
            weights[key] = max(weights[key, default: 0], 1 / Double(index + 1))
        }
        return weights
    }

    func recordSelection(_ word: String, after precedingWord: String?) { record(word, after: precedingWord, boost: 4) }
    func recordCommittedWord(_ word: String, after precedingWord: String?) { record(word, after: precedingWord, boost: 1) }
    private func record(_ source: String, after previous: String?, boost: Int) {
        lock.lock(); defer { lock.unlock() }
        let word = source.lowercased()
        guard Self.isWord(word) else { return }
        hasUnsavedLearning = true
        learned[word] = min(10000, learned[word, default: 0] + boost)
        if let previous = previous?.lowercased(), Self.isWord(previous) {
            learnedNext[previous, default: [:]][word] = min(10000, (learnedNext[previous]?[word] ?? 0) + boost)
            if let values = learnedNext[previous], values.count > 48 {
                learnedNext[previous] = Dictionary(uniqueKeysWithValues: values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(48).map { ($0.key, $0.value) })
            }
        }
        if learned.count > 512 {
            let keep = Set(learned.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(512).map(\.key))
            learned = learned.filter { keep.contains($0.key) }
        }
        if learnedNext.count > 512 {
            learnedNext = Dictionary(uniqueKeysWithValues: learnedNext.keys.sorted().prefix(512).map { ($0, learnedNext[$0]!) })
        }
        cache.removeAll(); cacheOrder.removeAll()
        persistence?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingPersistence() }
        persistence = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func flushPendingPersistence() {
        lock.lock(); defer { lock.unlock() }
        persistence?.cancel(); persistence = nil
        guard hasUnsavedLearning else { return }
        defaults.set(learned, forKey: Self.wordsKey); defaults.set(learnedNext, forKey: Self.nextKey)
        hasUnsavedLearning = false
    }
}
