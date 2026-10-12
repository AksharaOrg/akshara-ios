import Foundation

/// Port of Android PR #7 / Sinhala Phonetic Orthography. See Docs/Smart-Phonetic-V2.md.
struct SmartPhoneticConfiguration: Hashable {
    var enabled = true
    var options = SmartPhoneticV2.Options()
    static let classic = Self(enabled: false)
}

enum SmartPhoneticV2 {
    struct Options: Hashable {
        var archaic = false
        var repayaZwj = false
        var classical = false
        var rakaransayaU = false
    }

    private enum Token {
        case consonant(String, String)
        case vowel(String, String, String)
        case mark(String, String)
        case touch
        case literal(UnicodeScalar)
        var consonant: String? { if case .consonant(let letter, _) = self { return letter }; return nil }
    }
    private enum State { case vowel, anusvara, hal }
    private static let hal = "්", zwj = "\u{200D}"
    private static let sanyaka: Set<String> = ["ඟ", "ඦ", "ඬ", "ඳ", "ඹ"]
    private static let noHal = sanyaka.union(["ළ"])
    private static let plain = ["ඟ": "ග", "ඦ": "ජ", "ඬ": "ඩ", "ඳ": "ද", "ඹ": "බ"]
    private static let plainBeforeRa: Set<String> = ["ම", "න", "ල"]
    private static let velars: Set<String> = ["ක", "ඛ", "ග", "ඝ"]
    private static let front: Set<String> = ["i", "ii", "e", "ee", "ae", "aee", "ai"]
    private static let back: Set<String> = ["u", "uu", "o", "oo", "au"]
    private static let gaetta = ["u": "ෘ", "uu": "ෲ"]
    private static let gaettaAfter: [String: Set<String>] = [
        "u": Set("කගඝජටඩතදධනපබභමවශසහෆ".unicodeScalars.map(String.init)),
        "uu": Set("කගටඩතදපබම".unicodeScalars.map(String.init))
    ]
    static let bandi: Set<String> = ["කෂ", "කව", "ගධ", "ටඨ", "තථ", "තව", "දධ",
                                   "දව", "නථ", "නද", "නධ", "නව", "ඤච"]
    private static let sequences: [(String, Bool, Token)] = [
        ("k", false, .consonant("ක", "k")),
        ("c", false, .consonant("ක", "c")),
        ("kh", false, .consonant("ඛ", "kh")),
        ("K", false, .consonant("ඛ", "K")),
        ("C", false, .consonant("ඛ", "C")),
        ("g", false, .consonant("ග", "g")),
        ("gh", false, .consonant("ඝ", "gh")),
        ("G", false, .consonant("ඝ", "G")),
        ("X", false, .consonant("ඞ", "X")),
        ("zg", false, .consonant("ඟ", "zg")),
        ("ch", false, .consonant("ච", "ch")),
        ("chh", false, .consonant("ඡ", "chh")),
        ("j", false, .consonant("ජ", "j")),
        ("jh", false, .consonant("ඣ", "jh")),
        ("J", false, .consonant("ඣ", "J")),
        ("zk", false, .consonant("ඤ", "zk")),
        ("zh", false, .consonant("ඥ", "zh")),
        ("zj", true, .consonant("ඦ", "zj")),
        ("t", false, .consonant("ට", "t")),
        ("T", false, .consonant("ඨ", "T")),
        ("D", false, .consonant("ඩ", "D")),
        ("Dh", false, .consonant("ඪ", "Dh")),
        ("N", false, .consonant("ණ", "N")),
        ("zD", false, .consonant("ඬ", "zD")),
        ("th", false, .consonant("ත", "th")),
        ("thh", false, .consonant("ථ", "thh")),
        ("d", false, .consonant("ද", "d")),
        ("q", false, .consonant("ද", "q")),
        ("dh", false, .consonant("ධ", "dh")),
        ("dhh", false, .consonant("ධ", "dhh")),
        ("n", false, .consonant("න", "n")),
        ("zd", false, .consonant("ඳ", "zd")),
        ("zdh", false, .consonant("ඳ", "zdh")),
        ("zq", false, .consonant("ඳ", "zq")),
        ("p", false, .consonant("ප", "p")),
        ("ph", false, .consonant("ඵ", "ph")),
        ("P", false, .consonant("ඵ", "P")),
        ("b", false, .consonant("බ", "b")),
        ("bh", false, .consonant("භ", "bh")),
        ("m", false, .consonant("ම", "m")),
        ("B", false, .consonant("ඹ", "B")),
        ("y", false, .consonant("ය", "y")),
        ("r", false, .consonant("ර", "r")),
        ("l", false, .consonant("ල", "l")),
        ("w", false, .consonant("ව", "w")),
        ("v", false, .consonant("ව", "v")),
        ("W", false, .consonant("ව", "W")),
        ("V", false, .consonant("ව", "V")),
        ("sh", false, .consonant("ශ", "sh")),
        ("Sh", false, .consonant("ෂ", "Sh")),
        ("S", false, .consonant("ෂ", "S")),
        ("s", false, .consonant("ස", "s")),
        ("h", false, .consonant("හ", "h")),
        ("L", false, .consonant("ළ", "L")),
        ("f", false, .consonant("ෆ", "f")),
        ("a", false, .vowel("a", "අ", "")),
        ("aa", false, .vowel("aa", "ආ", "ා")),
        ("A", false, .vowel("ae", "ඇ", "ැ")),
        ("ae", false, .vowel("ae", "ඇ", "ැ")),
        ("Aa", false, .vowel("aee", "ඈ", "ෑ")),
        ("AA", false, .vowel("aee", "ඈ", "ෑ")),
        ("aee", false, .vowel("aee", "ඈ", "ෑ")),
        ("i", false, .vowel("i", "ඉ", "ි")),
        ("ii", false, .vowel("ii", "ඊ", "ී")),
        ("I", false, .vowel("ii", "ඊ", "ී")),
        ("u", false, .vowel("u", "උ", "ු")),
        ("U", false, .vowel("u", "උ", "ු")),
        ("uu", false, .vowel("uu", "ඌ", "ූ")),
        ("UU", false, .vowel("uu", "ඌ", "ූ")),
        ("Uu", false, .vowel("uu", "ඌ", "ූ")),
        ("R", false, .vowel("ru", "ඍ", "ෘ")),
        ("RR", false, .vowel("ruu", "ඎ", "ෲ")),
        ("e", false, .vowel("e", "එ", "ෙ")),
        ("ee", false, .vowel("ee", "ඒ", "ේ")),
        ("E", false, .vowel("ai", "ඓ", "ෛ")),
        ("o", false, .vowel("o", "ඔ", "ො")),
        ("O", false, .vowel("o", "ඔ", "ො")),
        ("oo", false, .vowel("oo", "ඕ", "ෝ")),
        ("OO", false, .vowel("oo", "ඕ", "ෝ")),
        ("Oo", false, .vowel("oo", "ඕ", "ෝ")),
        ("Au", false, .vowel("au", "ඖ", "ෞ")),
        ("AU", false, .vowel("au", "ඖ", "ෞ")),
        ("~l", true, .vowel("ilu", "ඏ", "ෟ")),
        ("~ll", true, .vowel("iluu", "ඐ", "ෳ")),
        ("x", false, .mark("ං", "x")),
        ("zn", false, .mark("ං", "zn")),
        ("M", false, .mark("ං", "M")),
        ("H", false, .mark("ඃ", "H")),
        ("~n", true, .mark("ඁ", "~n")),
        ("+", true, .touch)
    ]
    // Preserve source table order for equal-length sequences.
    private static let normal = sortedSequences(archaic: false)
    private static let archaic = sortedSequences(archaic: true)
    private static func sortedSequences(archaic: Bool) -> [(String, Bool, Token)] {
        sequences.enumerated().filter { archaic || !$0.element.1 }.sorted {
            $0.element.0.count == $1.element.0.count ? $0.offset < $1.offset : $0.element.0.count > $1.element.0.count
        }.map(\.element)
    }
    private static func tokenize(_ source: String, archaic: Bool) -> [Token] {
        let scalars = source.unicodeScalars
        var index = scalars.startIndex
        var tokens: [Token] = []
        let table = archaic ? self.archaic : normal
        while index < scalars.endIndex {
            if let match = table.first(where: { scalars[index...].starts(with: $0.0.unicodeScalars) }) {
                tokens.append(match.2)
                index = scalars.index(index, offsetBy: match.0.unicodeScalars.count)
            } else {
                if scalars[index] != "z" { tokens.append(.literal(scalars[index])) }
                index = scalars.index(after: index)
            }
        }
        return tokens
    }
    private static func glide(_ previous: String?, _ vowel: String) -> String {
        if let previous, front.contains(previous) { return "ය" }
        if let previous, back.contains(previous) { return "ව" }
        return front.contains(vowel) ? "ය" : "ව"
    }

    static func transliterate(_ source: String, options: Options = .init()) -> String {
        let tokens = tokenize(source, archaic: options.archaic)
        var out: [String] = [], state: State?, previousVowel: String?
        var j = 0
        while j < tokens.count {
            let next = j + 1 < tokens.count ? tokens[j + 1] : nil
            let after = j + 2 < tokens.count ? tokens[j + 2] : nil
            switch tokens[j] {
            case .consonant(let original, let seq):
                var letter = state == nil ? plain[original] ?? original : original
                if letter == "ඞ" {
                    if state == nil { out.append(seq); j += 1; continue }
                    if case .vowel? = next { letter = "ඟ" }
                }
                if letter == "න", seq == "n", state == .vowel,
                   let nextLetter = next?.consonant, velars.contains(nextLetter) {
                    out.append("ං"); state = .anusvara
                    if case .consonant(_, "g")? = next {
                        if after == nil { j += 2; continue }
                        if case .literal? = after { j += 2; continue }
                    }
                    j += 1; continue
                }
                out.append(letter)
                switch next {
                case .vowel(let id, _, let sign):
                    out.append(sign); state = .vowel; previousVowel = id; j += 2
                case .mark:
                    state = .vowel; previousVowel = "a"; j += 1
                case .consonant(let nextLetter, _):
                    if noHal.contains(letter) || sanyaka.contains(nextLetter) {
                        state = .vowel; previousVowel = "a"; j += 1; continue
                    }
                    var afterVowel: String?
                    if case .vowel(let id, _, _)? = after { afterVowel = id }
                    let ru = afterVowel.flatMap { gaetta[$0] } != nil
                    let attested = afterVowel.flatMap { gaettaAfter[$0] }?.contains(letter) == true
                    if letter != "ඞ", letter != "ර", nextLetter == "ර", attested, !options.rakaransayaU {
                        out.append(gaetta[afterVowel!]!); state = .vowel
                        previousVowel = afterVowel; j += 3; continue
                    }
                    let join: Bool
                    if letter == "ඞ" { join = false }
                    else if nextLetter == "ය" { join = letter != "ර" || options.repayaZwj }
                    else if nextLetter == "ර" {
                        join = letter != "ර" && !(plainBeforeRa.contains(letter) && !attested && !(options.classical && !ru))
                    } else if letter == "ර" { join = options.repayaZwj }
                    else { join = options.classical && bandi.contains(letter + nextLetter) }
                    out.append(hal + (join ? zwj : "")); state = .hal; j += 1
                case .touch where after?.consonant != nil && !noHal.contains(letter):
                    out.append(zwj + hal); state = .hal; j += 2
                default:
                    if noHal.contains(letter) { state = .vowel; previousVowel = "a" }
                    else { out.append(hal); state = .hal }
                    j += 1
                }
            case .vowel(let id, let independent, let sign):
                switch state {
                case .vowel: out.append(glide(previousVowel, id) + sign)
                case .anusvara: out[out.count - 1] = "ම" + sign
                default: out.append(id == "ruu" && !options.archaic ? "ඍ" : independent)
                }
                state = .vowel; previousVowel = id; j += 1
            case .mark(let output, let seq):
                if output == "ං", let letter = next?.consonant, sanyaka.contains(letter) { j += 1; continue }
                if state == .vowel { out.append(output); state = output == "ං" ? .anusvara : .vowel }
                else { out.append(seq); state = nil }
                j += 1
            case .touch: out.append("+"); state = nil; j += 1
            case .literal(let scalar): out.append(String(scalar)); state = nil; previousVowel = nil; j += 1
            }
        }
        return out.joined()
    }
}

