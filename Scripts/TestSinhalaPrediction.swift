import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtureURL = root.appendingPathComponent("Scripts/SinhalaPredictionFixture.tsv")
let frequencyURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaFrequencyModel.tsv")
let nextWordURL = root.appendingPathComponent("AksharaKeyboard/Resources/SinhalaNextWordModel.tsv")
let suiteName = "lk.org.akshara.prediction-fixture"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)

let provider = SinhalaFrequencyListPredictionProvider(
    modelURL: frequencyURL,
    nextWordURL: nextWordURL,
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
    let precedingWords = fields[1].isEmpty ? [] : [String(fields[1])]
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
