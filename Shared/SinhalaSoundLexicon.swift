import Foundation

/// Sound-key lookup and option styling, ported from Sinhala Phonetic Orthography's lexicon.py.
final class SinhalaSoundLexicon {
    private(set) var counts: [String: Int] = [:]
    private var byKey: [String: [String]] = [:]
    private var keys: [String] = []

    init(rows: [(String, Int)]) {
        let repair = !rows.contains { $0.0.unicodeScalars.contains("\u{200D}") }
        for (word, count) in rows where !word.isEmpty {
            counts[repair ? Self.normalize(word) : word, default: 0] += count
        }
        for word in counts.keys { byKey[Self.soundKey(word), default: []].append(word) }
        keys = byKey.keys.sorted(by: Self.scalarLess)
    }

    func exact(_ key: String) -> [String] { byKey[key] ?? [] }

    func dictionaryWord(for styled: String, options: SmartPhoneticV2.Options) -> String {
        if counts[styled] != nil { return styled }
        return exact(Self.soundKey(styled)).filter { Self.restyle($0, options: options) == styled }
            .max { counts[$0, default: 0] < counts[$1, default: 0] } ?? styled
    }
    func prefix(_ key: String, limit: Int = 200) -> [String] {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if Self.scalarLess(keys[mid], key) { low = mid + 1 } else { high = mid }
        }
        var out: [String] = [], i = low
        while i < keys.count, SinhalaEngine.hasUnicodeScalarPrefix(keys[i], key), out.count < limit {
            out += byKey[keys[i]] ?? []; i += 1
        }
        return out
    }

    func candidates(_ roman: String, limit: Int = 5, partial: Bool = false,
                    options: SmartPhoneticV2.Options = .init()) -> [String] {
        guard limit > 0 else { return [] }
        let spelled = SmartPhoneticV2.transliterate(roman, options: options)
        let key = Self.soundKey(spelled)
        let lookup = partial ? prefix(Self.withoutTrailingHal(key)) : exact(key)
        let ranked = Set(lookup).sorted {
            counts[$0, default: 0] == counts[$1, default: 0]
                ? Self.scalarLess($0, $1) : counts[$0, default: 0] > counts[$1, default: 0]
        }
        var seen = Set<String>()
        var styled = ranked.map { Self.restyle($0, options: options) }.filter { seen.insert($0).inserted }
        if !partial {
            if Self.isExplicit(roman), styled.contains(spelled) || Self.isLoneVowel(spelled) {
                styled.removeAll { $0 == spelled }; styled.insert(spelled, at: 0)
            } else if !styled.contains(spelled) { styled.append(spelled) }
        }
        return Array(styled.prefix(limit))
    }

    static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }
    static func withoutTrailingHal(_ text: String) -> String {
        guard text.unicodeScalars.last == "්" else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.dropLast()))
    }
    private static let explicit = try! NSRegularExpression(pattern: "[KCGJTDNLPBSWVUIEOAXRMH]|z[a-zA-Z]|aa|ii|uu|ee|oo|ae|thh|dh|kh|gh|chh|jh|ph|bh|x")
    static func isExplicit(_ roman: String) -> Bool {
        explicit.firstMatch(in: roman, range: NSRange(roman.startIndex..., in: roman)) != nil
    }
    static func isLoneVowel(_ text: String) -> Bool {
        text.unicodeScalars.count == 1 && text.unicodeScalars.first.map { (0x0D85...0x0D96).contains($0.value) } == true
    }
    private static func consonant(_ scalar: UnicodeScalar) -> Bool { (0x0D9A...0x0DC6).contains(scalar.value) }
    static func normalize(_ word: String) -> String {
        let s = Array(word.unicodeScalars)
        var out = String.UnicodeScalarView()
        for i in s.indices {
            out.append(s[i])
            if s[i] == "්", i > 0, i + 1 < s.count, consonant(s[i - 1]),
               s[i + 1] == "ය" || s[i + 1] == "ර",
               s[i - 1] != "ර", !(s[i + 1] == "ර" && "මනල".unicodeScalars.contains(s[i - 1])) {
                out.append("\u{200D}")
            }
        }
        return String(out)
    }
    private static let foldSequences = [
        ("ෛ", "යි"), ("ඓ", "අයි"), ("ෞ", "වු"), ("ඖ", "අවු"),
        ("ෘ", "්රු"), ("ෲ", "්රු"), ("ඍ", "රු"), ("ඎ", "රු"),
        ("ඥ", "ග්න"), ("ඟ", "න්ග"), ("ඦ", "න්ජ"), ("ඬ", "න්ද"),
        ("ඳ", "න්ද"), ("ඹ", "ම්බ"), ("ං", "න්"), ("ඞ්", "න්")
    ]
    private static let foldChars: [UnicodeScalar: String] = [
        "ඛ": "ක", "ඝ": "ග", "ඡ": "ච", "ඣ": "ජ", "ඨ": "ට", "ඪ": "ද", "ථ": "ත", "ධ": "ද",
        "ඵ": "ප", "භ": "බ", "ඩ": "ද", "ණ": "න", "ළ": "ල", "ශ": "ස", "ෂ": "ස", "ඤ": "න",
        "ආ": "අ", "ඊ": "ඉ", "ඌ": "උ", "ඒ": "එ", "ඕ": "ඔ", "ඇ": "එ", "ඈ": "එ",
        "ා": "", "ී": "ි", "ූ": "ු", "ේ": "ෙ", "ෝ": "ො", "ැ": "ෙ", "ෑ": "ෙ", "\u{200D}": ""
    ]
    private static let foldedScalars: [UnicodeScalar: String] = {
        var folds = foldChars
        for (from, to) in foldSequences where from.unicodeScalars.count == 1 {
            folds[from.unicodeScalars.first!] = to.unicodeScalars.map { foldChars[$0] ?? String($0) }.joined()
        }
        return folds
    }()

    static func soundKey(_ text: String) -> String {
        // The reference's ordered substitutions never create another sequence to fold.
        // One scalar pass avoids repeatedly allocating the complete string for every table row.
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView(), i = 0
        while i < scalars.count {
            if scalars[i] == "ඞ", i + 1 < scalars.count, scalars[i + 1] == "්" {
                result.append(contentsOf: "න්".unicodeScalars); i += 2
            } else {
                if let folded = foldedScalars[scalars[i]] { result.append(contentsOf: folded.unicodeScalars) }
                else { result.append(scalars[i]) }
                i += 1
            }
        }
        return String(result)
    }

    static func restyle(_ word: String, options: SmartPhoneticV2.Options) -> String {
        var out = word
        if options.rakaransayaU {
            let s = Array(out.unicodeScalars)
            var styled = ""
            for i in s.indices {
                if (s[i] == "ෘ" || s[i] == "ෲ"), i > 0, consonant(s[i - 1]), s[i - 1] != "ර" {
                    styled += "්\u{200D}ර" + (s[i] == "ෘ" ? "ු" : "ූ")
                } else { styled.unicodeScalars.append(s[i]) }
            }
            out = styled
        }
        if options.repayaZwj || options.classical {
            let s = Array(out.unicodeScalars)
            var styled = ""
            for i in s.indices {
                styled.unicodeScalars.append(s[i])
                guard s[i] == "්", i > 0, i + 1 < s.count, consonant(s[i - 1]), consonant(s[i + 1]) else { continue }
                if options.repayaZwj && s[i - 1] == "ර"
                    || options.classical && SmartPhoneticV2.bandi.contains(String(s[i - 1]) + String(s[i + 1])) {
                    styled += "\u{200D}"
                }
            }
            out = styled
        }
        return out
    }
}

