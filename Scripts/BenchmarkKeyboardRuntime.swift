import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let resources = root.appendingPathComponent("AksharaKeyboard/Resources")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let suite = "lk.org.akshara.benchmark.\(UUID().uuidString)"
let store = UserDefaults(suiteName: suite)!
defer { try? FileManager.default.removeItem(at: scratch); store.removePersistentDomain(forName: suite) }
for name in ["SinhalaNextWordModel.tsv", "SinhalaAutocorrect.lexicon"] {
    try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
}
func provider(indexed: Bool = true) -> SinhalaFrequencyListPredictionProvider {
    .init(modelURL: resources.appendingPathComponent("SinhalaFrequencyModel.tsv"),
          nextWordURL: (indexed ? resources : scratch).appendingPathComponent("SinhalaNextWordModel.tsv"),
          trigramURL: resources.appendingPathComponent("SinhalaTrigramModel.tsv"),
          sentenceStartURL: resources.appendingPathComponent("SinhalaSentenceStartModel.tsv"), defaults: store)
}
func correction(indexed: Bool = true) -> SinhalaAutocorrectionService {
    .init(artifactURL: (indexed ? resources : scratch).appendingPathComponent("SinhalaAutocorrect.lexicon"))
}
func measure(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds; body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
func report(_ name: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    func value(_ quantile: Double) -> String {
        String(format: "%.4f", sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * quantile)) - 1)])
    }
    print("| \(name) | \(samples.count) | \(value(0.5)) | \(value(0.95)) | \(value(1)) |")
}
print("Desktop swiftc -O; filesystem caches warmed; durations in milliseconds. UIKit/host waits excluded.")
print("| Operation | Samples | Median | p95 | Max |\n|---|---:|---:|---:|---:|")
for indexed in [false, true] {
    report("Sinhala preparation \(indexed ? "sidecar" : "fallback")", (0..<3).map { _ in
        let model = provider(indexed: indexed)
        return measure { model.prepareBundledModelsIfNeeded() }
    })
    report("Correction preparation \(indexed ? "sidecar" : "fallback")", (0..<3).map { _ in
        let service = correction(indexed: indexed)
        return measure { service.prepareIfNeeded() }
    })
}
let data = try String(contentsOf: resources.appendingPathComponent("SinhalaFrequencyModel.tsv"), encoding: .utf8)
let words = data.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: "\t").first.map(String.init) }
let prefixes = Array(Set(words.filter { $0.unicodeScalars.count >= 2 }.map {
    String(String.UnicodeScalarView($0.unicodeScalars.prefix(2)))
})).sorted().prefix(120)
let model = provider(); model.prepareBundledModelsIfNeeded()
report("Broad prefix cache misses", ["ක", "ම", "ස", "අ", "ප", "ද"].map { prefix in
    measure { _ = model.candidates(for: .init(composingText: prefix, precedingWords: ["එය"], maximumResults: 24)) }
})
report("Two-scalar prefix cache misses", prefixes.map { prefix in
    measure { _ = model.candidates(for: .init(composingText: prefix, precedingWords: [], maximumResults: 24)) }
})
let request = SinhalaPredictionRequest(composingText: "ක", precedingWords: ["එය"], maximumResults: 24)
_ = model.candidates(for: request)
report("Candidate cache hits", (0..<500).map { _ in measure { _ = model.candidates(for: request) } })
let ranked = model.candidates(for: request)
report("Next-key weights", (0..<100).map { _ in measure {
    _ = model.nextKeyWeights(latinBuffer: "k", mode: .smartPhonetic, shifted: false, from: ranked, precedingWords: ["එය"])
} })
let fullWords = Array(words.prefix(512))
store.set(Dictionary(uniqueKeysWithValues: fullWords.enumerated().map { ($0.element, $0.offset % 50 + 1) }), forKey: "prediction.learnedWords.v1")
store.set(Dictionary(uniqueKeysWithValues: fullWords.map { ($0, Dictionary(uniqueKeysWithValues: fullWords.prefix(48).map { ($0, 4) })) }), forKey: "prediction.learnedBigrams.v1")
let fullModel = provider(); fullModel.prepareBundledModelsIfNeeded()
report("Prefix misses with full personal model", prefixes.map { prefix in measure {
    _ = fullModel.candidates(for: .init(composingText: prefix, precedingWords: [fullWords[0]], maximumResults: 24))
} })
let service = correction(); service.prepareIfNeeded()
report("Correction cache misses", fullWords.prefix(120).map { word in measure { _ = service.evaluate(String(word.dropLast())) } })
let sample = String(fullWords[0].dropLast()); _ = service.evaluate(sample)
report("Correction cache hits", (0..<500).map { _ in measure { _ = service.evaluate(sample) } })
let emojiData = SinhalaEmojiSuggestions.loadIndex(from: resources.appendingPathComponent("SinhalaEmojiIndex.json"))!
let emojiIndex = SinhalaEmojiPrefixIndex(index: emojiData)
report("Sinhala emoji prefix index", emojiData.keys.sorted().prefix(120).map { word in measure {
    _ = emojiIndex.lookup(String(String.UnicodeScalarView(word.unicodeScalars.prefix(2))))
} })
let keywordData = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: root.appendingPathComponent("AksharaKeyboard/EmojiSearchIndex.json")))
let keywords = EmojiKeywordSearchIndex(index: keywordData, locale: Locale(identifier: "en_US"))
report("Emoji keyword scan", (0..<100).map { index in measure { _ = keywords.search(["face", "heart", "cat", "flag"][index % 4]) } })
let englishURL = resources.appendingPathComponent("EnglishPrediction.sqlite3")
report("English construction and preparation", (0..<3).map { _ in measure {
    EnglishPredictionProvider(databaseURL: englishURL, defaults: store).prepareIfNeeded()
} })
let english = EnglishPredictionProvider(databaseURL: englishURL, defaults: store)
english.prepareIfNeeded()
let englishPrefixes = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]
report("English broad prefix cache misses", englishPrefixes.map { prefix in measure {
    _ = english.candidates(for: .init(composingText: prefix, precedingWords: ["the"], maximumResults: 24))
} })
let englishRequest = SinhalaPredictionRequest(composingText: "h", precedingWords: ["hello"], maximumResults: 24)
_ = english.candidates(for: englishRequest)
report("English candidate cache hits", (0..<500).map { _ in measure { _ = english.candidates(for: englishRequest) } })
let englishWords = (0..<512).map { number -> String in
    "akshara" + String(UnicodeScalar(97 + number / 26)!) + String(UnicodeScalar(97 + number % 26)!)
}
store.set(Dictionary(uniqueKeysWithValues: englishWords.map { ($0, 4) }), forKey: "prediction.english.words.v1")
store.set(Dictionary(uniqueKeysWithValues: englishWords.map { ($0, Dictionary(uniqueKeysWithValues: englishWords.prefix(48).map { ($0, 4) })) }), forKey: "prediction.english.followers.v1")
let fullEnglish = EnglishPredictionProvider(databaseURL: englishURL, defaults: store); fullEnglish.prepareIfNeeded()
report("English misses with full personal model", englishWords.prefix(100).map { previous in measure {
    _ = fullEnglish.candidates(for: .init(composingText: "a", precedingWords: [previous], maximumResults: 24))
} })
