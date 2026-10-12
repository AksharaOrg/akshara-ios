import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appendingPathComponent("AksharaKeyboard/Resources")
let model = try String(contentsOf: root.appendingPathComponent("Scripts/Fixtures/smart_phonetic_v2_frequency.tsv"), encoding: .utf8)
let rows: [(String, Int)] = model.split(whereSeparator: \.isNewline).compactMap {
    let fields = $0.split(separator: "\t")
    guard fields.count == 2, let n = Int(fields[1]) else { return nil }
    return (String(fields[0]), n)
}
let lexicon = SinhalaSoundLexicon(rows: rows)
func options(_ name: String) -> SmartPhoneticV2.Options {
    switch name {
    case "archaic": return .init(archaic: true)
    case "repaya_zwj": return .init(repayaZwj: true)
    case "classical": return .init(classical: true)
    case "rakaransaya_u": return .init(rakaransayaU: true)
    default: fatalError("Unknown option: " + name)
    }
}
var failures = 0, counts: [String: Int] = [:]
let golden = try String(contentsOf: root.appendingPathComponent("Scripts/Fixtures/smart_phonetic_v2_golden.tsv"), encoding: .utf8)
for line in golden.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    let actual: String, expected: String
    switch f[0] {
    case "T": actual = SmartPhoneticV2.transliterate(f[1]); expected = f[2]
    case "O": actual = SmartPhoneticV2.transliterate(f[2], options: options(f[1])); expected = f[3]
    case "K": actual = SinhalaSoundLexicon.soundKey(f[1]); expected = f[2]
    case "N": actual = SinhalaSoundLexicon.normalize(f[1]); expected = f[2]
    case "C": actual = lexicon.candidates(f[1], partial: f[2] == "1").joined(separator: "|"); expected = f[3]
    case "R": actual = SinhalaSoundLexicon.restyle(f[2], options: options(f[1])); expected = f[3]
    case "D": actual = lexicon.candidates(f[2], partial: f[3] == "1", options: options(f[1])).joined(separator: "|"); expected = f[4]
    default: fatalError("Unknown row: " + f[0])
    }
    counts[f[0], default: 0] += 1
    if !actual.unicodeScalars.elementsEqual(expected.unicodeScalars) {
        if failures < 15 { print("FAIL", f.dropLast().joined(separator: " "), "expected:", expected, "actual:", actual) }
        failures += 1
    }
}
print("Golden rows:", counts, "failures:", failures)
if failures > 0 { exit(1) }

func expect(_ condition: @autoclosure () -> Bool, line: Int = #line) {
    if !condition() { print("FAIL integration line", line); exit(1) }
}
let suite = "lk.org.akshara.v2-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let provider = SinhalaFrequencyListPredictionProvider(
    modelURL: resources.appendingPathComponent("SinhalaFrequencyModel.tsv"),
    nextWordURL: resources.appendingPathComponent("SinhalaNextWordModel.tsv"),
    trigramURL: resources.appendingPathComponent("SinhalaTrigramModel.tsv"),
    sentenceStartURL: resources.appendingPathComponent("SinhalaSentenceStartModel.tsv"), defaults: defaults)
func request(_ roman: String, options: SmartPhoneticV2.Options = .init(),
             preceding: [String] = [], exact: Bool = true) -> SinhalaPredictionRequest {
    .init(composingText: SmartPhoneticV2.transliterate(roman, options: options),
          precedingWords: preceding, maximumResults: 3, phoneticSource: roman,
          phoneticConfiguration: .init(options: options), exactPhoneticOnly: exact)
}
for (roman, expected) in [("honda", "හොඳ"), ("sinhala", "සිංහල"), ("thaththa", "තාත්තා"),
                          ("karanawa", "කරනවා"), ("kazda", "කඳ"), ("R", "ඍ"), ("E", "ඓ")] {
    let result = provider.candidates(for: request(roman)).first?.text
    if result != expected { print("FAIL production choice", roman, result ?? "nil", expected); exit(1) }
}
// Words absent from this corpus keep the rule spelling on Space.
expect((provider.candidates(for: request("kramaya")).first?.text
        ?? SmartPhoneticV2.transliterate("kramaya")) == "ක්\u{200D}රමය")
expect(provider.candidates(for: request("zzzzzz")).isEmpty)
let cancelled = PredictionCancellationToken(); cancelled.cancel()
expect(provider.candidates(for: request("honda"), cancellation: cancelled).isEmpty)
let words = ["kruura", "karma", "akShara", "mrudu", "samruddhi", "dumriya", "dilrukshi", "vidyaava",
             "lankaava", "honda", "kaaryaya", "dham+ma", "ka~n", "karanawakarana", "kamalanzzzzzzzk"]
var incrementalChecks = 0
for mask in 0..<16 {
    let opts = SmartPhoneticV2.Options(archaic: mask & 1 != 0, repayaZwj: mask & 2 != 0,
                                     classical: mask & 4 != 0, rakaransayaU: mask & 8 != 0)
    let config = SmartPhoneticConfiguration(options: opts)
    for word in words {
        var committedSource = "", committedRendered = "", liveSource = ""
        for ch in word {
            liveSource.append(ch)
            let fullSource = committedSource + liveSource
            let full = SmartPhoneticV2.transliterate(fullSource, options: opts)
            let live: String
            if let rendering = PhoneticLiveWindow.liveRendering(source: fullSource,
                committedRendered: committedRendered, mode: .smartPhonetic, configuration: config) {
                live = rendering
            } else {
                committedSource = ""; committedRendered = ""; liveSource = fullSource; live = full
            }
            expect((committedRendered + live).unicodeScalars.elementsEqual(full.unicodeScalars))
            if let split = PhoneticLiveWindow.prefixCommitIfNeeded(source: liveSource, anchor: nil,
                mode: .smartPhonetic, configuration: config, currentLiveRendered: live, maximumLiveSourceLength: 4) {
                committedSource += split.committedSource; committedRendered += split.committedRendered
                liveSource = split.liveSource
            }
            incrementalChecks += 1
        }
        for length in stride(from: word.count, through: 0, by: -1) {
            let source = String(word.prefix(length))
            let rendered = SinhalaEngine.transliterate(source, mode: .smartPhonetic, configuration: config)
            expect(rendered.unicodeScalars.elementsEqual(SmartPhoneticV2.transliterate(source, options: opts).unicodeScalars))
        }
    }
    for roman in ["kruura", "karma", "akShara"] {
        let defaultChoice = provider.candidates(for: request(roman)).first?.text
        let styled = provider.candidates(for: request(roman, options: opts)).first?.text
        expect(styled == defaultChoice.map { SinhalaSoundLexicon.restyle($0, options: opts) })
    }
}
provider.recordSelection("කර්ම", after: nil)
expect(provider.candidates(for: request("karma", options: .init(repayaZwj: true))).first?.text == "කර්\u{200D}ම")
let suggestions = provider.candidates(for: request("kram", exact: false))
expect(!suggestions.isEmpty)
let weights = provider.nextKeyWeights(latinBuffer: "kram", mode: .smartPhonetic, shifted: false,
    from: suggestions, precedingWords: [], configuration: .init(), cancellation: nil)
expect(!weights.isEmpty && weights.values.allSatisfy { $0.isFinite })
expect(SinhalaEngine.transliterate("d", mode: .smartPhonetic, configuration: .classic) == "ඩ්")
expect(SinhalaEngine.transliterate("d", mode: .smartPhonetic, configuration: .init()) == "ද්")
expect(SinhalaEngine.transliterate("d", mode: .phonetic, configuration: .init()) == "ඩ්")
expect(SpaceSuggestionEligibility.accepts(candidate: "ක්\u{200D}රමය", displayedPrefix: "ක්",
    displayedGeneration: 2, currentPrefix: "ක්", currentGeneration: 2))
expect(!SpaceSuggestionEligibility.accepts(candidate: "\u{200D}", displayedPrefix: "ක්",
    displayedGeneration: 2, currentPrefix: "ක්", currentGeneration: 2))
let document = UUID()
let identity = PhoneticChoiceIdentity(document: document, generation: 2, source: "honda", word: "හොන්ද",
    configuration: .init(), protectionRevision: 1)
expect(identity != .init(document: UUID(), generation: 2, source: "honda", word: "හොන්ද", configuration: .init(), protectionRevision: 1))
expect(identity != .init(document: document, generation: 3, source: "honda", word: "හොන්ද", configuration: .init(), protectionRevision: 1))
expect(identity != .init(document: document, generation: 2, source: "honda", word: "හොන්ද", configuration: .classic, protectionRevision: 1))
expect(identity != .init(document: document, generation: 2, source: "honda", word: "හොන්ද", configuration: .init(), protectionRevision: 2))
let preferenceKeys = [KeyboardPreferences.smartPhoneticV2Key, KeyboardPreferences.v2ArchaicKey,
                      KeyboardPreferences.v2RepayaKey, KeyboardPreferences.v2ClassicalKey, KeyboardPreferences.v2RakaransayaKey]
let originals = preferenceKeys.map { KeyboardPreferences.defaults.object(forKey: $0) }
defer {
    for (key, value) in zip(preferenceKeys, originals) {
        if let value { KeyboardPreferences.defaults.set(value, forKey: key) }
        else { KeyboardPreferences.defaults.removeObject(forKey: key) }
    }
    KeyboardPreferences.reload()
}
preferenceKeys.forEach { KeyboardPreferences.defaults.removeObject(forKey: $0) }
KeyboardPreferences.reload()
expect(KeyboardPreferences.hotPath.smartPhonetic == .init())
KeyboardPreferences.setSmartPhoneticConfiguration(.init(enabled: false, options: .init(archaic: true, repayaZwj: true, classical: true, rakaransayaU: true)))
expect(!KeyboardPreferences.hotPath.smartPhonetic.enabled && KeyboardPreferences.hotPath.smartPhonetic.options.classical)
print("Production choices, all 16 option combinations, \(incrementalChecks) incremental checks, cancellation, ZWJ and preferences passed")

