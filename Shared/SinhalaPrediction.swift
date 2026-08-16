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
}

/// A replaceable, offline unigram model compiled from the University of
/// Moratuwa Sinhala Word Frequency List, plus a compact bundled bigram model.
/// Both resources are simple UTF-8 TSV files so they can be regenerated or
/// replaced without changing keyboard UI code.
final class SinhalaFrequencyListPredictionProvider: SinhalaPredictionProviding {
    let identifier: String

    private struct Entry { let word: String; let frequency: Int }
    private struct NextWord { let word: String; let count: Int }
    private let entries: [Entry]
    private let frequentEntries: [Entry]
    private let bundledBigrams: [String: [NextWord]]
    private let defaults = KeyboardPreferences.defaults
    private let learnedWordsKey = "prediction.learnedWords.v1"
    private let learnedBigramsKey = "prediction.learnedBigrams.v1"
    private let recencyKey = "prediction.recency.v1"
    private let maximumLearnedWords = 512
    private let maximumFollowersPerWord = 48
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
        nextWordURL: URL? = Bundle.main.url(forResource: "SinhalaNextWordModel", withExtension: "tsv")
    ) {
        self.identifier = identifier
        // The build script emits lexical order. Avoid sorting the bundled
        // model during the first prediction request in the keyboard process.
        let loadedEntries = Self.loadEntries(from: modelURL)
        entries = Self.isLexicallySorted(loadedEntries) ? loadedEntries : loadedEntries.sorted { $0.word < $1.word }
        // The empty-prefix rail needs only a small set of common words. Keep
        // that table bounded instead of allocating and sorting a second copy
        // of the full frequency model at keyboard startup.
        frequentEntries = Self.mostFrequentEntries(from: loadedEntries, maximum: 96)
        bundledBigrams = Self.loadBigrams(from: nextWordURL)
        learnedWords = Self.intDictionary(from: KeyboardPreferences.defaults, forKey: learnedWordsKey)
        learnedBigrams = Self.nestedIntDictionary(from: KeyboardPreferences.defaults, forKey: learnedBigramsKey)
        recency = Self.intDictionary(from: KeyboardPreferences.defaults, forKey: recencyKey)
        recencyClock = recency.values.max() ?? 0
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        let prefix = request.composingText
        let maximumResults = max(request.maximumResults, 0)
        guard maximumResults > 0 else { return [] }
        let previous = request.precedingWords.last
        let learnedNext = previous.flatMap { learnedBigrams[$0] } ?? [:]
        let bundledNext = previous.flatMap { bundledBigrams[$0] } ?? []
        var bundledCounts: [String: Int] = [:]
        for next in bundledNext {
            bundledCounts[next.word] = max(bundledCounts[next.word, default: 0], next.count)
        }

        // Keep only the requested winners while scanning. The old path built
        // and sorted up to 4,096 temporary candidates on every keypress.
        var ranked: [SinhalaPredictionCandidate] = []
        ranked.reserveCapacity(maximumResults)
        var considered = Set<String>()
        considered.reserveCapacity(maximumResults * 16)

        func consider(word: String, frequency: Int) {
            guard word != prefix, considered.insert(word).inserted else { return }
            let score = log(Double(max(frequency, 1)) + 1)
                + Double(learnedWords[word, default: 0]) * 0.60
                + Double(learnedNext[word, default: 0]) * 1.20
                // Corpus context is a stronger next-word signal than global
                // word frequency, while local choices still adapt the result.
                + log(Double(bundledCounts[word, default: 0]) + 1) * 1.70
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
            // This list is already frequency ordered, so a compact slice is
            // enough to establish useful next-word defaults.
            for entry in frequentEntries.prefix(max(maximumResults * 8, 24)) {
                consider(word: entry.word, frequency: entry.frequency)
            }
        } else {
            let firstMatch = firstIndex(atOrAfter: prefix)
            let upperBound = min(entries.count, firstMatch + 4_096)
            for index in firstMatch..<upperBound {
                let entry = entries[index]
                guard entry.word.hasPrefix(prefix) else { break }
                consider(word: entry.word, frequency: entry.frequency)
            }
            // Personal words need not exist in the bundled corpus to be
            // returned as a completion.
            for (word, count) in learnedWords where word.hasPrefix(prefix) {
                consider(word: word, frequency: count)
            }
            // A single edit is enough to rescue the common near-miss without
            // turning the candidate rail into a spell-check UI. Restrict the
            // scan to the personal model, which is intentionally compact.
            if prefix.count >= 3 {
                for (word, count) in learnedWords where editDistanceAtMostOne(prefix, word) {
                    consider(word: word, frequency: count)
                }
            }
        }

        // Contextual selections can be custom words which are absent from the
        // corpus's initial frequency slice. Include them without a full sort.
        for (word, count) in learnedNext where prefix.isEmpty || word.hasPrefix(prefix) {
            consider(word: word, frequency: learnedWords[word, default: count])
        }
        // A corpus continuation can be missing from the compact unigram
        // slice. Include it explicitly so context is useful from the first
        // word, before personal learning has accumulated.
        for next in bundledNext where prefix.isEmpty || next.word.hasPrefix(prefix) {
            consider(word: next.word, frequency: 0)
        }
        return ranked
    }

    func recordSelection(_ word: String, after precedingWord: String?) {
        record(word, after: precedingWord, selectionBoost: 2, persistImmediately: true)
    }

    func recordCommittedWord(_ word: String, after precedingWord: String?) {
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
        if persistImmediately { flushPendingPersistence() }
        else { schedulePersistence() }
    }

    func flushPendingPersistence() {
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
        guard let modelURL,
              let contents = try? String(contentsOf: modelURL, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let frequency = Int(fields[1]),
                  !fields[0].isEmpty else { return nil }
            return Entry(word: String(fields[0]), frequency: frequency)
        }
    }

    private static func loadBigrams(from modelURL: URL?) -> [String: [NextWord]] {
        guard let modelURL,
              let contents = try? String(contentsOf: modelURL, encoding: .utf8) else { return [:] }
        var grouped: [String: [NextWord]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let count = Int(fields[2]), !fields[0].isEmpty, !fields[1].isEmpty else { continue }
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
