// Deterministic sidecars use Swift's exact grapheme segmentation and NFC rules.
// Usage: swift Scripts/build_prediction_sidecars.swift AksharaKeyboard/Resources
import Foundation
import CryptoKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let checkOnly = CommandLine.arguments.contains("--check")
func writeOrCheck(_ data: Data, name: String) throws {
    let url = directory.appendingPathComponent(name)
    if checkOnly {
        guard try Data(contentsOf: url) == data else {
            throw NSError(domain: "AksharaPredictionIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stale sidecar: \(name)"])
        }
    } else { try data.write(to: url, options: .atomic) }
}
func appendInteger(_ value: Int, to data: inout Data) {
    precondition(value >= 0 && value <= Int(UInt32.max))
    var bytes = UInt32(value).littleEndian
    withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
}
func appendString(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    appendInteger(bytes.count, to: &data); data.append(bytes)
}
func header(_ magic: String, source: Data) -> Data {
    var data = Data(magic.utf8); data.append(contentsOf: SHA256.hash(data: source)); return data
}

func sealed(_ index: Data, magic: String) -> Data {
    let headerSize = magic.utf8.count + 32
    var data = Data(index.prefix(headerSize))
    data.append(contentsOf: SHA256.hash(data: index.suffix(from: headerSize)))
    data.append(index.suffix(from: headerSize))
    return data
}

let bigramURL = directory.appendingPathComponent("SinhalaNextWordModel.tsv")
let bigrams = try Data(contentsOf: bigramURL)
var groups: [(String, Int, Int)] = []
var offset = 0
var previousKeyBytes: Data?
for line in bigrams.split(separator: 10, omittingEmptySubsequences: false) {
    let end = min(bigrams.count, offset + line.count + 1)
    if let tab = line.firstIndex(of: 9), tab > line.startIndex {
        let keyBytes = Data(line[..<tab])
        let key = String(decoding: keyBytes, as: UTF8.self)
        if previousKeyBytes == keyBytes { groups[groups.count - 1].2 = end }
        else { groups.append((key, offset, end)) }
        previousKeyBytes = keyBytes
    }
    offset = end
}
// Match the runtime's byte-grouping and Swift String dictionary semantics:
// later canonically equivalent groups replace earlier ranges.
var lastRanges: [String: (String, Int, Int)] = [:]
for group in groups { lastRanges[group.0] = group }
groups = lastRanges.values.sorted { $0.1 < $1.1 }
var bigramIndex = header("AKSHARA_BIGRAM_INDEX_V1\0", source: bigrams)
appendInteger(groups.count, to: &bigramIndex)
for (key, start, end) in groups {
    appendString(key, to: &bigramIndex); appendInteger(start, to: &bigramIndex); appendInteger(end, to: &bigramIndex)
}
try writeOrCheck(sealed(bigramIndex, magic: "AKSHARA_BIGRAM_INDEX_V1\0"), name: "SinhalaNextWordModel.offsets")

let lexicon = try Data(contentsOf: directory.appendingPathComponent("SinhalaAutocorrect.lexicon"))
let magic = Data("AKSHARA_AUTOCORRECT_V1\0".utf8)
precondition(lexicon.starts(with: magic))
var cursor = magic.count
func integer(_ bytes: Int) -> Int {
    precondition(cursor + bytes <= lexicon.count)
    defer { cursor += bytes }
    return (0..<bytes).reduce(0) { $0 | (Int(lexicon[cursor + $1]) << (8 * $1)) }
}
let count = integer(4)
var words: [String] = [], seen = Set<String>()
for _ in 0..<count {
    let size = integer(2)
    precondition(cursor + size <= lexicon.count)
    let word = String(decoding: lexicon[cursor..<(cursor + size)], as: UTF8.self).precomposedStringWithCanonicalMapping
    cursor += size
    _ = integer(4)
    if word.count >= 3, word.unicodeScalars.allSatisfy({ (0x0D80...0x0DFF).contains($0.value) || $0.value == 0x200C || $0.value == 0x200D }),
       seen.insert(word).inserted { words.append(word) }
}
var postings: [String: [Int]] = [:]
for (id, word) in words.enumerated() {
    let graphemes = Array(word)
    for dropped in graphemes.indices {
        let key = graphemes.enumerated().compactMap { $0.offset == dropped ? nil : String($0.element) }.joined(separator: "\u{1F}")
        if postings[key, default: []].count < 12 { postings[key, default: []].append(id) }
    }
}
var correctionIndex = header("AKSHARA_CORRECTION_INDEX_V1\0", source: lexicon)
appendInteger(words.count, to: &correctionIndex); appendInteger(postings.count, to: &correctionIndex)
for key in postings.keys.sorted() {
    appendString(key, to: &correctionIndex)
    let ids = postings[key]!
    appendInteger(ids.count, to: &correctionIndex)
    for id in ids { appendInteger(id, to: &correctionIndex) }
}
try writeOrCheck(sealed(correctionIndex, magic: "AKSHARA_CORRECTION_INDEX_V1\0"), name: "SinhalaAutocorrect.postings")
print("\(checkOnly ? "Verified" : "Generated") \(groups.count) bigram ranges and \(postings.count) correction keys")
