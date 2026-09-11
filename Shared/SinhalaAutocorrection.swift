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
    private var entries: [Entry] = []
    private var exact: [String: Int] = [:]
    /// A delete key represents every word one grapheme away. The index is
    /// intentionally built during warm-up, never on a key press.
    private var deletionIndex: [String: [Int]] = [:]

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
        return exact[Self.normalized(word)] != nil
    }

    /// Returned candidates are safe to display in the existing suggestion rail.
    /// An exact verified word never receives spelling alternatives.
    func suggestions(for word: String, maximumResults: Int = 3) -> [Candidate] {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let normalized = Self.normalized(word)
        guard isEligible(normalized), exact[normalized] == nil,
              !KeyboardPreferences.isAutocorrectProtected(normalized) else { return [] }
        return rankedCandidatesLocked(for: normalized).prefix(max(0, maximumResults)).map {
            Candidate(text: $0.word, frequency: $0.frequency)
        }
    }

    /// V1 is deliberately more conservative than its suggestion list: it only
    /// replaces when exactly one verified one-edit candidate exists.
    func correction(for word: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        let normalized = Self.normalized(word)
        guard isEligible(normalized), exact[normalized] == nil,
              !KeyboardPreferences.isAutocorrectProtected(normalized) else { return nil }
        let candidates = rankedCandidatesLocked(for: normalized)
        guard candidates.count == 1 else { return nil }
        return candidates[0].word
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private func loadLocked() {
        guard !didLoad else { return }
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
            guard isEligible(word), exact[word] == nil else { continue }
            exact[word] = entries.count
            entries.append(.init(word: word, frequency: Int(frequency)))
        }
        deletionIndex.reserveCapacity(entries.count * 3)
        for (index, entry) in entries.enumerated() {
            for key in Self.deletionKeys(for: entry.word) {
                var values = deletionIndex[key, default: []]
                if values.count < 12 { values.append(index) }
                deletionIndex[key] = values
            }
        }
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
            return Self.editDistanceAtMostOne(graphemes, Array(entry.word)) ? entry : nil
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
