import Foundation

/// Offline spelling validation and conservative one-edit correction. The
/// bundled artifact is generated from Akshara Dictionary's redistributable
/// verified-spelling export; it deliberately has no network dependency.
final class SinhalaAutocorrectionService {
    static let shared = SinhalaAutocorrectionService()

    struct Candidate: Equatable {
        let text: String
        let frequency: Int
    }

    private struct Entry {
        let word: String
        let frequency: Int
    }

    private static let magic = Array("AKSHARA_AUTOCORRECT_V1\0".utf8)
    private let artifactURL: URL?
    private let lock = NSLock()
    private var didLoad = false
    private var evaluationCache: [String: (revision: Int, result: CorrectionEvaluation)] = [:]
    private var cachedWords: [String] = []
    private var entries: [Entry] = []
    private var exact: [String: Int] = [:]
    private var joinerEquivalents: [String: [Int]] = [:]
    /// A delete key represents every word one grapheme away. The index is
    /// intentionally built during warm-up, never on a key press.
    private var deletionIndex: [String: [Int]] = [:]
    private(set) var usesPrebuiltDeletionIndex = false

    init(artifactURL: URL? = Bundle.main.url(forResource: "SinhalaAutocorrect", withExtension: "lexicon")) {
        self.artifactURL = artifactURL
    }

    func prepareIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
    }

    func isVerified(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let normalized = Self.normalized(word)
        return exact[normalized] != nil ||
            (Self.hasValidJoins(normalized) && joinerEquivalents[Self.withoutJoiners(normalized)] != nil)
    }

    struct CorrectionEvaluation: Equatable {
        let suggestions: [Candidate]
        let replacement: String?
    }

    /// One lookup supplies both the rail and conservative boundary correction.
    func evaluate(_ word: String, maximumResults: Int = 3) -> CorrectionEvaluation {
        let interval = KeyboardPerformance.begin("CorrectionEvaluation")
        defer { KeyboardPerformance.end(interval) }
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        let normalized = Self.normalized(word)
        let revision = KeyboardPreferences.protectedWordRevision
        if let cached = evaluationCache[normalized], cached.revision == revision {
            return .init(suggestions: Array(cached.result.suggestions.prefix(max(0, maximumResults))), replacement: cached.result.replacement)
        }
        guard isEligible(normalized), exact[normalized] == nil,
              !KeyboardPreferences.isAutocorrectProtected(normalized) else {
            return .init(suggestions: [], replacement: nil)
        }
        let equivalent = joinerEquivalents[Self.withoutJoiners(normalized)] ?? []
        // Repaya and classical/touching variants may add optional joiners.
        // A verified letter sequence must never lose a deliberate join.
        if Self.hasValidJoins(normalized), !equivalent.isEmpty {
            return .init(suggestions: [], replacement: nil)
        }
        if equivalent.count == 1, let id = equivalent.first {
            let candidate = Candidate(text: entries[id].word, frequency: entries[id].frequency)
            return .init(suggestions: maximumResults > 0 ? [candidate] : [], replacement: candidate.text)
        }
        let conservative = rankedCandidatesLocked(for: normalized)
        var suggestions = conservative
        var seen = Set(conservative.map(\.word))
        // Swap complete graphemes only. These are explicit suggestions;
        // automatic replacement retains the existing one-edit policy.
        let graphemes = Array(normalized)
        for index in 0..<(graphemes.count - 1) where graphemes[index] != graphemes[index + 1] {
            var swapped = graphemes
            swapped.swapAt(index, index + 1)
            if let id = exact[Self.normalized(String(swapped))], seen.insert(entries[id].word).inserted {
                suggestions.append(entries[id])
            }
        }
        suggestions.sort { $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency }
        let result = CorrectionEvaluation(suggestions: suggestions.map {
            Candidate(text: $0.word, frequency: $0.frequency)
        }, replacement: conservative.count == 1 ? conservative[0].word : nil)
        if evaluationCache[normalized] == nil {
            if cachedWords.count == 64 { evaluationCache.removeValue(forKey: cachedWords.removeFirst()) }
            cachedWords.append(normalized)
        }
        evaluationCache[normalized] = (revision, result)
        return .init(suggestions: Array(result.suggestions.prefix(max(0, maximumResults))), replacement: result.replacement)
    }

    func suggestions(for word: String, maximumResults: Int = 3) -> [Candidate] {
        evaluate(word, maximumResults: maximumResults).suggestions
    }

    func correction(for word: String) -> String? { evaluate(word).replacement }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private static func hasValidJoins(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let joins = scalars.indices.filter { scalars[$0].value == 0x200D || scalars[$0].value == 0x200C }
        return !joins.isEmpty && joins.allSatisfy { index in
            guard index > 0, index + 1 < scalars.count else { return false }
            let previous = scalars[index - 1].value, next = scalars[index + 1].value
            return previous == 0x0DCA && (0x0D9A...0x0DC6).contains(next) ||
                (0x0D9A...0x0DC6).contains(previous) && next == 0x0DCA && index + 2 < scalars.count &&
                    (0x0D9A...0x0DC6).contains(scalars[index + 2].value)
        }
    }
    private static func withoutJoiners(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0x200C && $0.value != 0x200D }))
    }

    private func loadLocked() {
        guard !didLoad else { return }
        let interval = KeyboardPerformance.begin("CorrectionPreparation")
        defer { KeyboardPerformance.end(interval) }
        didLoad = true
        guard let artifactURL,
              let data = try? Data(contentsOf: artifactURL, options: .mappedIfSafe),
              data.count >= Self.magic.count + 4,
              Array(data.prefix(Self.magic.count)) == Self.magic else { return }
        var offset = Self.magic.count
        guard let count = Self.readUInt32(data, at: &offset) else { return }
        entries.reserveCapacity(Int(count))
        exact.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let byteCount = Self.readUInt16(data, at: &offset),
                  offset + Int(byteCount) <= data.count else {
                entries.removeAll(); exact.removeAll(); return
            }
            let wordData = data[offset..<(offset + Int(byteCount))]
            offset += Int(byteCount)
            guard let frequency = Self.readUInt32(data, at: &offset) else {
                entries.removeAll(); exact.removeAll(); return
            }
            let word = Self.normalized(String(decoding: wordData, as: UTF8.self))
            guard SinhalaEngine.isSinhalaWord(word), exact[word] == nil else { continue }
            exact[word] = entries.count
            entries.append(.init(word: word, frequency: Int(frequency)))
        }
        for (id, entry) in entries.enumerated() {
            joinerEquivalents[Self.withoutJoiners(entry.word), default: []].append(id)
        }
        if let indexed = loadDeletionIndex(source: data) {
            deletionIndex = indexed
            usesPrebuiltDeletionIndex = true
            return
        }
        deletionIndex.reserveCapacity(entries.count * 3)
        for (index, entry) in entries.enumerated() {
            guard isEligible(entry.word) else { continue }
            for key in Self.deletionKeys(for: entry.word) {
                var values = deletionIndex[key, default: []]
                if !values.contains(index) { values.append(index) }
                deletionIndex[key] = values
            }
        }
    }

    private func loadDeletionIndex(source: Data) -> [String: [Int]]? {
        let url = artifactURL?.deletingPathExtension().appendingPathExtension("postings")
        guard var reader = PredictionIndexReader(url: url, magic: "AKSHARA_CORRECTION_INDEX_V1\0", source: source),
              let entryCount = reader.uint32(), entryCount == entries.count,
              let count = reader.uint32(), count <= source.count else { return nil }
        var index: [String: [Int]] = [:]
        index.reserveCapacity(count)
        for _ in 0..<count {
            guard let key = reader.string(), !key.isEmpty, index[key] == nil,
                  let length = reader.uint32(), length > 0, length <= entries.count else { return nil }
            var ids: [Int] = []
            for _ in 0..<length {
                guard let id = reader.uint32(), entries.indices.contains(id) else { return nil }
                ids.append(id)
            }
            index[key] = ids
        }
        return reader.isAtEnd ? index : nil
    }

    private func rankedCandidatesLocked(for word: String) -> [Entry] {
        var ids = Set<Int>()
        // Missing grapheme: query itself is a delete form of a dictionary word.
        ids.formUnion(deletionIndex[Self.key(for: Array(word))] ?? [])
        let graphemes = Array(word)
        for key in Self.deletionKeys(for: word) {
            // Substitution: both words share a deletion form.
            ids.formUnion(deletionIndex[key] ?? [])
            // Extra grapheme: this delete form itself may be a dictionary word.
            if let index = exact[Self.normalized(String(key.split(separator: "\u{1F}").joined()))] {
                ids.insert(index)
            }
        }
        return ids.compactMap { index -> Entry? in
            guard entries.indices.contains(index) else { return nil }
            let entry = entries[index]
            return isEligible(entry.word) && Self.editDistanceAtMostOne(graphemes, Array(entry.word)) ? entry : nil
        }.sorted {
            $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency
        }
    }

    private func isEligible(_ word: String) -> Bool {
        guard Array(word).count >= 3 else { return false }
        return word.unicodeScalars.allSatisfy {
            (0x0D80...0x0DFF).contains($0.value) || $0.value == 0x200C || $0.value == 0x200D
        }
    }

    private static func deletionKeys(for word: String) -> [String] {
        let graphemes = Array(word)
        guard graphemes.count > 1 else { return [] }
        return graphemes.indices.map { index in
            key(for: graphemes.enumerated().compactMap { $0.offset == index ? nil : $0.element })
        }
    }

    private static func key(for graphemes: [Character]) -> String {
        graphemes.map(String.init).joined(separator: "\u{1F}")
    }

    private static func editDistanceAtMostOne(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard abs(lhs.count - rhs.count) <= 1 else { return false }
        var left = 0, right = 0, edits = 0
        while left < lhs.count, right < rhs.count {
            if lhs[left] == rhs[right] { left += 1; right += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if lhs.count > rhs.count { left += 1 }
            else if rhs.count > lhs.count { right += 1 }
            else { left += 1; right += 1 }
        }
        return edits + (lhs.count - left) + (rhs.count - right) <= 1
    }

    private static func readUInt16(_ data: Data, at offset: inout Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
