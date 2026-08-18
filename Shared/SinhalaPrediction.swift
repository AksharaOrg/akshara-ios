import Foundation

/// A request is deliberately independent of UIKit so prediction providers can
/// be tested and replaced without changing the keyboard controller.
struct SinhalaPredictionRequest {
    let composingText: String
    let precedingWords: [String]
    let maximumResults: Int
}

struct SinhalaPredictionCandidate: Equatable {
    let text: String
    let score: Double
}

/// The seam for an offline trie model, an eventual Core ML model, or a model
/// supplied by a future dictionary package. Providers never receive touch
/// coordinates or communicate with a network.
protocol SinhalaPredictionProviding: AnyObject {
    var identifier: String { get }
    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate]
    func recordSelection(_ word: String, after precedingWord: String?)
    /// Called for words the keyboard itself commits, not text merely observed
    /// in the host field. This lets the personal model learn naturally while
    /// keeping the extension's privacy boundary intact.
    func recordCommittedWord(_ word: String, after precedingWord: String?)
    /// Letter-key inflation weights in 0...1, keyed by lowercase QWERTY
    /// identity (`a`...`z`). Empty composing buffer returns no weights: hit
    /// cells stay tiled until the user has started a word.
    func nextKeyWeights(
        latinBuffer: String,
        mode: SinhalaEngine.Mode,
        shifted: Bool,
        from ranked: [SinhalaPredictionCandidate],
        precedingWords: [String]
    ) -> [String: Double]
}

extension SinhalaPredictionProviding {
    func nextKeyWeights(
        latinBuffer: String,
        mode: SinhalaEngine.Mode,
        shifted: Bool,
        from ranked: [SinhalaPredictionCandidate],
        precedingWords: [String]
    ) -> [String: Double] {
        _ = (latinBuffer, mode, shifted, ranked, precedingWords)
        return [:]
    }
}

/// Provider registry modelled after ShanKeyboard's separation of dictionary,
/// n-gram and UI layers. A provider is selected by identifier, so replacing the
/// bundled model does not require changes to composition or candidate-bar code.
final class SinhalaPredictionProviderRegistry {
    static let shared = SinhalaPredictionProviderRegistry()

    private var providers: [String: SinhalaPredictionProviding] = [:]
    private var activeIdentifier: String

    private init() {
        let provider = SinhalaFrequencyListPredictionProvider()
        providers[provider.identifier] = provider
        activeIdentifier = KeyboardPreferences.selectedPredictionProvider()
        if providers[activeIdentifier] == nil { activeIdentifier = provider.identifier }
    }

    var activeProvider: SinhalaPredictionProviding {
        providers[activeIdentifier] ?? providers["uom-frequency-list-v1"]!
    }

    /// Register before the keyboard appears, then select this identifier in
    /// settings or with `activate`. Existing providers remain available.
    func register(_ provider: SinhalaPredictionProviding) {
        providers[provider.identifier] = provider
    }

    @discardableResult
    func activate(identifier: String) -> Bool {
        guard providers[identifier] != nil else { return false }
        activeIdentifier = identifier
        KeyboardPreferences.setSelectedPredictionProvider(identifier)
        return true
    }

    func flushPendingPersistence() {
        (activeProvider as? SinhalaFrequencyListPredictionProvider)?.flushPendingPersistence()
    }

    /// Prefetch the bundled dictionary off the main thread so the first
    /// keystroke does not pay the TSV parse cost.
    func prepareBundledModelsInBackground() {
        let provider = activeProvider as? SinhalaFrequencyListPredictionProvider
        DispatchQueue.global(qos: .utility).async {
            provider?.prepareBundledModelsIfNeeded()
        }
    }
}

/// A replaceable, offline unigram model compiled from the University of
/// Moratuwa Sinhala Word Frequency List, plus compact bundled bigram and
/// trigram tables. All three resources are simple UTF-8 TSV files so they can
/// be regenerated or replaced without changing keyboard UI code.
final class SinhalaFrequencyListPredictionProvider: SinhalaPredictionProviding {
    let identifier: String

    private struct Entry { let word: String; let frequency: Int }
    private struct NextWord { let word: String; let count: Int }
    private var entries: [Entry] = []
    private var frequentEntries: [Entry] = []
    private var sentenceStartEntries: [Entry] = []
    private var unigramFrequency: [String: Int] = [:]
    private var bundledBigrams: [String: [NextWord]] = [:]
    private var bundledTrigrams: [String: [NextWord]] = [:]
    private var didLoadBundledModels = false
    private let modelURL: URL?
    private let nextWordURL: URL?
    private let trigramURL: URL?
    private let sentenceStartURL: URL?
    private let defaults: UserDefaults
    private let learnedWordsKey = "prediction.learnedWords.v1"
    private let learnedBigramsKey = "prediction.learnedBigrams.v1"
    private let recencyKey = "prediction.recency.v1"
    private let maximumLearnedWords = 512
    private let maximumFollowersPerWord = 48
    /// Candidate ranking runs away from the keyboard's main UI thread. The
    /// learned model is small but mutable, so guard it when a selection and a
    /// background lookup happen at the same time.
    private let modelLock = NSLock()
    // UserDefaults is relatively expensive in an input extension. Keep the
    // small personal model in memory and write it only after an intentional
    // candidate selection.
    private var learnedWords: [String: Int]
    private var learnedBigrams: [String: [String: Int]]
    private var recency: [String: Int]
    private var recencyClock: Int
    private var persistenceWorkItem: DispatchWorkItem?

    init(
        identifier: String = "uom-frequency-list-v1",
        modelURL: URL? = Bundle.main.url(forResource: "SinhalaFrequencyModel", withExtension: "tsv"),
        nextWordURL: URL? = Bundle.main.url(forResource: "SinhalaNextWordModel", withExtension: "tsv"),
        trigramURL: URL? = Bundle.main.url(forResource: "SinhalaTrigramModel", withExtension: "tsv"),
        sentenceStartURL: URL? = Bundle.main.url(forResource: "SinhalaSentenceStartModel", withExtension: "tsv"),
        defaults: UserDefaults = KeyboardPreferences.defaults
    ) {
        self.identifier = identifier
        self.modelURL = modelURL
        self.nextWordURL = nextWordURL
        self.trigramURL = trigramURL
        self.sentenceStartURL = sentenceStartURL
        self.defaults = defaults
        // Keep construction cheap for keyboard cold start. Bundled TSV models
        // are loaded on the first prediction request (off the main thread).
        // Only the compact personal model is read up front.
        learnedWords = Self.intDictionary(from: defaults, forKey: learnedWordsKey)
        learnedBigrams = Self.nestedIntDictionary(from: defaults, forKey: learnedBigramsKey)
        recency = Self.intDictionary(from: defaults, forKey: recencyKey)
        recencyClock = recency.values.max() ?? 0
    }

    /// Loads the bundled frequency and bigram tables once. Safe to call from
    /// the prediction queue; no-ops after the first successful load.
    func prepareBundledModelsIfNeeded() {
        modelLock.lock()
        defer { modelLock.unlock() }
        loadBundledModelsLocked()
    }

    private func loadBundledModelsLocked() {
        guard !didLoadBundledModels else { return }
        didLoadBundledModels = true
        // The build script emits lexical order. Avoid sorting the bundled
        // model during the first prediction request in the keyboard process.
        let loadedEntries = Self.loadEntries(from: modelURL)
        entries = Self.isLexicallySorted(loadedEntries) ? loadedEntries : loadedEntries.sorted { $0.word < $1.word }
        // The empty-prefix rail needs only a small set of common words. Keep
        // that table bounded instead of allocating and sorting a second copy
        // of the full frequency model at keyboard startup.
        frequentEntries = Self.mostFrequentEntries(from: loadedEntries, maximum: 96)
        unigramFrequency = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.word, $0.frequency) })
        // The next-word TSV is ~18 MB / 450k lines. Materializing it as one
        // String plus a dictionary jetsams keyboard extensions on iOS 16
        // (≈40 MB limit, iPhone X). Unigram + trigram + sentence-start still
        // fill the rail. iOS 17+ devices get the contextual table.
        if Self.canLoadNextWordModel {
            bundledBigrams = Self.loadBigrams(from: nextWordURL)
        }
        bundledTrigrams = Self.loadTrigrams(from: trigramURL)
        sentenceStartEntries = Self.loadEntries(from: sentenceStartURL)
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        modelLock.lock()
        defer { modelLock.unlock() }
        loadBundledModelsLocked()
        let prefix = request.composingText
        let maximumResults = max(request.maximumResults, 0)
        guard maximumResults > 0 else { return [] }
        let previous = request.precedingWords.last
        let earlier = request.precedingWords.count >= 2
            ? request.precedingWords[request.precedingWords.count - 2]
            : nil
        let learnedNext = previous.flatMap { learnedBigrams[$0] } ?? [:]
        let bundledNext = previous.flatMap { bundledBigrams[$0] } ?? []
        let trigramNext: [NextWord]
        if let earlier, let previous {
            trigramNext = bundledTrigrams[Self.trigramKey(earlier, previous)] ?? []
        } else {
            trigramNext = []
        }
        var bundledCounts: [String: Int] = [:]
        for next in bundledNext {
            bundledCounts[next.word] = max(bundledCounts[next.word, default: 0], next.count)
        }
        var trigramCounts: [String: Int] = [:]
        for next in trigramNext {
            trigramCounts[next.word] = max(trigramCounts[next.word, default: 0], next.count)
        }
        let hasContinuations = previous != nil && (
            !bundledNext.isEmpty || !learnedNext.isEmpty || !trigramNext.isEmpty
        )

        // Keep only the requested winners while scanning. The old path built
        // and sorted up to 4,096 temporary candidates on every keypress.
        var ranked: [SinhalaPredictionCandidate] = []
        ranked.reserveCapacity(maximumResults)
        var considered = Set<String>()
        considered.reserveCapacity(maximumResults * 16)

        func consider(word: String, frequency: Int, unigramWeight: Double) {
            guard word != prefix else { return }
            // Next-word ranking should move forward. Repeating the word that
            // was just committed makes a suggestion chain look stuck.
            if prefix.isEmpty, word == previous { return }
            guard considered.insert(word).inserted else { return }
            let score = unigramWeight * log(Double(max(frequency, 1)) + 1)
                + Double(learnedWords[word, default: 0]) * 1.00
                + Double(learnedNext[word, default: 0]) * 1.80
                // Corpus context is a stronger next-word signal than global
                // word frequency, while local choices still adapt the result.
                + log(Double(bundledCounts[word, default: 0]) + 1) * 1.70
                + log(Double(trigramCounts[word, default: 0]) + 1) * 2.20
                + recencyScore(for: word)
            let candidate = SinhalaPredictionCandidate(text: word, score: score)
            let insertionIndex = ranked.firstIndex {
                candidate.score > $0.score
                    || (candidate.score == $0.score && candidate.text < $0.text)
            } ?? ranked.endIndex
            guard insertionIndex < maximumResults || ranked.count < maximumResults else { return }
            ranked.insert(candidate, at: insertionIndex)
            if ranked.count > maximumResults { ranked.removeLast() }
        }

        if prefix.isEmpty {
            if hasContinuations {
                // Contextual next-word should stay on actual followers. Mixing
                // in globally common words made the rail stall on ඇති / වන.
            } else if previous == nil {
                let starts = sentenceStartEntries.isEmpty
                    ? frequentEntries.prefix(max(maximumResults * 8, 24))
                    : ArraySlice(sentenceStartEntries.prefix(max(maximumResults * 8, 24)))
                for entry in starts {
                    consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
                }
            } else {
                for entry in frequentEntries.prefix(max(maximumResults * 8, 24)) {
                    consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
                }
            }
        } else {
            let firstMatch = firstIndex(atOrAfter: prefix)
            let upperBound = min(entries.count, firstMatch + 4_096)
            for index in firstMatch..<upperBound {
                let entry = entries[index]
                guard hasUnicodeScalarPrefix(entry.word, prefix) else { break }
                consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
            }
            // Personal words need not exist in the bundled corpus to be
            // returned as a completion.
            for (word, count) in learnedWords where hasUnicodeScalarPrefix(word, prefix) {
                consider(word: word, frequency: count, unigramWeight: 1.0)
            }
            // A single edit is enough to rescue the common near-miss without
            // turning the candidate rail into a spell-check UI. Restrict the
            // scan to the personal model, which is intentionally compact.
            if prefix.count >= 3 {
                for (word, count) in learnedWords where editDistanceAtMostOne(prefix, word) {
                    consider(word: word, frequency: count, unigramWeight: 1.0)
                }
            }
        }

        // Contextual selections can be custom words which are absent from the
        // corpus's initial frequency slice. Include them without a full sort.
        let continuationUnigramWeight: Double = prefix.isEmpty && hasContinuations ? 0.20 : 1.0
        for (word, count) in learnedNext where prefix.isEmpty || hasUnicodeScalarPrefix(word, prefix) {
            consider(
                word: word,
                frequency: unigramFrequency[word, default: learnedWords[word, default: count]],
                unigramWeight: continuationUnigramWeight
            )
        }
        for next in bundledNext where prefix.isEmpty || hasUnicodeScalarPrefix(next.word, prefix) {
            consider(
                word: next.word,
                frequency: unigramFrequency[next.word, default: 0],
                unigramWeight: continuationUnigramWeight
            )
        }
        for next in trigramNext where prefix.isEmpty || hasUnicodeScalarPrefix(next.word, prefix) {
            consider(
                word: next.word,
                frequency: unigramFrequency[next.word, default: 0],
                unigramWeight: continuationUnigramWeight
            )
        }
        return ranked
    }

    func nextKeyWeights(
        latinBuffer: String,
        mode: SinhalaEngine.Mode,
        shifted: Bool,
        from ranked: [SinhalaPredictionCandidate],
        precedingWords: [String]
    ) -> [String: Double] {
        guard mode != .sls, !latinBuffer.isEmpty, !ranked.isEmpty else { return [:] }
        var scores: [String: Double] = [:]
        let currentRendered = SinhalaEngine.transliterate(latinBuffer, mode: mode)
        var rewriteCache: [String: Double] = [:]
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let lower = String(UnicodeScalar(scalar)!)
            let source = shifted ? lower.uppercased() : lower
            let nextRendered = Self.strippingTrailingVirama(
                SinhalaEngine.transliterate(latinBuffer + source, mode: mode)
            )
            guard !nextRendered.isEmpty, nextRendered != currentRendered else { continue }
            var score = 0.0
            for candidate in ranked where SinhalaEngine.hasUnicodeScalarPrefix(candidate.text, nextRendered) {
                score += candidate.score
            }
            if score == 0 {
                if let cached = rewriteCache[nextRendered] {
                    score = cached
                } else {
                    let extra = candidates(for: SinhalaPredictionRequest(
                        composingText: nextRendered,
                        precedingWords: precedingWords,
                        maximumResults: 8
                    ))
                    score = extra.reduce(0) { $0 + $1.score }
                    rewriteCache[nextRendered] = score
                }
            }
            if score > 0 {
                scores[lower, default: 0] += score
            }
        }
        guard let maximum = scores.values.max(), maximum > 0 else { return [:] }
        return scores.mapValues { $0 / maximum }
    }

    func recordSelection(_ word: String, after precedingWord: String?) {
        modelLock.lock()
        defer { modelLock.unlock() }
        record(word, after: precedingWord, selectionBoost: 4, persistImmediately: true)
    }

    func recordCommittedWord(_ word: String, after precedingWord: String?) {
        modelLock.lock()
        defer { modelLock.unlock() }
        record(word, after: precedingWord, selectionBoost: 1, persistImmediately: false)
    }

    private func record(_ word: String, after precedingWord: String?, selectionBoost: Int, persistImmediately: Bool) {
        guard isSinhalaWord(word) else { return }
        learnedWords[word, default: 0] += selectionBoost
        recencyClock += 1
        recency[word] = recencyClock
        trimPersonalModel()
        if let precedingWord, isSinhalaWord(precedingWord) {
            var followers = learnedBigrams[precedingWord, default: [:]]
            followers[word, default: 0] += selectionBoost
            if followers.count > maximumFollowersPerWord {
                let weakest = followers.sorted {
                    $0.value == $1.value
                        ? (recency[$0.key, default: 0] < recency[$1.key, default: 0])
                        : $0.value < $1.value
                }.prefix(followers.count - maximumFollowersPerWord)
                weakest.forEach { followers.removeValue(forKey: $0.key) }
            }
            learnedBigrams[precedingWord] = followers
        }
        if persistImmediately { persistLocked() }
        else { schedulePersistence() }
    }

    func flushPendingPersistence() {
        modelLock.lock()
        defer { modelLock.unlock() }
        persistLocked()
    }

    private func persistLocked() {
        persistenceWorkItem?.cancel()
        persistenceWorkItem = nil
        defaults.set(learnedWords, forKey: learnedWordsKey)
        defaults.set(recency, forKey: recencyKey)
        defaults.set(learnedBigrams, forKey: learnedBigramsKey)
    }

    private func schedulePersistence() {
        persistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingPersistence() }
        persistenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func recencyScore(for word: String) -> Double {
        guard let lastUsed = recency[word], recencyClock > 0 else { return 0 }
        // Recent choices rise quickly, then decay smoothly as new words are
        // typed. The score is independent of wall-clock time and survives
        // relaunches, so it is deterministic and fully offline.
        return max(0, 2.2 - log(Double(max(1, recencyClock - lastUsed + 1))))
    }

    private func trimPersonalModel() {
        guard learnedWords.count > maximumLearnedWords else { return }
        let removals = learnedWords.sorted { lhs, rhs in
            let lhsScore = lhs.value * 100 + recency[lhs.key, default: 0]
            let rhsScore = rhs.value * 100 + recency[rhs.key, default: 0]
            return lhsScore == rhsScore ? lhs.key < rhs.key : lhsScore < rhsScore
        }.prefix(learnedWords.count - maximumLearnedWords)
        for (word, _) in removals {
            learnedWords.removeValue(forKey: word)
            recency.removeValue(forKey: word)
        }
        for preceding in learnedBigrams.keys {
            learnedBigrams[preceding] = learnedBigrams[preceding]?.filter { learnedWords[$0.key] != nil }
        }
    }

    private static func intDictionary(from defaults: UserDefaults, forKey key: String) -> [String: Int] {
        defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    private static func nestedIntDictionary(from defaults: UserDefaults, forKey key: String) -> [String: [String: Int]] {
        defaults.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
    }

    private func isSinhalaWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x0D80...0x0DFF).contains($0.value) }
    }

    private func firstIndex(atOrAfter prefix: String) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let midpoint = (low + high) / 2
            if entries[midpoint].word < prefix { low = midpoint + 1 } else { high = midpoint }
        }
        return low
    }

    /// Sinhala vowel signs and diacritics combine with the preceding base
    /// letter into one grapheme cluster. `String.hasPrefix` therefore fails
    /// for a typed base letter such as ක against a word beginning කං; compare
    /// Unicode scalars so prediction works from the first keystroke.
    private func hasUnicodeScalarPrefix(_ text: String, _ prefix: String) -> Bool {
        var textScalars = text.unicodeScalars.makeIterator()
        for scalar in prefix.unicodeScalars {
            guard textScalars.next() == scalar else { return false }
        }
        return true
    }

    private func editDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] { i += 1; j += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if left.count > right.count { i += 1 }
            else if right.count > left.count { j += 1 }
            else { i += 1; j += 1 }
        }
        return edits + (left.count - i) + (right.count - j) <= 1
    }

    private static func loadEntries(from modelURL: URL?) -> [Entry] {
        guard let contents = utf8Contents(of: modelURL) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let frequency = Int(fields[1]),
                  Self.isValidModelWord(fields[0]) else { return nil }
            return Entry(word: String(fields[0]), frequency: frequency)
        }
    }

    private static func strippingTrailingVirama(_ text: String) -> String {
        guard text.unicodeScalars.last?.value == 0x0DCA else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.dropLast()))
    }

    private static func trigramKey(_ earlier: String, _ previous: String) -> String {
        earlier + "\u{1E}" + previous
    }

    /// Keyboard extensions on iOS 16 are jetsam'd well below the size of
    /// `SinhalaNextWordModel.tsv`. Newer OS versions allow the extra table.
    private static var canLoadNextWordModel: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    private static func utf8Contents(of url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func loadTrigrams(from modelURL: URL?) -> [String: [NextWord]] {
        guard let contents = utf8Contents(of: modelURL) else { return [:] }
        var grouped: [String: [NextWord]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let count = Int(fields[3]),
                  Self.isValidModelWord(fields[0]),
                  Self.isValidModelWord(fields[1]),
                  Self.isValidModelWord(fields[2]) else { continue }
            let key = trigramKey(String(fields[0]), String(fields[1]))
            grouped[key, default: []].append(NextWord(word: String(fields[2]), count: count))
        }
        return grouped.mapValues { values in
            values.sorted { lhs, rhs in lhs.count == rhs.count ? lhs.word < rhs.word : lhs.count > rhs.count }
        }
    }

    private static func loadBigrams(from modelURL: URL?) -> [String: [NextWord]] {
        guard let contents = utf8Contents(of: modelURL) else { return [:] }
        var grouped: [String: [NextWord]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let count = Int(fields[2]),
                  Self.isValidModelWord(fields[0]), Self.isValidModelWord(fields[1]) else { continue }
            grouped[String(fields[0]), default: []].append(NextWord(word: String(fields[1]), count: count))
        }
        // Keep deterministic ordering even if a hand-edited replacement model
        // isn't already grouped by descending count.
        return grouped.mapValues { values in
            values.sorted { lhs, rhs in lhs.count == rhs.count ? lhs.word < rhs.word : lhs.count > rhs.count }
        }
    }

    private static func isLexicallySorted(_ values: [Entry]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0.word <= $1.word }
    }

    private static func isValidModelWord(_ value: Substring) -> Bool {
        let scalars = value.unicodeScalars
        return !scalars.isEmpty && scalars.count <= 24
            && scalars.allSatisfy { (0x0D80...0x0DFF).contains($0.value) }
    }

    private static func mostFrequentEntries(from values: [Entry], maximum: Int) -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(maximum)
        for entry in values {
            let index = result.firstIndex {
                entry.frequency > $0.frequency
                    || (entry.frequency == $0.frequency && entry.word < $0.word)
            } ?? result.endIndex
            guard index < maximum || result.count < maximum else { continue }
            result.insert(entry, at: index)
            if result.count > maximum { result.removeLast() }
        }
        return result
    }
}
