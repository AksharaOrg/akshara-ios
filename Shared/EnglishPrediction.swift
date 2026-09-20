import Foundation

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
    /// Candidate taps may replace the token on both sides of the caret.
    var canReplaceWholeWord: Bool { !hasSelection }
    /// Boundary autocorrection remains stricter: the caret must be at the end
    /// so Space/Return never rewrites a fragment inside an existing word.
    var canAutocorrectAtBoundary: Bool { !hasSelection && suffix.isEmpty }
    var canReplace: Bool { canAutocorrectAtBoundary }
}

/// All model operations run on the prediction worker. The lock also permits
/// standalone tests and persistence callbacks without exposing mutable state.
final class EnglishPredictionProvider: SinhalaPredictionProviding {
    let identifier = "english-wordfreq-v1"
    private let lock = NSLock()
    private let wordURL: URL?
    private let nextURL: URL?
    private let emojiURL: URL?
    private let defaults: UserDefaults
    private var loaded = false
    private var words: [String] = []
    private var ranks: [String: Int] = [:]
    private var deletions: [String: [String]] = [:]
    private var followers: [String: [String: Int]] = [:]
    private var emojiTokens: [String: [String]] = [:]
    private var learned: [String: Int]
    private var learnedNext: [String: [String: Int]]
    private var cache: [SinhalaPredictionRequest: [SinhalaPredictionCandidate]] = [:]
    private var cacheOrder: [SinhalaPredictionRequest] = []
    private var persistence: DispatchWorkItem?
    private static let wordsKey = "prediction.english.words.v1"
    private static let nextKey = "prediction.english.followers.v1"

    init(wordURL: URL? = Bundle.main.url(forResource: "english_wordfreq_25000", withExtension: "json"),
         nextURL: URL? = Bundle.main.url(forResource: "english_next_word_model", withExtension: "tsv"),
         emojiURL: URL? = Bundle.main.url(forResource: "EmojiSearchIndex", withExtension: "json"),
         defaults: UserDefaults = KeyboardPreferences.defaults) {
        self.wordURL = wordURL; self.nextURL = nextURL; self.emojiURL = emojiURL; self.defaults = defaults
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

    func prepareIfNeeded() { lock.lock(); defer { lock.unlock() }; load() }

    private func load() {
        guard !loaded else { return }; loaded = true
        if let wordURL, let data = try? Data(contentsOf: wordURL, options: .mappedIfSafe),
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] {
            for (rank, row) in rows.enumerated() {
                guard let word = (row.first as? String)?.lowercased(), Self.isWord(word), ranks[word] == nil else { continue }
                ranks[word] = rank
            }
        }
        words = ranks.keys.sorted()
        for word in words where word.count >= 2 {
            for key in Set(Self.deletionKeys(word)) { deletions[key, default: []].append(word) }
        }
        if let nextURL, let text = try? String(contentsOf: nextURL, encoding: .utf8) {
            for row in text.split(separator: "\n") {
                let fields = row.split(separator: "\t")
                guard fields.count == 3 else { continue }
                let previous = fields[0].lowercased(), next = fields[1].lowercased()
                guard Self.isWord(previous), Self.isWord(next), let count = Int(fields[2]) else { continue }
                followers[previous, default: [:]][next] = max(followers[previous]?[next] ?? 0, count)
            }
        }
        // Same conversational additions as Android.
        let conversation = ["hello": ["how": 50000, "there": 42000, "everyone": 16000],
                            "hi": ["how": 45000, "there": 38000], "how": ["are": 55000, "do": 40000],
                            "thank": ["you": 60000], "good": ["morning": 30000, "night": 30000, "afternoon": 18000]]
        if !words.isEmpty {
            for (previous, values) in conversation {
                for (next, count) in values where followers[previous]?[next] == nil {
                    followers[previous, default: [:]][next] = max(followers[previous]?[next] ?? 0, count)
                }
            }
        }
        if let emojiURL, let data = try? Data(contentsOf: emojiURL),
           let entries = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for emoji in entries.keys.sorted() {
                for phrase in entries[emoji] ?? [] where !phrase.hasPrefix("akshara-") {
                    for token in phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                        where token.count >= 2 && Self.isWord(token) {
                        if !emojiTokens[token, default: []].contains(emoji) { emojiTokens[token, default: []].append(emoji) }
                    }
                }
            }
        }
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        lock.lock(); defer { lock.unlock() }; load()
        guard request.maximumResults > 0 else { return [] }
        if let cached = cache[request] { return cached }
        let prefix = request.composingText.lowercased()
        guard prefix.isEmpty || Self.isWord(prefix) else { return [] }
        let previous = request.precedingWords.last?.lowercased() ?? ""
        let localNext = learnedNext[previous] ?? [:], bundledNext = followers[previous] ?? [:]
        var pool = Set(localNext.keys).union(bundledNext.keys).union(learned.keys)
        if !prefix.isEmpty {
            var low = 0, high = words.count
            while low < high { let mid = (low + high) / 2; if words[mid] < prefix { low = mid + 1 } else { high = mid } }
            var index = low
            while index < words.count && words[index].hasPrefix(prefix) { pool.insert(words[index]); index += 1 }
        } else {
            // No generic opener rail. Empty-prefix results require context.
            pool = Set(localNext.keys).union(bundledNext.keys)
        }
        var ranked: [SinhalaPredictionCandidate] = []
        for word in pool where word.hasPrefix(prefix) {
            let personalContext = Double(localNext[word, default: 0]) * 100_000_000.0
            let corpusContext = Double(bundledNext[word, default: 0]) * 1_000.0
            let personalFrequency = Double(learned[word, default: 0]) * 100.0
            let frequency = 1.0 / Double(ranks[word, default: 100_000] + 1)
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
        lock.lock(); defer { lock.unlock() }; load()
        let word = source.lowercased()
        guard word.count >= 3, Self.isWord(word), ranks[word] == nil, learned[word] == nil,
              source == word || source == source.uppercased() || source == Self.cased(word, like: "A"),
              !KeyboardPreferences.isAutocorrectProtected(word) else { return nil }
        var pool = Set(deletions[word] ?? [])
        for key in Self.deletionKeys(word) {
            pool.formUnion(deletions[key] ?? [])
            if ranks[key] != nil { pool.insert(key) }
        }
        // Never truncate the index before counting: that can make an ambiguous
        // typo appear to have a unique correction.
        let matches = pool.filter { Self.oneEdit(word, $0) }
        guard matches.count == 1, let match = matches.first else { return nil }
        return Self.cased(match, like: source)
    }

    private static func deletionKeys(_ word: String) -> [String] {
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
        lock.lock(); defer { lock.unlock() }; load()
        guard prefix.count >= 2 else { return [] }
        return Array((emojiTokens[prefix.lowercased()] ?? emojiTokens[bestWord?.lowercased() ?? ""] ?? []).prefix(2))
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
        defaults.set(learned, forKey: Self.wordsKey); defaults.set(learnedNext, forKey: Self.nextKey)
    }
}
