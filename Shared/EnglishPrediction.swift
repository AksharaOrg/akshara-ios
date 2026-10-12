import Foundation
import SQLite3
#if canImport(UIKit)
import UIKit
#endif

/// Frequency is useful for ranking, but corpus words (including "teh") are
/// not a spelling authority. The extension uses the public UK system checker.
protocol EnglishSpellingChecking {
    func isCorrect(_ word: String) -> Bool
    func guesses(for word: String) -> [String]
    func completions(for prefix: String) -> [String]
}

enum EnglishSpelling {
    static func systemBritishChecker() -> EnglishSpellingChecking? {
        #if canImport(UIKit)
        return UITextChecker.availableLanguages.contains("en_GB") ? BritishEnglishSpellingChecker() : nil
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
private final class BritishEnglishSpellingChecker: EnglishSpellingChecking {
    private let checker = UITextChecker()
    private var valid: [String: Bool] = [:]
    private var corrections: [String: [String]] = [:]
    // Access is serialized by EnglishPredictionProvider's lock.
    func isCorrect(_ word: String) -> Bool {
        if let cached = valid[word] { return cached }
        let range = NSRange(location: 0, length: word.utf16.count)
        let result = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0,
            wrap: false, language: "en_GB").location == NSNotFound
        if valid.count >= 128 { valid.removeAll(keepingCapacity: true) }
        valid[word] = result
        return result
    }
    func guesses(for word: String) -> [String] {
        if let cached = corrections[word] { return cached }
        let result = Array((checker.guesses(forWordRange: NSRange(location: 0, length: word.utf16.count),
            in: word, language: "en_GB") ?? []).prefix(8))
        if corrections.count >= 64 { corrections.removeAll(keepingCapacity: true) }
        corrections[word] = result
        return result
    }
    func completions(for prefix: String) -> [String] {
        Array((checker.completions(forPartialWordRange: NSRange(location: 0, length: prefix.utf16.count),
            in: prefix, language: "en_GB") ?? []).prefix(24))
    }
}
#endif

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
    private let spellingChecker: EnglishSpellingChecking?
    private let defaults: UserDefaults
    private var learned: [String: Int]
    private var learnedNext: [String: [String: Int]]
    private var cache: [SinhalaPredictionRequest: [SinhalaPredictionCandidate]] = [:]
    private var cacheOrder: [SinhalaPredictionRequest] = []
    private var persistence: DispatchWorkItem?
    private var hasUnsavedLearning = false
    private var learningRevision = 0
    private var persistedRevision = -1
    private let persistenceQueue = DispatchQueue(label: "lk.org.akshara.english.persistence", qos: .utility)
    private var learningGeneration: String?
    private static let wordsKey = "prediction.english.words.v1"
    private static let nextKey = "prediction.english.followers.v1"

    init(databaseURL: URL? = Bundle.main.url(forResource: "EnglishPrediction", withExtension: "sqlite3"),
         defaults: UserDefaults = KeyboardPreferences.defaults,
         spellingChecker: EnglishSpellingChecking? = EnglishSpelling.systemBritishChecker()) {
        database = EnglishPredictionDatabase(url: databaseURL)
        self.spellingChecker = spellingChecker
        self.defaults = defaults
        learningGeneration = defaults.string(forKey: KeyboardPreferences.learningResetKey)
        learned = defaults.dictionary(forKey: Self.wordsKey) as? [String: Int] ?? [:]
        learnedNext = defaults.dictionary(forKey: Self.nextKey) as? [String: [String: Int]] ?? [:]
    }

    static func isWord(_ word: String) -> Bool {
        guard let first = word.first, let last = word.last, first.isLetter, last.isLetter else { return false }
        return word.unicodeScalars.allSatisfy {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) ||
            (0xC0...0x24F).contains($0.value) && $0.properties.isAlphabetic ||
            (0x300...0x36F).contains($0.value) || $0 == "'" || $0 == "’"
        } && !word.contains("''") && !word.contains("’’")
    }

    private static func lookupWord(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'").precomposedStringWithCanonicalMapping
    }

    static func cased(_ word: String, like source: String) -> String {
        if !source.isEmpty, source.count > 1, source == source.uppercased() { return word.uppercased() }
        if source.first?.isUppercase == true { return word.prefix(1).uppercased() + word.dropFirst() }
        return word == "i" || word.hasPrefix("i'") ? "I" + word.dropFirst() : word
    }

    func prepareIfNeeded() {
        let interval = KeyboardPerformance.begin("EnglishModelPreparation")
        defer { KeyboardPerformance.end(interval) }
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked(); database?.prepare()
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        candidates(for: request, cancellation: nil)
    }
    func candidates(for request: SinhalaPredictionRequest, cancellation: PredictionCancellationToken?) -> [SinhalaPredictionCandidate] {
        let interval = KeyboardPerformance.begin("EnglishRanking")
        defer { KeyboardPerformance.end(interval) }
        guard cancellation?.isCancelled != true else { return [] }
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked()
        guard request.maximumResults > 0 else { return [] }
        if let cached = cache[request] { return cached }
        let prefix = Self.lookupWord(request.composingText)
        guard prefix.isEmpty || Self.isWord(prefix) else { return [] }
        let previous = request.precedingWords.last.map(Self.lookupWord) ?? ""
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
            for word in spellingChecker?.completions(for: prefix) ?? [] {
                let word = Self.lookupWord(word)
                if Self.isWord(word) { pool.insert(word) }
            }
        } else {
            // No generic opener rail. Empty-prefix results require context.
            pool = Set(localNext.keys).union(bundledNext.keys)
        }
        var ranked: [SinhalaPredictionCandidate] = []
        for word in pool {
            guard cancellation?.isCancelled != true else { return [] }
            guard word.hasPrefix(prefix) else { continue }
            // Explicitly learned names remain available. Ordinary corpus
            // mistakes must not appear as recommended UK spellings.
            if learned[word] == nil, spellingChecker?.isCorrect(word) == false { continue }
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
        guard cancellation?.isCancelled != true else { return [] }
        if cacheOrder.count == 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheOrder.append(request); cache[request] = result
        return result
    }

    func correction(for source: String) -> String? {
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked()
        let word = Self.lookupWord(source)
        guard Self.isWord(word),
              source == source.lowercased() || source == source.uppercased() || source == Self.cased(source.lowercased(), like: "A"),
              !KeyboardPreferences.isAutocorrectProtected(word) else { return nil }
        if word == "i" { return source == "i" ? "I" : nil }
        if let spellingChecker {
            guard word.count >= 2, !spellingChecker.isCorrect(source) else { return nil }
            // Native ordering supplies the preferred UK guess, but only a
            // nearby spelling can replace automatically. Names, distant
            // guesses and multiword replacements stay literal.
            guard let guess = spellingChecker.guesses(for: source).first else { return nil }
            let match = Self.lookupWord(guess)
            guard Self.isWord(match), Self.oneEdit(word, match) || Self.adjacentSwap(word, match),
                  spellingChecker.isCorrect(guess) else { return nil }
            return Self.cased(match, like: source)
        }
        guard word.count >= 3, database?.rank(of: word) == nil, learned[word] == nil else { return nil }
        let pool = Set(database?.correctionCandidates(for: word) ?? [])
        // Never truncate the index before counting: that can make an ambiguous
        // typo appear to have a unique correction.
        let matches = pool.filter { Self.oneEdit(word, $0) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return Self.cased(match, like: source)
    }

    /// The corpus fallback offers swaps for explicit selection. On iOS,
    /// automatic swaps require the British system checker's preferred guess.
    func transpositionSuggestions(for source: String, maximumResults: Int = 3,
                                  cancellation: PredictionCancellationToken? = nil) -> [String] {
        guard maximumResults > 0, cancellation?.isCancelled != true else { return [] }
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked()
        let word = source.lowercased()
        if spellingChecker?.isCorrect(source) == true { return [] }
        guard word.count >= 3, Self.isWord(word), database?.rank(of: word) == nil, learned[word] == nil,
              source == word || source == source.uppercased() || source == Self.cased(word, like: "A"),
              !KeyboardPreferences.isAutocorrectProtected(word) else { return [] }
        let chars = Array(word)
        var matches: [String: Int] = [:]
        for index in 0..<(chars.count - 1) where chars[index] != chars[index + 1] {
            guard cancellation?.isCancelled != true else { return [] }
            var swapped = chars
            swapped.swapAt(index, index + 1)
            let candidate = String(swapped)
            if let rank = database?.rank(of: candidate), spellingChecker?.isCorrect(candidate) != false { matches[candidate] = rank }
        }
        guard cancellation?.isCancelled != true else { return [] }
        return matches.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            .prefix(maximumResults).map { Self.cased($0.key, like: source) }
    }

    fileprivate static func deletionKeys(_ word: String) -> [String] {
        let chars = Array(word)
        return chars.indices.map { index in String(chars[..<index] + chars[(index + 1)...]) }
    }
    private static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if a.count >= b.count { i += 1 }; if b.count >= a.count { j += 1 }
        }
        return edits + a.count - i + b.count - j == 1
    }

    private static func adjacentSwap(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard a.count == b.count else { return false }
        let differences = a.indices.filter { a[$0] != b[$0] }
        guard differences.count == 2, differences[1] == differences[0] + 1 else { return false }
        return a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]]
    }

    func emoji(for prefix: String, bestWord: String?) -> [String] {
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked()
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
        lock.lock(); defer { lock.unlock() }; synchronizeLearningResetLocked()
        let word = Self.lookupWord(source)
        guard Self.isWord(word) else { return }
        if boost == 1, spellingChecker?.isCorrect(source) == false { return }
        hasUnsavedLearning = true
        learningRevision += 1
        learned[word] = min(10000, learned[word, default: 0] + boost)
        if let previous = previous.map(Self.lookupWord), Self.isWord(previous) {
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
    private func synchronizeLearningResetLocked() {
        let generation = defaults.string(forKey: KeyboardPreferences.learningResetKey)
        guard generation != learningGeneration else { return }
        learningGeneration = generation
        learningRevision += 1
        persistedRevision = -1
        persistence?.cancel()
        persistence = nil
        learned.removeAll()
        learnedNext.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        hasUnsavedLearning = false
    }

    func flushPendingPersistence() {
        lock.lock()
        synchronizeLearningResetLocked()
        persistence?.cancel(); persistence = nil
        guard hasUnsavedLearning else { lock.unlock(); return }
        let words = learned, followers = learnedNext
        let generation = learningGeneration, revision = learningRevision
        lock.unlock()
        _ = persistenceQueue.sync {
            KeyboardPerformance.measure("EnglishPersistence") {
                KeyboardPreferences.withLearningPersistenceLock {
                    defaults.synchronize()
                    guard defaults.string(forKey: KeyboardPreferences.learningResetKey) == generation else { return }
                    lock.lock(); let superseded = revision <= persistedRevision; lock.unlock()
                    guard !superseded else { return }
                    defaults.set(words, forKey: Self.wordsKey)
                    defaults.set(followers, forKey: Self.nextKey)
                    defaults.synchronize()
                    lock.lock()
                    if learningGeneration == generation {
                        persistedRevision = revision
                        if learningRevision == revision { hasUnsavedLearning = false }
                    }
                    lock.unlock()
                }
            }
        }
    }

}
