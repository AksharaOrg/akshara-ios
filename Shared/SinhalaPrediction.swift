import Foundation

/// Cancellation crosses queues and is checked during scans as well as between stages.
final class PredictionCancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    private let onCheck: (() -> Void)?

    /// Optional checkpoint supports deterministic concurrent-cancellation tests.
    init(onCheck: (() -> Void)? = nil) { self.onCheck = onCheck }

    var isCancelled: Bool {
        onCheck?()
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A request is deliberately independent of UIKit so prediction providers can
/// be tested and replaced without changing the keyboard controller.
struct SinhalaPredictionRequest: Hashable {
    let composingText: String
    let precedingWords: [String]
    let maximumResults: Int
    var phoneticSource: String? = nil
    var phoneticConfiguration: SmartPhoneticConfiguration = .classic
    var exactPhoneticOnly = false

    /// An empty composing word still has input after a committed word.
    /// Empty fields have neither and should not display sentence openers.
    var hasInputContext: Bool { !composingText.isEmpty || !precedingWords.isEmpty }
}

struct SinhalaPredictionCandidate: Equatable {
    let text: String
    let score: Double
}

/// While a word is being composed, continuing its spelling takes precedence
/// over changing letters already typed. Corrections remain available afterwards.
enum SinhalaCandidateRanking {
    static func words(composingText: String, ranked: [String], corrections: [String], maximumResults: Int = 3) -> [String] {
        guard maximumResults > 0 else { return [] }
        guard !composingText.isEmpty else { return Array(ranked.prefix(maximumResults)) }
        func continues(_ word: String) -> Bool {
            SinhalaEngine.hasUnicodeScalarPrefix(word, composingText)
        }
        let ordered = ranked.filter(continues) + corrections.filter(continues)
            + corrections.filter { !continues($0) } + ranked.filter { !continues($0) }
        var seen = Set<String>()
        var result: [String] = []
        for word in ordered where !word.isEmpty && seen.insert(word).inserted {
            result.append(word)
            if result.count == maximumResults { break }
        }
        return result
    }
}

/// The seam for an offline trie model, an eventual Core ML model, or a model
/// supplied by a future dictionary package. Providers never receive touch
/// coordinates or communicate with a network.
protocol SinhalaPredictionProviding: AnyObject {
    var identifier: String { get }
    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate]
    func candidates(for request: SinhalaPredictionRequest, cancellation: PredictionCancellationToken?) -> [SinhalaPredictionCandidate]
    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        cancellation: PredictionCancellationToken?) -> [String: Double]
    func recordSelection(_ word: String, after precedingWord: String?)
    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        configuration: SmartPhoneticConfiguration,
                        cancellation: PredictionCancellationToken?) -> [String: Double]
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
    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        configuration: SmartPhoneticConfiguration,
                        cancellation: PredictionCancellationToken?) -> [String: Double] {
        nextKeyWeights(latinBuffer: latinBuffer, mode: mode, shifted: shifted,
                       from: ranked, precedingWords: precedingWords, cancellation: cancellation)
    }
    func candidates(for request: SinhalaPredictionRequest, cancellation: PredictionCancellationToken?) -> [SinhalaPredictionCandidate] {
        guard cancellation?.isCancelled != true else { return [] }
        let result = candidates(for: request)
        return cancellation?.isCancelled == true ? [] : result
    }
    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        cancellation: PredictionCancellationToken?) -> [String: Double] {
        guard cancellation?.isCancelled != true else { return [:] }
        let result = nextKeyWeights(latinBuffer: latinBuffer, mode: mode, shifted: shifted, from: ranked, precedingWords: precedingWords)
        return cancellation?.isCancelled == true ? [:] : result
    }

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
        let provider = activeProvider as? SinhalaFrequencyListPredictionProvider
        DispatchQueue.global(qos: .utility).async {
            provider?.flushPendingPersistence()
        }
    }

    /// Prefetch the bundled dictionary off the main thread so the first
    /// keystroke does not pay the TSV parse cost.
    func prepareBundledModelsInBackground(phonetic: Bool = false) {
        let provider = activeProvider as? SinhalaFrequencyListPredictionProvider
        DispatchQueue.global(qos: .utility).async {
            provider?.prepareBundledModelsIfNeeded(phonetic: phonetic)
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
    /// Keeps the 18 MB next-word corpus memory-mapped and indexes only the
    /// byte ranges for its ~30k preceding words. Expanding all 455k rows into
    /// Swift strings and dictionaries uses many times the file size.
    private struct MappedBigramTable {
        let data: Data
        let ranges: [String: Range<Int>]
        let usesPrebuiltIndex: Bool
        private var cache: [String: [NextWord]] = [:]
        private var cacheOrder: [String] = []

        init?(url: URL?) {
            guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }
            let indexURL = url.deletingPathExtension().appendingPathExtension("offsets")
            if let indexed = Self.loadRanges(url: indexURL, source: data) {
                self.data = data; ranges = indexed; usesPrebuiltIndex = true
                return
            }
            var ranges: [String: Range<Int>] = [:]
            ranges.reserveCapacity(32_000)
            var currentKey: String?
            var currentKeyBytes: [UInt8] = []
            var groupStart = 0
            var lineStart = 0
            var firstTab: Int?

            data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                func finishLine(at lineEnd: Int) {
                    defer {
                        lineStart = lineEnd + 1
                        firstTab = nil
                    }
                    guard let tab = firstTab, tab > lineStart else { return }
                    let keyBytes = bytes[lineStart..<tab]
                    let sameKey = keyBytes.count == currentKeyBytes.count
                        && keyBytes.elementsEqual(currentKeyBytes)
                    guard !sameKey else { return }
                    if let currentKey {
                        ranges[currentKey] = groupStart..<lineStart
                    }
                    currentKeyBytes = Array(keyBytes)
                    currentKey = String(decoding: currentKeyBytes, as: UTF8.self)
                    groupStart = lineStart
                }

                for index in bytes.indices {
                    switch bytes[index] {
                    case 0x09 where firstTab == nil: firstTab = index
                    case 0x0A: finishLine(at: index)
                    default: break
                    }
                }
                if lineStart < bytes.count {
                    finishLine(at: bytes.count)
                }
                if let currentKey {
                    ranges[currentKey] = groupStart..<bytes.count
                }
            }
            self.data = data
            self.ranges = ranges
            usesPrebuiltIndex = false
        }

        private static func loadRanges(url: URL, source: Data) -> [String: Range<Int>]? {
            guard var reader = PredictionIndexReader(url: url, magic: "AKSHARA_BIGRAM_INDEX_V1\0", source: source),
                  let count = reader.uint32(), count <= source.count / 3 else { return nil }
            var ranges: [String: Range<Int>] = [:]
            ranges.reserveCapacity(count)
            var previousEnd = 0
            for _ in 0..<count {
                guard let key = reader.string(), !key.isEmpty, ranges[key] == nil,
                      let start = reader.uint32(), let end = reader.uint32(),
                      start >= previousEnd, start < end, end <= source.count,
                      start == 0 || source[start - 1] == 10,
                      end == source.count || source[end - 1] == 10,
                      source[start..<end].starts(with: Array((key + "\t").utf8)) else { return nil }
                ranges[key] = start..<end; previousEnd = end
            }
            return reader.isAtEnd ? ranges : nil
        }

        mutating func followers(for precedingWord: String, cancellation: PredictionCancellationToken?) -> [NextWord] {
            guard cancellation?.isCancelled != true else { return [] }
            if let cached = cache[precedingWord] { return cached }
            guard let range = ranges[precedingWord] else { return [] }
            var result: [NextWord] = []
            for (offset, line) in String(decoding: data[range], as: UTF8.self).split(whereSeparator: \.isNewline).enumerated() {
                if offset & 63 == 0, cancellation?.isCancelled == true { return [] }
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let count = Int(fields[2]) else { continue }
                result.append(NextWord(word: String(fields[1]), count: count))
            }
            guard cancellation?.isCancelled != true else { return [] }
            if cacheOrder.count == 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            cacheOrder.append(precedingWord); cache[precedingWord] = result
            return result
        }
    }
    private var entries: [Entry] = []
    private var frequentEntries: [Entry] = []
    private var sentenceStartEntries: [Entry] = []
    private var unigramFrequency: [String: Int] = [:]
    private var bundledBigrams: MappedBigramTable?
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
    private var soundLexicon: SinhalaSoundLexicon?
    // UserDefaults is relatively expensive in an input extension. Keep the
    // small personal model in memory and write it only after an intentional
    // candidate selection.
    private var learnedWords: [String: Int]
    private var learnedBigrams: [String: [String: Int]]
    private var recency: [String: Int]
    private var recencyClock: Int
    private var persistenceWorkItem: DispatchWorkItem?
    private var hasUnsavedLearning = false
    private var learningRevision = 0
    private var persistedRevision = -1
    private let persistenceQueue = DispatchQueue(label: "lk.org.akshara.sinhala.persistence", qos: .utility)
    private var learningGeneration: String?
    // Backspace/retyping often revisits the same prefix and context. Bound the
    // cache so the keyboard extension cannot retain an entire typing session.
    private var candidateCache: [SinhalaPredictionRequest: [SinhalaPredictionCandidate]] = [:]
    private var cachedRequests: [SinhalaPredictionRequest] = []

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
        learningGeneration = defaults.string(forKey: KeyboardPreferences.learningResetKey)
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
    func prepareBundledModelsIfNeeded(phonetic: Bool = false) {
        modelLock.lock()
        defer { modelLock.unlock() }
        synchronizeLearningResetLocked()
        loadBundledModelsLocked()
        if phonetic { prepareSoundLexiconLocked() }
    }

    private func prepareSoundLexiconLocked() {
        guard soundLexicon == nil else { return }
        soundLexicon = SinhalaSoundLexicon(rows: entries.map { ($0.word, $0.frequency) })
    }

    private func loadBundledModelsLocked() {
        guard !didLoadBundledModels else { return }
        let interval = KeyboardPerformance.begin("SinhalaModelPreparation")
        defer { KeyboardPerformance.end(interval) }
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
        bundledBigrams = MappedBigramTable(url: nextWordURL)
        bundledTrigrams = Self.loadTrigrams(from: trigramURL)
        sentenceStartEntries = Self.loadEntries(from: sentenceStartURL)
    }

    var usesPrebuiltBigramIndex: Bool {
        modelLock.lock(); defer { modelLock.unlock() }
        return bundledBigrams?.usesPrebuiltIndex == true
    }

    func candidates(for request: SinhalaPredictionRequest) -> [SinhalaPredictionCandidate] {
        candidates(for: request, cancellation: nil)
    }
    func candidates(for request: SinhalaPredictionRequest, cancellation: PredictionCancellationToken?) -> [SinhalaPredictionCandidate] {
        let interval = KeyboardPerformance.begin("SinhalaRanking")
        defer { KeyboardPerformance.end(interval) }
        guard cancellation?.isCancelled != true else { return [] }
        modelLock.lock()
        defer { modelLock.unlock() }
        synchronizeLearningResetLocked()
        loadBundledModelsLocked()
        guard cancellation?.isCancelled != true else { return [] }
        if request.phoneticSource != nil, request.phoneticConfiguration.enabled { prepareSoundLexiconLocked() }
        var processed = 0
        func shouldCancel() -> Bool {
            processed += 1
            return processed & 63 == 0 && cancellation?.isCancelled == true
        }
        if let cached = candidateCache[request] { return cached }
        let prefix = request.composingText
        let maximumResults = max(request.maximumResults, 0)
        guard maximumResults > 0 else { return [] }
        let observedPrevious = request.precedingWords.last
        func dictionaryContext(_ word: String) -> String {
            request.phoneticConfiguration.enabled
                ? soundLexicon?.dictionaryWord(for: word, options: request.phoneticConfiguration.options) ?? word
                : word
        }
        let previous = observedPrevious.map(dictionaryContext)
        let earlier = request.precedingWords.count >= 2
            ? dictionaryContext(request.precedingWords[request.precedingWords.count - 2])
            : nil
        var learnedNext = previous.flatMap { learnedBigrams[$0] } ?? [:]
        if let observedPrevious, observedPrevious != previous {
            learnedNext.merge(learnedBigrams[observedPrevious] ?? [:], uniquingKeysWith: max)
        }
        let bundledNext = previous.flatMap { bundledBigrams?.followers(for: $0, cancellation: cancellation) } ?? []
        let trigramNext: [NextWord]
        if let earlier, let previous {
            trigramNext = bundledTrigrams[Self.trigramKey(earlier, previous)] ?? []
        } else {
            trigramNext = []
        }
        var bundledCounts: [String: Int] = [:]
        for next in bundledNext {
            if shouldCancel() { return [] }
            bundledCounts[next.word] = max(bundledCounts[next.word, default: 0], next.count)
        }
        var trigramCounts: [String: Int] = [:]
        for next in trigramNext {
            if shouldCancel() { return [] }
            trigramCounts[next.word] = max(trigramCounts[next.word, default: 0], next.count)
        }
        let hasContinuations = previous != nil && (
            !bundledNext.isEmpty || !learnedNext.isEmpty || !trigramNext.isEmpty
        )
        let phonetic = request.phoneticSource.flatMap { source -> (String, SmartPhoneticV2.Options)? in
            request.phoneticConfiguration.enabled && !source.isEmpty ? (source, request.phoneticConfiguration.options) : nil
        }
        var pinnedWord: String?
        if let (source, options) = phonetic, let lexicon = soundLexicon {
            let spelled = SmartPhoneticV2.transliterate(source, options: options)
            if SinhalaSoundLexicon.isExplicit(source),
               (SinhalaSoundLexicon.isLoneVowel(spelled) || learnedWords[spelled] != nil
                || lexicon.exact(SinhalaSoundLexicon.soundKey(spelled)).contains(where: {
                    SinhalaSoundLexicon.restyle($0, options: options) == spelled
                })) {
                pinnedWord = spelled
            }
        }

        // Keep only the requested winners while scanning. The old path built
        // and sorted up to 4,096 temporary candidates on every keypress.
        var ranked: [SinhalaPredictionCandidate] = []
        ranked.reserveCapacity(maximumResults)
        var considered = Set<String>()
        considered.reserveCapacity(maximumResults * 16)

        func consider(word: String, frequency: Int, unigramWeight: Double, canonicalWord: String? = nil) {
            guard word != prefix || phonetic != nil else { return }
            // Next-word ranking should move forward. Repeating the word that
            // was just committed makes a suggestion chain look stuck.
            if prefix.isEmpty, word == previous { return }
            guard considered.insert(word).inserted else { return }
            let canonical = canonicalWord ?? word
            let baseScore = unigramWeight * log(Double(max(frequency, 1)) + 1)
                + Double(max(learnedWords[canonical, default: 0], learnedWords[word, default: 0])) * 1.00
                + Double(max(learnedNext[canonical, default: 0], learnedNext[word, default: 0])) * 1.80
                // Corpus context is a stronger next-word signal than global
                // word frequency, while local choices still adapt the result.
                + log(Double(bundledCounts[canonical, default: 0]) + 1) * 1.70
                + log(Double(trigramCounts[canonical, default: 0]) + 1) * 2.20
                + max(recencyScore(for: canonical), recencyScore(for: word))
            let score = word == pinnedWord ? Double.greatestFiniteMagnitude : baseScore
            let candidate = SinhalaPredictionCandidate(text: word, score: score)
            let insertionIndex = ranked.firstIndex {
                // Keep this priority inside the bounded ranking, otherwise a
                // frequent learned near-match can evict a completion entirely.
                if phonetic == nil, !prefix.isEmpty {
                    let candidateContinues = hasUnicodeScalarPrefix(candidate.text, prefix)
                    let currentContinues = hasUnicodeScalarPrefix($0.text, prefix)
                    if candidateContinues != currentContinues { return candidateContinues }
                }
                return candidate.score > $0.score
                    || (candidate.score == $0.score && candidate.text < $0.text)
            } ?? ranked.endIndex
            guard insertionIndex < maximumResults || ranked.count < maximumResults else { return }
            ranked.insert(candidate, at: insertionIndex)
            if ranked.count > maximumResults { ranked.removeLast() }
        }

        if let (source, options) = phonetic, let lexicon = soundLexicon {
            let spelled = SmartPhoneticV2.transliterate(source, options: options)
            let key = SinhalaSoundLexicon.soundKey(spelled)
            // Whole-word sound matches are eligible for Space. Completions are suggestions only.
            for word in lexicon.exact(key) {
                if shouldCancel() { return [] }
                consider(word: SinhalaSoundLexicon.restyle(word, options: options),
                         frequency: lexicon.counts[word, default: 0], unigramWeight: 1.0, canonicalWord: word)
            }
            if let pinnedWord {
                consider(word: pinnedWord, frequency: lexicon.counts[pinnedWord, default: 0], unigramWeight: 1.0)
            }
            for (word, count) in learnedWords where SinhalaSoundLexicon.soundKey(word) == key {
                if shouldCancel() { return [] }
                consider(word: SinhalaSoundLexicon.restyle(word, options: options),
                         frequency: unigramFrequency[word, default: count], unigramWeight: 1.0, canonicalWord: word)
            }
            if !request.exactPhoneticOnly {
                // Rank completions separately: an exact sound match must always precede them.
                let exactRanked = ranked
                ranked = []
                for word in lexicon.prefix(SinhalaSoundLexicon.withoutTrailingHal(key)) {
                    if shouldCancel() { return [] }
                    consider(word: SinhalaSoundLexicon.restyle(word, options: options),
                             frequency: lexicon.counts[word, default: 0], unigramWeight: 1.0, canonicalWord: word)
                }
                for (word, count) in learnedWords where SinhalaEngine.hasUnicodeScalarPrefix(
                    SinhalaSoundLexicon.soundKey(word), SinhalaSoundLexicon.withoutTrailingHal(key)) {
                    if shouldCancel() { return [] }
                    consider(word: SinhalaSoundLexicon.restyle(word, options: options), frequency: count, unigramWeight: 1.0, canonicalWord: word)
                }
                ranked = Array((exactRanked + ranked).prefix(maximumResults))
            }
        } else if prefix.isEmpty {
            if hasContinuations {
                // Contextual next-word should stay on actual followers. Mixing
                // in globally common words made the rail stall on ඇති / වන.
            } else if previous == nil {
                let starts = sentenceStartEntries.isEmpty
                    ? frequentEntries.prefix(max(maximumResults * 8, 24))
                    : ArraySlice(sentenceStartEntries.prefix(max(maximumResults * 8, 24)))
                for entry in starts {
                    if shouldCancel() { return [] }
                    consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
                }
            } else {
                for entry in frequentEntries.prefix(max(maximumResults * 8, 24)) {
                    if shouldCancel() { return [] }
                    consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
                }
            }
        } else {
            let firstMatch = firstIndex(atOrAfter: prefix)
            let upperBound = min(entries.count, firstMatch + 4_096)
            for index in firstMatch..<upperBound {
                if shouldCancel() { return [] }
                let entry = entries[index]
                guard hasUnicodeScalarPrefix(entry.word, prefix) else { break }
                consider(word: entry.word, frequency: entry.frequency, unigramWeight: 1.0)
            }
            // Personal words need not exist in the bundled corpus to be
            // returned as a completion.
            for (word, count) in learnedWords {
                if shouldCancel() { return [] }
                guard hasUnicodeScalarPrefix(word, prefix) else { continue }
                consider(word: word, frequency: count, unigramWeight: 1.0)
            }
            // A single edit is enough to rescue the common near-miss without
            // turning the candidate rail into a spell-check UI. Restrict the
            // scan to the personal model, which is intentionally compact.
            if prefix.count >= 3 {
                for (word, count) in learnedWords {
                    if shouldCancel() { return [] }
                    guard editDistanceAtMostOne(prefix, word) else { continue }
                    consider(word: word, frequency: count, unigramWeight: 1.0)
                }
            }
        }

        // Contextual selections can be custom words which are absent from the
        // corpus's initial frequency slice. Include them without a full sort.
        let continuationUnigramWeight: Double = prefix.isEmpty && hasContinuations ? 0.20 : 1.0
        for (word, count) in learnedNext {
            if phonetic != nil { break }
            if shouldCancel() { return [] }
            guard prefix.isEmpty || hasUnicodeScalarPrefix(word, prefix) else { continue }
            consider(
                word: word,
                frequency: unigramFrequency[word, default: learnedWords[word, default: count]],
                unigramWeight: continuationUnigramWeight
            )
        }
        for next in bundledNext {
            if phonetic != nil { break }
            if shouldCancel() { return [] }
            guard prefix.isEmpty || hasUnicodeScalarPrefix(next.word, prefix) else { continue }
            consider(
                word: next.word,
                frequency: unigramFrequency[next.word, default: 0],
                unigramWeight: continuationUnigramWeight
            )
        }
        for next in trigramNext {
            if phonetic != nil { break }
            if shouldCancel() { return [] }
            guard prefix.isEmpty || hasUnicodeScalarPrefix(next.word, prefix) else { continue }
            consider(
                word: next.word,
                frequency: unigramFrequency[next.word, default: 0],
                unigramWeight: continuationUnigramWeight
            )
        }
        guard cancellation?.isCancelled != true else { return [] }
        if cachedRequests.count == 32 {
            candidateCache.removeValue(forKey: cachedRequests.removeFirst())
        }
        cachedRequests.append(request)
        candidateCache[request] = ranked
        return ranked
    }

    func nextKeyWeights(
        latinBuffer: String,
        mode: SinhalaEngine.Mode,
        shifted: Bool,
        from ranked: [SinhalaPredictionCandidate],
        precedingWords: [String]
    ) -> [String: Double] {
        nextKeyWeights(latinBuffer: latinBuffer, mode: mode, shifted: shifted,
                       from: ranked, precedingWords: precedingWords, cancellation: nil)
    }
    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        cancellation: PredictionCancellationToken?) -> [String: Double] {
        nextKeyWeights(latinBuffer: latinBuffer, mode: mode, shifted: shifted,
                       from: ranked, precedingWords: precedingWords,
                       configuration: KeyboardPreferences.hotPath.smartPhonetic, cancellation: cancellation)
    }

    func nextKeyWeights(latinBuffer: String, mode: SinhalaEngine.Mode, shifted: Bool,
                        from ranked: [SinhalaPredictionCandidate], precedingWords: [String],
                        configuration: SmartPhoneticConfiguration,
                        cancellation: PredictionCancellationToken?) -> [String: Double] {
        let interval = KeyboardPerformance.begin("NextKeyWeights")
        defer { KeyboardPerformance.end(interval) }
        guard cancellation?.isCancelled != true, mode != .sls, !latinBuffer.isEmpty, !ranked.isEmpty else { return [:] }
        modelLock.lock()
        defer { modelLock.unlock() }
        synchronizeLearningResetLocked()
        var scores: [String: Double] = [:]
        let currentRendered = SinhalaEngine.transliterate(latinBuffer, mode: mode, configuration: configuration)
        var rewriteCache: [String: Double] = [:]
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            guard cancellation?.isCancelled != true else { return [:] }
            let lower = String(UnicodeScalar(scalar)!)
            let source = shifted ? lower.uppercased() : lower
            let nextRendered = Self.strippingTrailingVirama(
                SinhalaEngine.transliterate(latinBuffer + source, mode: mode, configuration: configuration)
            )
            guard !nextRendered.isEmpty, nextRendered != currentRendered else { continue }
            var score = 0.0
            for candidate in ranked where SinhalaEngine.hasUnicodeScalarPrefix(
                mode == .smartPhonetic && configuration.enabled ? SinhalaSoundLexicon.soundKey(candidate.text) : candidate.text,
                mode == .smartPhonetic && configuration.enabled ? SinhalaSoundLexicon.soundKey(nextRendered) : nextRendered) {
                score += min(candidate.score, 100)
            }
            // Some roman sequences rewrite the rendered prefix completely
            // (`s` + `h` is the common case). A tiny binary-search probe keeps
            // predictive hit areas working without recursively running the
            // full candidate ranker for every letter key.
            if score == 0 {
                if let cached = rewriteCache[nextRendered] {
                    score = cached
                } else {
                    if mode == .smartPhonetic, configuration.enabled, let lexicon = soundLexicon {
                        let key = SinhalaSoundLexicon.soundKey(nextRendered)
                        let exact = lexicon.exact(key).map { lexicon.counts[$0, default: 0] }.max()
                        let partial = lexicon.prefix(key, limit: 8).map { lexicon.counts[$0, default: 0] }.max() ?? 0
                        score = exact.map { log(Double($0) + 1) } ?? log(Double(partial) + 1) * 0.4
                    } else {
                        score = lightweightCompletionScore(for: nextRendered, cancellation: cancellation)
                    }
                    rewriteCache[nextRendered] = score
                }
            }
            if score > 0 {
                scores[lower, default: 0] += score
            }
        }
        guard cancellation?.isCancelled != true, let maximum = scores.values.max(), maximum > 0 else { return [:] }
        return scores.mapValues { $0 / maximum }
    }

    private func lightweightCompletionScore(for prefix: String, cancellation: PredictionCancellationToken?) -> Double {
        let start = firstIndex(atOrAfter: prefix)
        var score = 0.0
        var matches = 0
        for index in start..<entries.count {
            let entry = entries[index]
            guard hasUnicodeScalarPrefix(entry.word, prefix) else { break }
            score += log(Double(max(entry.frequency, 1)) + 1)
            matches += 1
            if matches == 8 { break }
        }
        if matches < 8 {
            for (offset, entry) in learnedWords.enumerated() {
                if offset & 63 == 0, cancellation?.isCancelled == true { return 0 }
                let (word, count) = entry
                guard hasUnicodeScalarPrefix(word, prefix) else { continue }
                score += log(Double(max(count, 1)) + 1)
                matches += 1
                if matches == 8 { break }
            }
        }
        return score
    }

    func recordSelection(_ word: String, after precedingWord: String?) {
        modelLock.lock()
        defer { modelLock.unlock() }
        synchronizeLearningResetLocked()
        record(word, after: precedingWord, selectionBoost: 4, persistImmediately: true)
    }

    func recordCommittedWord(_ word: String, after precedingWord: String?) {
        modelLock.lock()
        defer { modelLock.unlock() }
        synchronizeLearningResetLocked()
        record(word, after: precedingWord, selectionBoost: 1, persistImmediately: false)
    }

    private func record(_ word: String, after precedingWord: String?, selectionBoost: Int, persistImmediately: Bool) {
        guard isSinhalaWord(word) else { return }
        hasUnsavedLearning = true
        learningRevision += 1
        candidateCache.removeAll(keepingCapacity: true)
        cachedRequests.removeAll(keepingCapacity: true)
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
        schedulePersistence(delay: persistImmediately ? 0 : 3)
    }

    private func synchronizeLearningResetLocked() {
        let generation = defaults.string(forKey: KeyboardPreferences.learningResetKey)
        guard generation != learningGeneration else { return }
        learningGeneration = generation
        learningRevision += 1
        persistedRevision = -1
        persistenceWorkItem?.cancel()
        persistenceWorkItem = nil
        learnedWords.removeAll()
        learnedBigrams.removeAll()
        recency.removeAll()
        recencyClock = 0
        candidateCache.removeAll()
        cachedRequests.removeAll()
        hasUnsavedLearning = false
    }

    func flushPendingPersistence() {
        modelLock.lock()
        synchronizeLearningResetLocked()
        persistenceWorkItem?.cancel()
        persistenceWorkItem = nil
        guard hasUnsavedLearning else { modelLock.unlock(); return }
        let words = learnedWords, bigrams = learnedBigrams, recent = recency
        let generation = learningGeneration, revision = learningRevision
        modelLock.unlock()
        // The serial writer owns disk and interprocess waits, never modelLock.
        _ = persistenceQueue.sync {
            KeyboardPerformance.measure("SinhalaPersistence") {
                KeyboardPreferences.withLearningPersistenceLock {
                    defaults.synchronize()
                    guard defaults.string(forKey: KeyboardPreferences.learningResetKey) == generation else { return }
                    modelLock.lock()
                    let superseded = revision <= persistedRevision
                    modelLock.unlock()
                    guard !superseded else { return }
                    defaults.set(words, forKey: learnedWordsKey)
                    defaults.set(recent, forKey: recencyKey)
                    defaults.set(bigrams, forKey: learnedBigramsKey)
                    defaults.synchronize()
                    modelLock.lock()
                    if learningGeneration == generation {
                        persistedRevision = revision
                        if learningRevision == revision { hasUnsavedLearning = false }
                    }
                    modelLock.unlock()
                }
            }
        }
    }

    private func schedulePersistence(delay: TimeInterval) {
        persistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingPersistence() }
        persistenceWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
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
        SinhalaEngine.isSinhalaWord(text)
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

    private static func isLexicallySorted(_ values: [Entry]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0.word <= $1.word }
    }

    private static func isValidModelWord(_ value: Substring) -> Bool {
        let scalars = value.unicodeScalars
        return !scalars.isEmpty && scalars.filter { $0.value != 0x200D && $0.value != 0x200C }.count <= 24
            && SinhalaEngine.isSinhalaWord(String(value))
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
