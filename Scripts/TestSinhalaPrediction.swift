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
