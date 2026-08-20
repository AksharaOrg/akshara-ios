import Foundation

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
