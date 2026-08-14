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
}

/// A replaceable, offline unigram model compiled from the University of
/// Moratuwa Sinhala Word Frequency List. The resource is deliberately a
/// simple UTF-8 TSV (`word<TAB>frequency`), so a larger model or a separately
/// trained n-gram model can replace it without changing keyboard UI code.
final class SinhalaFrequencyListPredictionProvider: SinhalaPredictionProviding {
    let identifier: String

    private struct Entry { let word: String; let frequency: Int }
    private let entries: [Entry]
    private let frequentEntries: [Entry]
    private let defaults = KeyboardPreferences.defaults
    private let learnedWordsKey = "prediction.learnedWords.v1"
    private let learnedBigramsKey = "prediction.learnedBigrams.v1"
    // UserDefaults is relatively expensive in an input extension. Keep the
    // small personal model in memory and write it only after an intentional
    // candidate selection.
    private var learnedWords: [String: Int]
    private var learnedBigrams: [String: [String: Int]]

    init(
        identifier: String = "uom-frequency-list-v1",
        modelURL: URL? = Bundle.main.url(forResource: "SinhalaFrequencyModel", withExtension: "tsv")
    ) {
        self.identifier = identifier
        let loadedEntries = Self.loadEntries(from: modelURL)
        entries = loadedEntries.sorted { $0.word < $1.word }
        frequentEntries = loadedEntries.sorted {
            $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency
        }
        learnedWords = Self.intDictionary(from: KeyboardPreferences.defaults, forKey: learnedWordsKey)
        learnedBigrams = Self.nestedIntDictionary(from: KeyboardPreferences.defaults, forKey: learnedBigramsKey)
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        let prefix = request.composingText
        let maximumResults = max(request.maximumResults, 0)
        guard maximumResults > 0 else { return [] }
        let previous = request.precedingWords.last
        let learnedNext = previous.flatMap { learnedBigrams[$0] } ?? [:]

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
        }

        // Contextual selections can be custom words which are absent from the
        // corpus's initial frequency slice. Include them without a full sort.
        for (word, count) in learnedNext where prefix.isEmpty || word.hasPrefix(prefix) {
            consider(word: word, frequency: learnedWords[word, default: count])
        }
        return ranked
    }

    func recordSelection(_ word: String, after precedingWord: String?) {
        guard isSinhalaWord(word) else { return }
        learnedWords[word, default: 0] += 1
        defaults.set(learnedWords, forKey: learnedWordsKey)
        guard let precedingWord, isSinhalaWord(precedingWord) else { return }
        var followers = learnedBigrams[precedingWord, default: [:]]
        followers[word, default: 0] += 1
        learnedBigrams[precedingWord] = followers
        defaults.set(learnedBigrams, forKey: learnedBigramsKey)
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
}
