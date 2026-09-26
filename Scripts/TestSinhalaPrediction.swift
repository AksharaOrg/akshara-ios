import Foundation
import SQLite3

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtureURL = root.appendingPathComponent("Scripts/SinhalaPredictionFixture.tsv")
let frequencyURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaFrequencyModel.tsv")
let nextWordURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaNextWordModel.tsv")
let trigramURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaTrigramModel.tsv")
let sentenceStartURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaSentenceStartModel.tsv")
let suiteName = "lk.org.akshara.prediction-fixture"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)

let provider = SinhalaFrequencyListPredictionProvider(
    modelURL: frequencyURL,
    nextWordURL: nextWordURL,
    trigramURL: trigramURL,
    sentenceStartURL: sentenceStartURL,
    defaults: defaults
)
let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
var passed = true

for line in fixture.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3 else {
        fputs("Malformed fixture line: \(line)\n", stderr)
        passed = false
        continue
    }
    let prefix = String(fields[0])
    let precedingWords = fields[1].isEmpty ? [] : fields[1].split(separator: " ").map(String.init)
    let expected = fields[2].split(separator: ",").map(String.init)
    let actual = provider.candidates(for: .init(
        composingText: prefix,
        precedingWords: precedingWords,
        maximumResults: expected.count
    )).map(\.text)
    guard actual == expected else {
        fputs("FAIL prefix=\(prefix) context=\(fields[1]): expected \(expected), got \(actual)\n", stderr)
        passed = false
        continue
    }
}

guard passed else { exit(1) }
print("Sinhala prediction fixtures passed")

let firstHop = provider.candidates(for: .init(
    composingText: "",
    precedingWords: ["අතර"],
    maximumResults: 3
)).map(\.text)
let secondHop = provider.candidates(for: .init(
    composingText: "",
    precedingWords: firstHop.first.map { [$0] } ?? [],
    maximumResults: 3
)).map(\.text)
guard !firstHop.isEmpty else {
    fputs("FAIL chained next-word: missing first hop after අතර\n", stderr)
    exit(1)
}
guard !secondHop.isEmpty else {
    fputs("FAIL chained next-word: missing second hop after \(firstHop[0])\n", stderr)
    exit(1)
}
guard secondHop != firstHop else {
    fputs("FAIL chained next-word: second hop repeated \(firstHop)\n", stderr)
    exit(1)
}
guard !secondHop.contains(firstHop[0]) else {
    fputs("FAIL chained next-word: repeated committed word \(firstHop[0]) in \(secondHop)\n", stderr)
    exit(1)
}
print("Sinhala chained next-word predictions passed (\(firstHop[0]) → \(secondHop.joined(separator: ",")))")

var autocorrectPassed = true
func expectAutocorrect(_ condition: Bool, label: String) {
    guard condition else {
        fputs("FAIL autocorrect \(label)\n", stderr)
        autocorrectPassed = false
        return
    }
}

let autocorrectURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaAutocorrect.lexicon")
let autocorrect = SinhalaAutocorrectionService(artifactURL: autocorrectURL)
expectAutocorrect(autocorrect.isVerified("ගෙදර"), label: "verified word")
expectAutocorrect(autocorrect.correction(for: "ගෙදරා") == "ගෙදර", label: "one extra grapheme")
expectAutocorrect(autocorrect.correction(for: "ගෙදර") == nil, label: "verified word unchanged")
expectAutocorrect(autocorrect.correction(for: "abc") == nil, label: "Latin excluded")
expectAutocorrect(autocorrect.suggestions(for: "ගෙදරා").first?.text == "ගෙදර", label: "correction suggestion")
guard autocorrectPassed else { exit(1) }
print("Sinhala autocorrect fixtures passed")

var easterEggPassed = true
func expectTrueName(rendered: String, phonetic: String, expected: Bool, label: String) {
    let actual = AksharaEasterEgg.isCompleteTrueName(rendered: rendered, phoneticSource: phonetic)
    guard actual == expected else {
        fputs("FAIL easter egg \(label): expected \(expected), got \(actual) rendered=\(rendered) phonetic=\(phonetic)\n", stderr)
        easterEggPassed = false
        return
    }
}

let phoneticAkshara = SinhalaEngine.transliterate("akshara", mode: .phonetic)
let smartAkshara = SinhalaEngine.transliterate("akshara", mode: .smartPhonetic)
let phoneticAkShara = SinhalaEngine.transliterate("akShara", mode: .phonetic)
expectTrueName(rendered: phoneticAkshara, phonetic: "akshara", expected: true, label: "phonetic akshara")
expectTrueName(rendered: smartAkshara, phonetic: "akshara", expected: true, label: "smart phonetic akshara")
expectTrueName(rendered: phoneticAkShara, phonetic: "akShara", expected: true, label: "phonetic akShara")
expectTrueName(rendered: "අක්ෂර", phonetic: "", expected: true, label: "wijesekara akshara")
expectTrueName(rendered: SinhalaEngine.transliterate("akshar", mode: .phonetic), phonetic: "akshar", expected: false, label: "incomplete akshar")
expectTrueName(rendered: SinhalaEngine.transliterate("aksharaya", mode: .phonetic), phonetic: "aksharaya", expected: false, label: "aksharaya")
expectTrueName(rendered: "අක්ෂරය", phonetic: "", expected: false, label: "wijesekara aksharaya")
expectTrueName(rendered: "", phonetic: "", expected: false, label: "empty")

guard easterEggPassed else { exit(1) }
print("Akshara easter-egg true-name matches passed (phonetic=\(phoneticAkshara) akShara=\(phoneticAkShara) smart=\(smartAkshara))")

var compositionPassed = true
func expectComposition(_ actual: Bool, _ expected: Bool, label: String) {
    guard actual == expected else {
        fputs("FAIL composition \(label): expected \(expected), got \(actual)\n", stderr)
        compositionPassed = false
        return
    }
}
func expectRendered(_ input: String, _ expected: String, label: String) {
    let actual = SinhalaEngine.normalizeSLS(input)
    guard actual == expected else {
        fputs("FAIL composition \(label): expected \(expected), got \(actual)\n", stderr)
        compositionPassed = false
        return
    }
}

expectComposition(SinhalaEngine.canExtendPrebase("ෙ", with: "ක"), true, label: "kombuwa plus ka")
expectComposition(SinhalaEngine.canExtendPrebase("ෙ", with: "ෙ"), true, label: "double kombuwa")
expectComposition(SinhalaEngine.canExtendPrebase("ෙක", with: "්"), true, label: "ke plus virama")
expectComposition(SinhalaEngine.canExtendPrebase("ෙක", with: "ා"), true, label: "ke plus aa")
expectComposition(SinhalaEngine.canExtendPrebase("ෙකා", with: "්"), true, label: "ko plus virama")
expectComposition(SinhalaEngine.canExtendPrebase("ෙක්", with: "ක"), false, label: "finished kee does not take ka")
expectComposition(SinhalaEngine.isIndependentVowel("අ"), true, label: "a is independent")
expectComposition(SinhalaEngine.combinesWithIndependentVowel("අ", suffix: "ා"), true, label: "a plus aa")
expectComposition(SinhalaEngine.combinesWithIndependentVowel("ක", suffix: "ා"), false, label: "ka does not combine as independent")
expectRendered("ෙක", "කෙ", label: "kombuwa ka")
expectRendered("ෙක්", "කේ", label: "kombuwa ka virama")
expectRendered("ෙකා", "කො", label: "kombuwa ka aa")
expectRendered("අා", "ආ", label: "independent aa")
let rakaranshaya = "\u{E004}"
let yansaya = "\u{E005}"
expectRendered("ෙප\(rakaranshaya)්", "ප්‍රේ", label: "kombuwa pa rakaranshaya virama")
expectRendered("ෙප\(rakaranshaya)", "ප්‍රෙ", label: "kombuwa pa rakaranshaya")
expectRendered("ෙක\(yansaya)්", "ක්‍යේ", label: "kombuwa ka yansaya virama")
expectComposition(SinhalaEngine.canExtendPrebase("ෙප", with: rakaranshaya), true, label: "ke pa plus rakaranshaya")
expectComposition(SinhalaEngine.canExtendPrebase("ෙප" + rakaranshaya, with: "්"), true, label: "pre plus virama")

guard compositionPassed else { exit(1) }
print("Wijesekara composition helpers passed")

var backspacePassed = true
func expectBackspace(_ actual: String, _ expected: String, label: String) {
    guard actual == expected else {
        fputs("FAIL backspace \(label): expected \(expected), got \(actual)\n", stderr)
        backspacePassed = false
        return
    }
}

if let split = NativeBackspace.lastGrapheme(in: "කා") {
    expectBackspace(split.cluster, "කා", label: "ka+aa cluster")
    expectBackspace(split.remaining, "", label: "ka+aa remaining")
} else {
    fputs("FAIL backspace ka+aa missing grapheme\n", stderr)
    backspacePassed = false
}
if let split = NativeBackspace.lastGrapheme(in: "කට") {
    expectBackspace(split.cluster, "ට", label: "kata last cluster")
    expectBackspace(split.remaining, "ක", label: "kata remaining")
} else {
    fputs("FAIL backspace kata missing grapheme\n", stderr)
    backspacePassed = false
}
expectBackspace(NativeBackspace.lastWordSegment(in: "hello world"), "world", label: "latin words")
expectBackspace(NativeBackspace.lastWordSegment(in: "hello world "), "world ", label: "trailing space plus word")
expectBackspace(NativeBackspace.lastWordSegment(in: "hello,"), "hello,", label: "word with comma")
expectBackspace(NativeBackspace.lastWordSegment(in: "අම්මා ගෙදර"), "ගෙදර", label: "sinhala words")
expectBackspace(NativeBackspace.removingSuffix("xyzකා", suffix: "කා") ?? "nil", "xyz", label: "remove sinhala cluster suffix")
if !NativeBackspace.endsWith("xyzකා", suffix: "කා") {
    fputs("FAIL backspace endsWith sinhala cluster\n", stderr)
    backspacePassed = false
}
if NativeBackspace.endsWith("xyzකා", suffix: "ක") {
    fputs("FAIL backspace endsWith must not split the කා cluster into ක\n", stderr)
    backspacePassed = false
}
if NativeBackspace.endsWith("xyzක්‍ර", suffix: "ක්‍ර") == false {
    fputs("FAIL backspace endsWith rakaransaya cluster\n", stderr)
    backspacePassed = false
}
// Suggestion ranking matches Unicode scalars, but String.hasPrefix does not:
// "කා".hasPrefix("ක") is false because කා is one grapheme. Selection must
// therefore insert the visible candidate rather than requiring hasPrefix.
if "කා".hasPrefix("ක") {
    fputs("FAIL documented grapheme: String.hasPrefix unexpectedly split කා\n", stderr)
    backspacePassed = false
}
if "ක්‍රමය".hasPrefix("ක") {
    fputs("FAIL documented grapheme: String.hasPrefix unexpectedly split ක්‍ර\n", stderr)
    backspacePassed = false
}

guard backspacePassed else { exit(1) }
print("Native backspace helpers passed")

var touchWeightPassed = true
func expectTouch(_ condition: Bool, label: String) {
    guard condition else {
        fputs("FAIL touch weights \(label)\n", stderr)
        touchWeightPassed = false
        return
    }
}

let akshaRendered = SinhalaEngine.transliterate("aksha", mode: .phonetic)
let akShaRendered = SinhalaEngine.transliterate("akSha", mode: .phonetic)
let akshaRanked = provider.candidates(for: .init(
    composingText: akshaRendered,
    precedingWords: [],
    maximumResults: 64
))
let akShaRanked = provider.candidates(for: .init(
    composingText: akShaRendered,
    precedingWords: [],
    maximumResults: 64
))
let akshaWeights = provider.nextKeyWeights(
    latinBuffer: "aksha",
    mode: .phonetic,
    shifted: false,
    from: akshaRanked,
    precedingWords: []
)
let akShaWeights = provider.nextKeyWeights(
    latinBuffer: "akSha",
    mode: .phonetic,
    shifted: false,
    from: akShaRanked,
    precedingWords: []
)
// Phonetic `sh` renders ශ; the frequency list's අක්ෂර uses ෂ (`akSha`).
expectTouch(
    (akshaWeights["r"] ?? 0) > 0 || (akShaWeights["r"] ?? 0) > 0,
    label: "aksha/akSha → r"
)

let sRendered = SinhalaEngine.transliterate("s", mode: .phonetic)
let sRanked = provider.candidates(for: .init(
    composingText: sRendered,
    precedingWords: [],
    maximumResults: 64
))
let sWeights = provider.nextKeyWeights(
    latinBuffer: "s",
    mode: .phonetic,
    shifted: false,
    from: sRanked,
    precedingWords: []
)
expectTouch((sWeights["h"] ?? 0) > 0, label: "s → h rewrite")

let startRanked = provider.candidates(for: .init(
    composingText: "",
    precedingWords: [],
    maximumResults: 64
))
let startWeights = provider.nextKeyWeights(
    latinBuffer: "",
    mode: .phonetic,
    shifted: false,
    from: startRanked,
    precedingWords: []
)
expectTouch(startWeights.isEmpty, label: "empty buffer does not inflate keys")

let afterAthara = provider.candidates(for: .init(
    composingText: "",
    precedingWords: ["අතර"],
    maximumResults: 64
))
let afterAtharaWeights = provider.nextKeyWeights(
    latinBuffer: "",
    mode: .phonetic,
    shifted: false,
    from: afterAthara,
    precedingWords: ["අතර"]
)
expectTouch(afterAtharaWeights.isEmpty, label: "no inflation without a composing letter")

let smartSRendered = SinhalaEngine.transliterate("s", mode: .smartPhonetic)
let smartSRanked = provider.candidates(for: .init(
    composingText: smartSRendered,
    precedingWords: [],
    maximumResults: 64
))
let smartSWeights = provider.nextKeyWeights(
    latinBuffer: "s",
    mode: .smartPhonetic,
    shifted: false,
    from: smartSRanked,
    precedingWords: []
)
expectTouch((smartSWeights["h"] ?? 0) > 0, label: "smart phonetic s → h")

guard touchWeightPassed else { exit(1) }
print("Phonetic next-key touch weights passed (akSha r=\(akShaWeights["r"] ?? 0) s→h=\(sWeights["h"] ?? 0))")

var hygienePassed = true
func expectHygiene(_ condition: Bool, label: String) {
    guard condition else {
        fputs("FAIL composition hygiene \(label)\n", stderr)
        hygienePassed = false
        return
    }
}

for event in CompositionHygieneEvent.allCases {
    expectHygiene(
        CompositionHygiene.shouldCancelWithoutCommit(for: event),
        label: "\(event.rawValue) cancels"
    )
    expectHygiene(
        !CompositionHygiene.shouldCommitLeftoverBuffer(for: event),
        label: "\(event.rawValue) does not commit leftover buffer"
    )
}

let fieldA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
let fieldB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
expectHygiene(
    !CompositionHygiene.documentIdentifierChanged(previous: nil, current: fieldA),
    label: "first document identity is recorded, not a switch"
)
expectHygiene(
    !CompositionHygiene.documentIdentifierChanged(previous: fieldA, current: fieldA),
    label: "same document keeps composition"
)
expectHygiene(
    CompositionHygiene.documentIdentifierChanged(previous: fieldA, current: fieldB),
    label: "new documentIdentifier is a field switch"
)

let amma = SinhalaEngine.transliterate("amma", mode: .smartPhonetic)
expectHygiene(
    !CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: amma,
        documentContextBeforeInput: nil
    ),
    label: "nil context is inconclusive without an identifier change"
)
expectHygiene(
    CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: amma,
        documentContextBeforeInput: nil,
        contextIsExpected: true
    ),
    label: "missing context invalidates composition when Full Access is enabled"
)
expectHygiene(
    CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: amma,
        documentContextBeforeInput: ""
    ),
    label: "empty field invalidates leftover composition"
)
expectHygiene(
    !CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: amma,
        documentContextBeforeInput: "hello " + amma
    ),
    label: "matching caret suffix keeps composition"
)
expectHygiene(
    CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: amma,
        documentContextBeforeInput: "other"
    ),
    label: "unrelated context invalidates leftover composition"
)
expectHygiene(
    !CompositionHygiene.documentContextInvalidatedComposition(
        renderedWord: "",
        documentContextBeforeInput: ""
    ),
    label: "idle session is not invalidated by an empty field"
)

var wordPrefixPassed = true
func expectWordPrefix(_ actual: String, _ expected: String, label: String) {
    guard actual == expected else {
        fputs("FAIL word prefix \(label): expected \(expected), got \(actual)\n", stderr)
        wordPrefixPassed = false
        return
    }
}
expectWordPrefix(
    NativeBackspace.wordPrefixBeforeCaret(in: "මම ගෙද"),
    "ගෙද",
    label: "keeps the word before an accidental space"
)
expectWordPrefix(
    NativeBackspace.wordPrefixBeforeCaret(in: "මම ගෙද, "),
    "",
    label: "does not cross whitespace or punctuation"
)
expectWordPrefix(
    NativeBackspace.wordPrefixBeforeCaret(in: "මම ගෙදර"),
    "ගෙදර",
    label: "reads the prefix at a moved caret"
)
guard wordPrefixPassed else { exit(1) }

var session = KeyboardCompositionSession()
session.phoneticBuffer = "amma"
session.lastPhoneticRendered = amma
session.phoneticCompositionAnchor = "previous field"
session.committedPhoneticSegments = [.init(source: "am", rendered: SinhalaEngine.transliterate("am", mode: .smartPhonetic))]
session.rawBuffer = "amma"
session.visibleEntries = [amma]
session.visibleSources = ["amma"]
session.pendingSource = "ෙ"
session.pendingKind = .prebase
session.pendingHostRendered = "ෙ"
session.pendingHostAnchor = "anchor"
session.pendingAnchorKey = "f"
session.predictionPrefix = amma
let leaked = session.phoneticPreviewIfTyping("a", mode: .smartPhonetic)
expectHygiene(
    leaked != SinhalaEngine.transliterate("a", mode: .smartPhonetic),
    label: "unhygienic session would replay the previous word"
)

session.apply(.documentIdentifierChanged)
expectHygiene(!session.hasLocalComposition, label: "identifier change clears every local buffer")
expectHygiene(session.droppedPredictionDebounceCount == 1, label: "identifier change drops prediction debounce")
expectHygiene(session.predictionGeneration == 1, label: "identifier change invalidates in-flight ranking")
expectHygiene(
    session.phoneticPreviewIfTyping("a", mode: .smartPhonetic)
        == SinhalaEngine.transliterate("a", mode: .smartPhonetic),
    label: "next Smart Phonetic letter does not include the previous word"
)
expectHygiene(
    !CompositionHygiene.shouldCommitLeftoverBuffer(for: .documentIdentifierChanged),
    label: "identifier change must not insert leftover marked text"
)

func seedSmartPhoneticSession() -> KeyboardCompositionSession {
    var seeded = KeyboardCompositionSession()
    seeded.phoneticBuffer = "amma"
    seeded.lastPhoneticRendered = amma
    seeded.rawBuffer = "amma"
    seeded.predictionPrefix = amma
    return seeded
}

for event in [
    CompositionHygieneEvent.returnOrSend,
    .keyboardWillDisappear,
    .inputModeChanged,
    .documentContextChangedUnexpectedly
] {
    var seeded = seedSmartPhoneticSession()
    seeded.apply(event)
    expectHygiene(!seeded.hasLocalComposition, label: "\(event.rawValue) clears local composition")
    expectHygiene(
        seeded.phoneticPreviewIfTyping("k", mode: .smartPhonetic)
            == SinhalaEngine.transliterate("k", mode: .smartPhonetic),
        label: "\(event.rawValue) does not replay leftover Smart Phonetic text"
    )
}

guard hygienePassed else { exit(1) }
print("Composition field-switch hygiene passed")

var unmarkedPassed = true
func expectUnmarked(_ actual: Bool, label: String) {
    guard actual else {
        fputs("FAIL unmarked rewrite \(label)\n", stderr)
        unmarkedPassed = false
        return
    }
}
func expectUnmarkedEqual<T: Equatable>(_ actual: T, _ expected: T, label: String) {
    guard actual == expected else {
        fputs("FAIL unmarked rewrite \(label): expected \(expected), got \(actual)\n", stderr)
        unmarkedPassed = false
        return
    }
}

let smartA = SinhalaEngine.transliterate("a", mode: .smartPhonetic)
let smartAm = SinhalaEngine.transliterate("am", mode: .smartPhonetic)
let smartAmm = SinhalaEngine.transliterate("amm", mode: .smartPhonetic)
let smartAmma = SinhalaEngine.transliterate("amma", mode: .smartPhonetic)
let smartAmmak = SinhalaEngine.transliterate("ammak", mode: .smartPhonetic)
let smartAmmaka = SinhalaEngine.transliterate("ammaka", mode: .smartPhonetic)
let smartS = SinhalaEngine.transliterate("s", mode: .smartPhonetic)
let smartSh = SinhalaEngine.transliterate("sh", mode: .smartPhonetic)
let smartK = SinhalaEngine.transliterate("k", mode: .smartPhonetic)
let smartKa = SinhalaEngine.transliterate("ka", mode: .smartPhonetic)
let smartKak = SinhalaEngine.transliterate("kak", mode: .smartPhonetic)

expectUnmarkedEqual(
    UnmarkedCompositionRewrite.plan(from: "", to: smartA),
    .insertOnly(smartA),
    label: "first letter is insert-only"
)
expectUnmarkedEqual(
    UnmarkedCompositionRewrite.plan(from: smartA, to: smartAm),
    .insertOnly(UnmarkedCompositionRewrite.unicodeScalarSuffix(smartAm, afterPrefix: smartA)),
    label: "a → am appends"
)
expectUnmarkedEqual(
    UnmarkedCompositionRewrite.plan(from: smartAm, to: smartAmm),
    .insertOnly(UnmarkedCompositionRewrite.unicodeScalarSuffix(smartAmm, afterPrefix: smartAm)),
    label: "am → amm appends"
)
expectUnmarked(
    {
        if case .reconcile = UnmarkedCompositionRewrite.plan(from: smartAmm, to: smartAmma) { return true }
        return false
    }(),
    label: "amm → amma strips the trailing virama"
)
expectUnmarkedEqual(
    UnmarkedCompositionRewrite.plan(from: smartAmma, to: smartAmmak),
    .insertOnly(UnmarkedCompositionRewrite.unicodeScalarSuffix(smartAmmak, afterPrefix: smartAmma)),
    label: "amma → ammak appends even after a long prefix"
)
expectUnmarked(
    {
        if case .reconcile = UnmarkedCompositionRewrite.plan(from: smartAmmak, to: smartAmmaka) { return true }
        return false
    }(),
    label: "ammak → ammaka rewrites only the last syllable"
)
expectUnmarked(
    {
        if case .reconcile = UnmarkedCompositionRewrite.plan(from: smartS, to: smartSh) { return true }
        return false
    }(),
    label: "s → sh rewrites ස් to ශ්"
)
expectUnmarked(
    {
        if case .reconcile = UnmarkedCompositionRewrite.plan(from: smartK, to: smartKa) { return true }
        return false
    }(),
    label: "k → ka strips the provisional virama"
)

enum SimulatedDeleteUnit { case unicodeScalar, graphemeCluster }
struct SimulatedHost {
    var beforeInput: String
    var deleteUnit: SimulatedDeleteUnit
    var deleteCount = 0
    var insertCount = 0
    var contextReads = 0

    mutating func apply(_ plan: UnmarkedCompositionRewrite.Plan) {
        switch plan {
        case .none:
            return
        case .insertOnly(let text):
            guard !text.isEmpty else { return }
            beforeInput += text
            insertCount += 1
        case .reconcile(let old, let new, let maximumDeletes):
            UnmarkedCompositionRewrite.reconcile(
                old: old,
                new: new,
                maximumDeletes: maximumDeletes,
                context: {
                    self.contextReads += 1
                    return self.beforeInput
                },
                deleteBackward: {
                    self.deleteCount += 1
                    switch self.deleteUnit {
                    case .graphemeCluster:
                        if !self.beforeInput.isEmpty { self.beforeInput.removeLast() }
                    case .unicodeScalar:
                        if !self.beforeInput.unicodeScalars.isEmpty {
                            self.beforeInput.unicodeScalars.removeLast()
                        }
                    }
                },
                insert: { text in
                    guard !text.isEmpty else { return }
                    self.beforeInput += text
                    self.insertCount += 1
                }
            )
        }
    }
}

func typeSmartPhonetic(
    _ source: String,
    onto prefix: String = "",
    deleteUnit: SimulatedDeleteUnit,
    maximumLiveSourceLength: Int = PhoneticLiveWindow.defaultMaximumSourceLength
) -> (host: SimulatedHost, session: KeyboardCompositionSession) {
    var host = SimulatedHost(beforeInput: prefix, deleteUnit: deleteUnit)
    var session = KeyboardCompositionSession()
    session.phoneticCompositionAnchor = prefix
    for character in source {
        session.phoneticBuffer.append(character)
        let rendered = SinhalaEngine.transliterate(session.phoneticBuffer, mode: .smartPhonetic)
        host.apply(UnmarkedCompositionRewrite.plan(from: session.lastPhoneticRendered, to: rendered))
        session.lastPhoneticRendered = rendered
        session.commitStablePhoneticPrefixIfNeeded(
            mode: .smartPhonetic,
            maximumLiveSourceLength: maximumLiveSourceLength
        )
    }
    return (host, session)
}

for unit in [SimulatedDeleteUnit.unicodeScalar, .graphemeCluster] {
    let unitName = unit == .unicodeScalar ? "scalar" : "grapheme"
    let typed = typeSmartPhonetic("amma", onto: "hello ", deleteUnit: unit)
    expectUnmarkedEqual(
        typed.host.beforeInput,
        "hello " + smartAmma,
        label: "\(unitName) host renders amma"
    )
    let sh = typeSmartPhonetic("sh", deleteUnit: unit)
    expectUnmarkedEqual(sh.host.beforeInput, smartSh, label: "\(unitName) host renders sh")
    let virama = typeSmartPhonetic("ka", deleteUnit: unit)
    expectUnmarkedEqual(virama.host.beforeInput, smartKa, label: "\(unitName) host renders ka")
    let backspace = typeSmartPhonetic("kak", deleteUnit: unit)
    var shrinking = backspace.host
    shrinking.apply(UnmarkedCompositionRewrite.plan(from: smartKak, to: smartKa))
    expectUnmarkedEqual(shrinking.beforeInput, smartKa, label: "\(unitName) host backspaces kak → ka")
}

let longAppend = typeSmartPhonetic("amma", onto: "hello ", deleteUnit: .unicodeScalar)
let beforeK = longAppend.host
var grow = beforeK
grow.apply(UnmarkedCompositionRewrite.plan(from: smartAmma, to: smartAmmak))
expectUnmarkedEqual(grow.deleteCount, beforeK.deleteCount, label: "amma → ammak does not delete")
expectUnmarkedEqual(grow.contextReads, beforeK.contextReads, label: "amma → ammak does not poll the host")
expectUnmarkedEqual(grow.beforeInput, "hello " + smartAmmak, label: "amma → ammak inserts the last cluster")

var lastSyllable = grow
lastSyllable.apply(UnmarkedCompositionRewrite.plan(from: smartAmmak, to: smartAmmaka))
expectUnmarkedEqual(lastSyllable.beforeInput, "hello " + smartAmmaka, label: "ammak → ammaka keeps the earlier syllables")
expectUnmarked(
    lastSyllable.deleteCount - grow.deleteCount < smartAmmak.unicodeScalars.count,
    label: "ammak → ammaka deletes fewer scalars than the whole word"
)

let capped = typeSmartPhonetic(
    "aksharaya",
    onto: "prev ",
    deleteUnit: .unicodeScalar,
    maximumLiveSourceLength: 4
)
expectUnmarked(
    !capped.session.committedPhoneticSegments.isEmpty,
    label: "long Smart Phonetic words commit a stable prefix"
)
expectUnmarked(
    capped.session.phoneticBuffer.count <= 4,
    label: "live Latin window stays at the cap"
)
expectUnmarkedEqual(
    capped.session.phoneticCompositionAnchor,
    "prev " + capped.session.committedPhoneticSegments.map(\.rendered).joined(),
    label: "prefix commit advances the live anchor"
)
expectUnmarkedEqual(
    capped.host.beforeInput,
    "prev " + SinhalaEngine.transliterate("aksharaya", mode: .smartPhonetic),
    label: "prefix commit does not change visible text"
)
expectUnmarkedEqual(
    capped.session.committedPhoneticSegments.map(\.rendered).joined() + capped.session.lastPhoneticRendered,
    SinhalaEngine.transliterate("aksharaya", mode: .smartPhonetic),
    label: "committed prefix plus live suffix stay the full word"
)

let noSplit = PhoneticLiveWindow.prefixCommitIfNeeded(
    source: "amma",
    anchor: "x",
    mode: .smartPhonetic,
    maximumLiveSourceLength: 8
)
expectUnmarked(noSplit == nil, label: "short words stay entirely live")

guard unmarkedPassed else { exit(1) }
print("Unmarked phonetic rewrite passed")

var spacingPassed = true
func expectSpacing(_ actual: String, _ expected: String, label: String) {
    if actual != expected {
        fputs("FAIL spacing \(label): expected \(expected), got \(actual)\n", stderr)
        spacingPassed = false
    }
}

expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "hello "),
    "hello. ",
    label: "space before period collapses and a sentence space follows"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "hello"),
    "hello. ",
    label: "period after a word inserts a following space"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: "?", before: "hello"),
    "hello? ",
    label: "question mark inserts a following space"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: "!", before: "hello"),
    "hello! ",
    label: "exclamation mark inserts a following space"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ")", before: "hello "),
    "hello)",
    label: "space before a closing paren collapses"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ",", before: "hello "),
    "hello,",
    label: "space before a comma collapses without adding another"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: "h", before: "\" "),
    "\"h",
    label: "space after an opening quote collapses"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: "h", before: "( "),
    "(h",
    label: "space after an opening paren collapses"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "3"),
    "3.",
    label: "decimal point does not insert a sentence space"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "www", field: .suppressesSentenceSpacing),
    "www.",
    label: "URL fields do not auto-space after a period"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "hello\n"),
    "hello\n.",
    label: "a newline before a period is not eaten"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "ක "),
    "ක. ",
    label: "Sinhala letters collapse space before a period"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: "෴", before: "ක"),
    "ක෴ ",
    label: "kundaliya inserts a following space"
)
expectSpacing(
    SmartPunctuationSpacing.applied(inserting: ".", before: "hello. "),
    "hello..",
    label: "a second period eats the auto-space instead of stacking spaces"
)

if !SmartPunctuationSpacing.hasTrailingSentenceSpace("hello. ") {
    fputs("FAIL spacing trailing sentence space not detected\n", stderr)
    spacingPassed = false
}
if SmartPunctuationSpacing.hasTrailingSentenceSpace("hello ") {
    fputs("FAIL spacing ordinary space is not a sentence space\n", stderr)
    spacingPassed = false
}

guard spacingPassed else { exit(1) }
print("Smart punctuation spacing passed")

let emojiIndexURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaEmojiIndex.json")
guard let emojiIndex = SinhalaEmojiSuggestions.loadIndex(from: emojiIndexURL) else {
    fputs("FAIL emoji index: could not load \(emojiIndexURL.path)\n", stderr)
    exit(1)
}

var emojiPassed = true
func expectEmoji(
    composing: String,
    bestWord: String? = nil,
    contains expected: String,
    label: String
) {
    let actual = SinhalaEmojiSuggestions.emoji(
        forComposing: composing,
        bestWord: bestWord,
        index: emojiIndex
    )
    guard actual.contains(expected) else {
        fputs("FAIL emoji \(label): expected \(expected) in \(actual) for composing=\(composing) best=\(bestWord ?? "nil")\n", stderr)
        emojiPassed = false
        return
    }
    guard actual.count <= 2 else {
        fputs("FAIL emoji \(label): expected at most 2 results, got \(actual)\n", stderr)
        emojiPassed = false
        return
    }
}

func expectNoEmoji(composing: String, bestWord: String? = nil, label: String) {
    let actual = SinhalaEmojiSuggestions.emoji(
        forComposing: composing,
        bestWord: bestWord,
        index: emojiIndex
    )
    guard actual.isEmpty else {
        fputs("FAIL emoji \(label): expected [], got \(actual)\n", stderr)
        emojiPassed = false
        return
    }
}

expectEmoji(composing: "හරි", contains: "👍", label: "හරි → thumbs up")
expectEmoji(composing: "හිනා", contains: "😊", label: "හිනා overlay smile")
expectEmoji(composing: "ආදරෙයි", contains: "❤️", label: "ආදරෙයි overlay heart")
expectEmoji(composing: "ආදරය", contains: "❤️", label: "ආදරය heart")
expectEmoji(composing: "හර", bestWord: "හරි", contains: "👍", label: "prefix of best word")
expectNoEmoji(composing: "", label: "empty prefix")
expectNoEmoji(composing: "ක්ෂ්ම්ප්ට්", label: "unknown word")

let uniqueEmoji = SinhalaEmojiSuggestions.uniqueEmojiCount(index: emojiIndex)
if uniqueEmoji < 200 {
    fputs("FAIL emoji unique count: expected >= 200, got \(uniqueEmoji)\n", stderr)
    emojiPassed = false
}

let hari = SinhalaEmojiSuggestions.emoji(forComposing: "හරි", bestWord: nil, index: emojiIndex)
if hari.count != 2 {
    fputs("FAIL emoji හරි should return two chips, got \(hari)\n", stderr)
    emojiPassed = false
}

guard emojiPassed else { exit(1) }
print("Sinhala emoji suggestions passed (\(uniqueEmoji) unique emoji)")

func expectSkinTone(
    _ emoji: String,
    tone: KeyboardPreferences.EmojiSkinTone,
    expected: String,
    label: String
) {
    let actual = EmojiSkinToneApplicator.withPreferredSkinTone(emoji, tone: tone)
    guard actual == expected else {
        fputs("FAIL skin tone \(label): expected \(expected) scalars=\(expected.unicodeScalars.map { String($0.value, radix: 16) }), got \(actual) scalars=\(actual.unicodeScalars.map { String($0.value, radix: 16) })\n", stderr)
        exit(1)
    }
}

expectSkinTone("👍", tone: .standard, expected: "👍", label: "thumbs up default")
expectSkinTone("👍", tone: .light, expected: "👍🏻", label: "thumbs up light")
expectSkinTone("👍", tone: .dark, expected: "👍🏿", label: "thumbs up dark")
expectSkinTone("👍🏻", tone: .dark, expected: "👍🏿", label: "existing light becomes dark")
expectSkinTone("😀", tone: .dark, expected: "😀", label: "smiley has no modifier")
expectSkinTone("👩‍💻", tone: .light, expected: "👩🏻‍💻", label: "technologist light")

let mixed = EmojiSkinToneApplicator.applyingPreferredSkinTone(
    to: ["👍", "👍🏻", "😀", "👏"],
    tone: .dark
)
guard mixed == ["👍🏿", "😀", "👏🏿"] else {
    fputs("FAIL skin tone catalog: expected [👍🏿, 😀, 👏🏿], got \(mixed)\n", stderr)
    exit(1)
}
print("Emoji skin tone application passed")

let blockedURL = root.appendingPathComponent("Scripts/SinhalaBlockedWords.txt")
let blockedSource = try String(contentsOf: blockedURL, encoding: .utf8)
let blockedWords = Set(
    blockedSource.split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
)
func modelContainsBlockedToken(at url: URL, wordFields: Int) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var hits: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > wordFields else { continue }
        for word in fields.prefix(wordFields) where blockedWords.contains(word) {
            hits.append(word)
        }
    }
    return hits
}
let frequencyHits = try modelContainsBlockedToken(at: frequencyURL, wordFields: 1)
let nextWordHits = try modelContainsBlockedToken(at: nextWordURL, wordFields: 2)
let trigramHits = try modelContainsBlockedToken(at: trigramURL, wordFields: 3)
let sentenceHits = try modelContainsBlockedToken(at: sentenceStartURL, wordFields: 1)
if !frequencyHits.isEmpty || !nextWordHits.isEmpty || !trigramHits.isEmpty || !sentenceHits.isEmpty {
    fputs("FAIL blocked tokens still present in models: frequency=\(frequencyHits) next=\(nextWordHits) trigram=\(trigramHits) sentence=\(sentenceHits)\n", stderr)
    exit(1)
}
print("Blocked suggestion tokens absent from models (\(blockedWords.count) exact tokens)")

// A cancelled request queued behind a busy ranking must never start work.
let rankingQueue = DispatchQueue(label: "prediction-cancellation-test")
let unblockRanking = DispatchSemaphore(value: 0)
let obsolete = PredictionCancellationToken()
let newest = PredictionCancellationToken()
var completedRequests: [String] = []
rankingQueue.async { unblockRanking.wait() }
rankingQueue.async {
    if !obsolete.isCancelled { completedRequests.append("obsolete") }
}
obsolete.cancel()
rankingQueue.async {
    if !newest.isCancelled { completedRequests.append("newest") }
}
unblockRanking.signal()
rankingQueue.sync {}
precondition(completedRequests == ["newest"], "Obsolete ranking was not skipped")
print("Queued prediction cancellation passed")

let cacheSuite = "lk.org.akshara.prediction-cache-test"
let cacheDefaults = UserDefaults(suiteName: cacheSuite)!
cacheDefaults.removePersistentDomain(forName: cacheSuite)
let cacheProvider = SinhalaFrequencyListPredictionProvider(
    modelURL: nil, nextWordURL: nil, trigramURL: nil,
    sentenceStartURL: nil, defaults: cacheDefaults
)
let cacheRequest = SinhalaPredictionRequest(composingText: "ගෙ", precedingWords: [], maximumResults: 3)
precondition(cacheProvider.candidates(for: cacheRequest).isEmpty)
cacheProvider.recordCommittedWord("ගෙදර", after: nil)
let learned = cacheProvider.candidates(for: cacheRequest)
precondition(learned.first?.text == "ගෙදර", "Learning failed to invalidate cached empty result")
precondition(cacheProvider.candidates(for: cacheRequest) == learned)
cacheProvider.recordSelection("ගෙදර", after: nil)
precondition(cacheProvider.candidates(for: cacheRequest)[0].score > learned[0].score,
             "Selection failed to invalidate cached score")
precondition(cacheProvider.candidates(for: .init(composingText: "ගෙ", precedingWords: [], maximumResults: 0)).isEmpty)
cacheProvider.flushPendingPersistence()
cacheDefaults.removePersistentDomain(forName: cacheSuite)
print("Prediction cache learning and result-limit regressions passed")

// Report desktop lookup timings, without imposing hardware-specific thresholds.
let timingRequest = SinhalaPredictionRequest(composingText: "ක", precedingWords: ["එය"], maximumResults: 24)
let uncachedStart = DispatchTime.now().uptimeNanoseconds
let expectedTimingResults = provider.candidates(for: timingRequest)
let uncachedMS = Double(DispatchTime.now().uptimeNanoseconds - uncachedStart) / 1_000_000
let cachedStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<1000 {
    precondition(provider.candidates(for: timingRequest) == expectedTimingResults)
}
let cachedMS = Double(DispatchTime.now().uptimeNanoseconds - cachedStart) / 1_000_000 / 1000
print(String(format: "Desktop lookup timing: uncached %.3f ms; repeated cached mean %.4f ms", uncachedMS, cachedMS))

// English model, casing, context and learning are independent of Sinhala.
let englishSuite = "lk.org.akshara.english-tests.\(UUID().uuidString)"
let englishDefaults = UserDefaults(suiteName: englishSuite)!
let englishStart = DispatchTime.now().uptimeNanoseconds
let english = EnglishPredictionProvider(
    databaseURL: root.appendingPathComponent("AksharaKeyboard/Resources/EnglishPrediction.sqlite3"),
    defaults: englishDefaults)
let constructionMS = Double(DispatchTime.now().uptimeNanoseconds - englishStart) / 1_000_000
let loadStart = DispatchTime.now().uptimeNanoseconds
english.prepareIfNeeded()
let coldMS = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000
func englishCandidates(_ prefix: String, after: [String] = [], limit: Int = 3) -> [String] {
    english.candidates(for: .init(composingText: prefix, precedingWords: after, maximumResults: limit)).map(\.text)
}
precondition(englishCandidates("the").contains("the"))
precondition(englishCandidates("h", after: ["hello"]).contains("how"))
precondition(englishCandidates("", after: ["thank"]).first == "you")
precondition(englishCandidates("").isEmpty)
precondition(englishCandidates("", limit: 0).isEmpty)
precondition(englishCandidates("සිං").isEmpty)
precondition(englishCandidates("don't").isEmpty)
precondition(englishCandidates("The").allSatisfy { $0.first?.isUppercase == true })
precondition(englishCandidates("THE").allSatisfy { $0 == $0.uppercased() })
precondition(english.correction(for: "the") == nil)
precondition(english.correction(for: "don't") == nil)
precondition(english.correction(for: "userName") == nil)
precondition(english.correction(for: "ab") == nil)
let weights = english.nextKeyWeights(latinBuffer: "he", mode: .sls, shifted: false,
    from: [.init(text: "hello", score: 1)], precedingWords: [])
precondition(weights == ["l": 1])
precondition(!english.emoji(for: "happy", bestWord: nil).isEmpty)

let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
let tinyURL = fixtureDirectory.appendingPathComponent("EnglishPrediction.sqlite3")
var tinyHandle: OpaquePointer?
precondition(sqlite3_open(tinyURL.path, &tinyHandle) == SQLITE_OK)
let tinySchema = """
CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE words(word TEXT PRIMARY KEY, rank INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE bigrams(previous TEXT NOT NULL, next TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(previous,next)) WITHOUT ROWID;
CREATE TABLE deletions(deletion TEXT NOT NULL, word TEXT NOT NULL, PRIMARY KEY(deletion,word)) WITHOUT ROWID;
CREATE TABLE emoji(token TEXT NOT NULL, emoji TEXT NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY(token,emoji)) WITHOUT ROWID;
INSERT INTO metadata VALUES('schema_version','1');
INSERT INTO words VALUES('hello',0),('cat',1),('cot',2),('dog',3);
INSERT INTO deletions VALUES
('ello','hello'),('hllo','hello'),('helo','hello'),('hell','hello'),
('at','cat'),('ct','cat'),('ca','cat'),('ot','cot'),('ct','cot'),('co','cot'),
('og','dog'),('dg','dog'),('do','dog');
INSERT INTO emoji VALUES('happy','😊',0);
"""
precondition(sqlite3_exec(tinyHandle, tinySchema, nil, nil, nil) == SQLITE_OK)
// A personal follower outside the SQL top-48 shortlist must retain its
// corpus score when personal learning promotes it into the visible rail.
for index in 0..<50 {
    let word = "filler" + String(UnicodeScalar(97 + index / 26)!) + String(UnicodeScalar(97 + index % 26)!)
    precondition(sqlite3_exec(tinyHandle,
        "INSERT INTO bigrams VALUES('hello','\(word)',100)", nil, nil, nil) == SQLITE_OK)
}
precondition(sqlite3_exec(tinyHandle, "INSERT INTO bigrams VALUES('hello','zorb',10)", nil, nil, nil) == SQLITE_OK)
sqlite3_close(tinyHandle)
let tiny = EnglishPredictionProvider(databaseURL: tinyURL, defaults: englishDefaults)
precondition(tiny.correction(for: "helllo") == "hello")
precondition(tiny.correction(for: "Helllo") == "Hello")
precondition(tiny.correction(for: "HELLLO") == "HELLO")
precondition(tiny.correction(for: "hElllo") == nil)
precondition(tiny.correction(for: "cut") == nil, "Ambiguous typo was corrected")
precondition(tiny.correction(for: "he-lo") == nil)
let learnedRequest = SinhalaPredictionRequest(composingText: "z", precedingWords: [], maximumResults: 3)
precondition(tiny.candidates(for: learnedRequest).isEmpty)
tiny.recordCommittedWord("zorb", after: "hello")
let personalFollower = tiny.candidates(for: .init(composingText: "", precedingWords: ["hello"], maximumResults: 3))
precondition(personalFollower.first?.text == "zorb")
precondition(personalFollower.first!.score > 100_010_000, "SQL shortlist lost the personal follower's corpus score")
precondition(tiny.candidates(for: learnedRequest).first?.text == "zorb")
precondition(tiny.correction(for: "zorb") == nil)
let learnedBefore = tiny.candidates(for: learnedRequest)[0].score
tiny.recordSelection("zorb", after: "hello")
precondition(tiny.candidates(for: learnedRequest)[0].score > learnedBefore)
precondition(tiny.candidates(for: .init(composingText: "z", precedingWords: ["hello"], maximumResults: 3))[0].score > learnedBefore)
tiny.flushPendingPersistence()
precondition(englishDefaults.object(forKey: "prediction.learnedWords.v1") == nil)
let reloaded = EnglishPredictionProvider(databaseURL: nil, defaults: englishDefaults)
precondition(reloaded.candidates(for: learnedRequest).first?.text == "zorb")
let unavailableDefaults = UserDefaults(suiteName: englishSuite + ".empty")!
let unavailable = EnglishPredictionProvider(databaseURL: nil, defaults: unavailableDefaults)
unavailable.flushPendingPersistence()
precondition(unavailableDefaults.object(forKey: "prediction.english.words.v1") == nil,
             "An unchanged model should not write learning data on dismissal")
precondition(unavailable.candidates(for: .init(composingText: "he", precedingWords: ["hello"], maximumResults: 3)).isEmpty)
precondition(unavailable.correction(for: "helllo") == nil)

let middle = EnglishWordContext(before: "hello wor", after: "ld!")
precondition(middle.prefix == "wor" && middle.suffix == "ld" && !middle.canReplace)
precondition(middle.wholeWord == "world" && middle.canReplaceWholeWord)
precondition(!middle.canAutocorrectAtBoundary)
precondition(middle.preceding == ["hello"])
let selectedEnglish = EnglishWordContext(before: "hello", after: "", hasSelection: true)
precondition(!selectedEnglish.canReplace && !selectedEnglish.canReplaceWholeWord)
let middleSinhala = EnglishWordContext(before: "මම සිං", after: "හල ලියමි")
precondition(middleSinhala.prefix == "සිං" && middleSinhala.suffix == "හල")
precondition(middleSinhala.wholeWord == "සිංහල" && middleSinhala.canReplaceWholeWord)
precondition(EnglishWordContext(before: "don't", after: "").prefix == "don't")
precondition(EnglishWordContext(before: "hello සිංහල wor", after: "").preceding.isEmpty)
precondition(EnglishWordContext(before: "hello. wor", after: "").preceding.isEmpty)
precondition(EnglishWordContext(before: "hello", after: "") != EnglishWordContext(before: "x hello", after: ""))

// Restore shared preferences after testing enable/disable and saved-word rules.
do {
    let keys = [KeyboardPreferences.englishKeyboardKey, KeyboardPreferences.activeLanguageKey,
                KeyboardPreferences.layoutKey, KeyboardPreferences.autocorrectProtectedWordsKey,
                KeyboardPreferences.autocorrectReversalCountsKey]
    let original = Dictionary(uniqueKeysWithValues: keys.map { ($0, KeyboardPreferences.defaults.object(forKey: $0)) })
    defer {
        for key in keys {
            if let value = original[key] ?? nil { KeyboardPreferences.defaults.set(value, forKey: key) }
            else { KeyboardPreferences.defaults.removeObject(forKey: key) }
        }
        KeyboardPreferences.refreshHotPathCache()
    }
    keys.forEach { KeyboardPreferences.defaults.removeObject(forKey: $0) }
    precondition(!KeyboardPreferences.englishKeyboardEnabled())
    precondition(KeyboardPreferences.activeLanguage() == .sinhala)
    for mode in SinhalaEngine.Mode.allCases {
        KeyboardPreferences.setSelectedMode(mode)
        KeyboardPreferences.setEnglishKeyboardEnabled(true)
        KeyboardPreferences.setActiveLanguage(.english)
        KeyboardPreferences.reload()
        precondition(KeyboardPreferences.activeLanguage() == .english)
        precondition(KeyboardPreferences.selectedMode() == mode)
        KeyboardPreferences.setEnglishKeyboardEnabled(false)
        precondition(KeyboardPreferences.activeLanguage() == .sinhala)
        KeyboardPreferences.setEnglishKeyboardEnabled(true)
        precondition(KeyboardPreferences.activeLanguage() == .sinhala)
    }
    KeyboardPreferences.protectFromAutocorrect("HeLlLo")
    precondition(KeyboardPreferences.isAutocorrectProtected("HELLLO"))
    precondition(tiny.correction(for: "Helllo") == nil)
    KeyboardPreferences.removeAutocorrectProtection("helllo")
    precondition(tiny.correction(for: "Helllo") == "Hello")
    for _ in 0..<3 { KeyboardPreferences.recordAutocorrectionReversal(for: "HeLlLo") }
    precondition(tiny.correction(for: "helllo") == nil)
}
let warmStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<1000 { _ = englishCandidates("hel", after: ["say"]) }
let warmMS = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000 / 1000
print(String(format: "English desktop timing: construction %.3f ms, cold load %.3f ms, repeated lookup %.4f ms", constructionMS, coldMS, warmMS))
print("English resources, correction, context, casing, learning isolation, preferences and protection passed")
tiny.flushPendingPersistence()
englishDefaults.removePersistentDomain(forName: englishSuite)
unavailableDefaults.removePersistentDomain(forName: englishSuite + ".empty")
try FileManager.default.removeItem(at: fixtureDirectory)

for isPad in [false, true] {
    for emoji in [false, true] {
        for language in [false, true] {
            for globe in [false, true] {
                for punctuation in [[], ["@", "."]] as [[String]] {
                    let keys = KeyboardBottomRow.keys(isPad: isPad, emoji: emoji, language: language, globe: globe, punctuation: punctuation)
                    if language { precondition(keys[1] == "language") }
                    if language && emoji { precondition(keys[2] == "emoji") }
                    for width: CGFloat in [256, 320, 393, 402, 600, 1024] {
                        let gap: CGFloat = 6
                        let small: CGFloat = isPad ? 60 : 44
                        let enter: CGFloat = 94
                        let scale = KeyboardBottomRow.controlScale(keys: keys, availableWidth: width, gap: gap, smallWidth: small, returnWidth: enter)
                        let budget = width - CGFloat(keys.count - 1) * gap
                        let controls = keys.reduce(CGFloat.zero) { $0 + ($1 == "space" ? 0 : $1 == "return" ? enter : small) * scale }
                        precondition(budget - controls >= budget * 0.32 - 0.001, "Space was squeezed by bottom controls")
                        precondition(scale > 0 && scale <= 1)
                    }
                }
            }
        }
    }
}
print("Bottom-row key order and Space width budgets passed (phone, iPad, one-handed, URL, optional keys)")

// Explicit suggestion separators participate in two *physical* Space taps.
for word in ["hello", "සිංහල"] {
    let before = word + " "
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: true,
        suggestionSpacePending: true, lastTap: nil, now: 10, periodEnabled: true) == .useSuggestionSpace)
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: true,
        suggestionSpacePending: false, lastTap: 10, now: 10.2, periodEnabled: true) == .replaceWithPeriod)
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: true,
        suggestionSpacePending: false, lastTap: 10, now: 11, periodEnabled: true) == .insert)
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: true, compositionIsIdle: true,
        suggestionSpacePending: true, lastTap: 10, now: 10.2, periodEnabled: true) == .insert)
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: false,
        suggestionSpacePending: false, lastTap: 10, now: 10.2, periodEnabled: true) == .insert)
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: true,
        suggestionSpacePending: false, lastTap: 10, now: 10.2, periodEnabled: false) == .insert)
}
for before in ["", " ", "hello", "hello  ", "hello. ", "hello! ", "hello\n"] {
    precondition(KeyboardSpaceAction.resolve(before: before, hasSelection: false, compositionIsIdle: true,
        suggestionSpacePending: false, lastTap: 10, now: 10.2, periodEnabled: true) == .insert)
}
precondition(KeyboardSpaceAction.resolve(before: "“hello” ", hasSelection: false, compositionIsIdle: true,
    suggestionSpacePending: false, lastTap: 10, now: 10.2, periodEnabled: true) == .replaceWithPeriod)
for before in ["", " ", "Hello. ", "Hello!  ", "Hello? ", "Hello\n", "Hello\n  ", "“", "Hello. “"] {
    precondition(EnglishCapitalization.shouldShift(before: before, mode: .sentences), "Missing sentence capital: \(before)")
}
for before in ["h", "hello ", "example.", "Hello. w", "don't "] {
    precondition(!EnglishCapitalization.shouldShift(before: before, mode: .sentences), "Unexpected sentence capital: \(before)")
}
precondition(!EnglishCapitalization.shouldShift(before: "", mode: .none))
precondition(EnglishCapitalization.shouldShift(before: "hello ", mode: .words))
precondition(!EnglishCapitalization.shouldShift(before: "hello", mode: .words))
precondition(EnglishCapitalization.shouldShift(before: "hello", mode: .allCharacters))
print("Sinhala/English suggestion spacing, double-space period, and English capitalization passed")

for (before, after, replacement, expected) in [
    ("hello wor", "ld again", "world ", "hello world again"),
    ("hello wor", "ld", "world ", "hello world "),
    ("hello world", " again", "word ", "hello word again"),
    ("මම සිං", "හල ලියමි", "සිංහල ", "මම සිංහල ලියමි")
] {
    let context = EnglishWordContext(before: before, after: after)
    let span = context.replacementSpan(for: replacement)
    let left = before + after.prefix(span.advance)
    precondition(left.hasSuffix(span.text))
    let result = left.dropLast(span.text.count) + replacement + after.dropFirst(span.advance)
    precondition(result == expected, "Suggestion replacement damaged adjacent text: \(result)")
}
print("Suggestion replacement preserves adjacent words and reuses existing separators")
