import Foundation

/// Stateless, local-only transliteration used by both the host app and keyboard extension.
enum SinhalaEngine {
    enum Mode: String, CaseIterable, Identifiable {
        case sls = "Wijesekara"
        case phonetic = "Phonetic"
        case smartPhonetic = "Smart Phonetic"

        var id: String { rawValue }
    }

    private static let consonants: [(String, String)] = [
        ("ng", "ඞ"), ("gn", "ඥ"), ("ny", "ඤ"), ("kh", "ඛ"), ("gh", "ඝ"),
        ("ch", "ඡ"), ("jh", "ඣ"), ("Th", "ඨ"), ("Dh", "ඪ"), ("th", "ත"),
        ("dh", "ද"), ("ph", "ඵ"), ("bh", "භ"), ("sh", "ශ"), ("Sh", "ෂ"),
        ("k", "ක"), ("g", "ග"), ("c", "ච"), ("j", "ජ"), ("T", "ට"), ("D", "ඩ"),
        ("N", "ණ"), ("t", "ට"), ("d", "ඩ"), ("n", "න"), ("p", "ප"), ("b", "බ"),
        ("m", "ම"), ("y", "ය"), ("r", "ර"), ("l", "ල"), ("L", "ළ"), ("v", "ව"),
        ("w", "ව"), ("s", "ස"), ("h", "හ"), ("f", "ෆ"), ("R", "ර"), ("Y", "ය")
    ]
    private static let vowels: [(String, String, String)] = [
        ("aee", "ඈ", "ෑ"), ("ae", "ඇ", "ැ"), ("aa", "ආ", "ා"), ("ii", "ඊ", "ී"),
        ("uu", "ඌ", "ූ"), ("ee", "ඒ", "ේ"), ("ai", "ඓ", "ෛ"), ("oo", "ඕ", "ෝ"),
        ("au", "ඖ", "ෞ"), ("A", "ආ", "ා"), ("I", "ඊ", "ී"), ("U", "ඌ", "ූ"),
        ("E", "ඒ", "ේ"), ("O", "ඕ", "ෝ"), ("a", "අ", ""), ("i", "ඉ", "ි"),
        ("u", "උ", "ු"), ("e", "එ", "ෙ"), ("o", "ඔ", "ො")
    ]

    private static let smartConsonants: [(String, String)] = [
        ("chh", "ඡ"), ("thh", "ථ"), ("dhh", "ධ"), ("zdh", "ඳ"),
        ("ch", "ච"), ("th", "ත"), ("dh", "ද"), ("sh", "ශ"), ("Sh", "ෂ"),
        ("kh", "ඛ"), ("gh", "ඝ"), ("ph", "ඵ"), ("bh", "භ"),
        ("zg", "ඟ"), ("zj", "ඦ"), ("zd", "ඬ"), ("zq", "ඳ"),
        ("zk", "ඤ"), ("zh", "ඥ"), ("k", "ක"), ("g", "ග"), ("j", "ජ"),
        ("t", "ට"), ("d", "ඩ"), ("q", "ද"), ("n", "න"), ("N", "ණ"),
        ("p", "ප"), ("b", "බ"), ("m", "ම"), ("y", "ය"), ("r", "ර"),
        ("l", "ල"), ("L", "ළ"), ("w", "ව"), ("v", "ව"), ("s", "ස"),
        ("S", "ෂ"), ("h", "හ"), ("f", "ෆ"), ("T", "ඨ"), ("D", "ඪ"),
        ("B", "ඹ"), ("X", "ඞ")
    ]
    private static let smartVowels: [(String, String, String?)] = [
        ("ruu", "", "ෲ"), ("Aa", "ඈ", "ෑ"), ("AA", "ඈ", "ෑ"),
        ("aa", "ආ", "ා"), ("ii", "ඊ", "ී"), ("uu", "ඌ", "ූ"),
        ("ee", "ඒ", "ේ"), ("ai", "ඓ", "ෛ"), ("oo", "ඕ", "ෝ"),
        ("au", "ඖ", "ෞ"), ("ou", "ඖ", "ෞ"), ("Ru", "ඎ", nil),
        ("ru", "", "ෘ"), ("A", "ඇ", "ැ"), ("I", "", nil),
        ("U", "", nil), ("E", "", nil), ("O", "", nil), ("a", "අ", ""),
        ("i", "ඉ", "ි"), ("u", "උ", "ු"), ("e", "එ", "ෙ"),
        ("o", "ඔ", "ො"), ("R", "ඍ", nil)
    ]

    // SLS 1134 / Wijesekara keyboard layer. Values may include private-use
    // composition tokens, which are consumed by `normalizeSLS` before text is
    // committed to the document.
    private static let join = "\u{E000}", touch = "\u{E001}", repaya = "\u{E002}"
    private static let sanyakaya = "\u{E003}", rakaransaya = "\u{E004}", yansaya = "\u{E005}"
    private static let slsNormal: [String: String] = [
        "`": rakaransaya, "q": "ු", "w": "අ", "e": "ැ", "r": "ර", "t": "එ", "y": "හ", "u": "ම", "i": "ස", "o": "ද", "p": "ච", "[": "ඤ", "]": ";", "\\": join,
        "a": "්", "s": "ි", "d": "ා", "f": "ෙ", "g": "ට", "h": "ය", "j": "ව", "k": "න", "l": "ක", ";": "ත", "'": ".",
        "z": "'", "x": "ං", "c": "ජ", "v": "ඩ", "b": "ඉ", "n": "බ", "m": "ප", ",": "ල", ".": "ග", "/": "/"
    ]
    private static let slsShift: [String: String] = [
        "~": repaya, "Q": "ූ", "W": "උ", "E": "ෑ", "R": "ඍ", "T": "ඔ", "Y": "ශ", "U": "ඹ", "I": "ෂ", "O": "ධ", "P": "ඡ", "{": "ඥ", "}": ":", "|": touch,
        "A": "ෟ", "S": "ී", "D": "ෘ", "F": "ෆ", "G": "ඨ", "H": yansaya, "J": "ළු", "K": "ණ", "L": "ඛ", ":": "ථ", "\"": ",",
        "Z": "\"", "X": "ඞ", "C": "ඣ", "V": "ඪ", "B": "ඊ", "N": "භ", "M": "ඵ", "<": "ළ", ">": "ඝ", "?": "?"
    ]

    static func slsCharacter(for key: String, shifted: Bool) -> String {
        let shiftedSymbols: [String: String] = [
            "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"
        ]
        let lookup = shifted ? (shiftedSymbols[key] ?? key.uppercased()) : key.lowercased()
        return (shifted ? slsShift[lookup] : slsNormal[lookup]) ?? key
    }

    static func slsKeyLabel(_ key: String, shifted: Bool) -> String {
        let mapped = slsCharacter(for: key, shifted: shifted)
        return mapped.unicodeScalars.allSatisfy { $0.value < 0xE000 || $0.value > 0xE0FF } ? mapped : ""
    }

    /// Produces Unicode-order Sinhala from the visual Wijesekara entry order.
    /// This covers the normal/shift layers and the key pre-base vowel sequences.
    static func normalizeSLS(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var i = 0
        func isConsonant(_ scalar: UnicodeScalar) -> Bool { (0x0D9A...0x0DC6).contains(scalar.value) }
        while i < scalars.count {
            let scalar = scalars[i]
            // Independent-vowel key sequences are composed just as they are
            // in the desktop Wijesekara engine (for example අා -> ආ).
            if (0x0D85...0x0D96).contains(scalar.value) {
                let next = i + 1 < scalars.count ? scalars[i + 1].value : nil
                let combined: String?
                switch (scalar.value, next) {
                case (0x0D85, 0x0DCF): combined = "ආ"
                case (0x0D85, 0x0DD0): combined = "ඇ"
                case (0x0D85, 0x0DD1): combined = "ඈ"
                case (0x0D91, 0x0DCA): combined = "ඒ"
                case (0x0D89, 0x0DD3): combined = "ඊ"
                case (0x0D94, 0x0DCA): combined = "ඕ"
                case (0x0D94, 0x0DDF), (0x0D94, 0x0DD6): combined = "ඖ"
                case (0x0D8B, 0x0DDF), (0x0D8B, 0x0DD6): combined = "ඌ"
                case (0x0D8D, 0x0DD8): combined = "ඎ"
                default: combined = nil
                }
                if let combined {
                    output += combined
                    i += 2
                } else {
                    output.unicodeScalars.append(scalar)
                    i += 1
                }
                continue
            }
            // Kombuwa is entered before its consonant in Wijesekara.
            if scalar.value == 0x0DD9 {
                var prefixes = 0
                while i < scalars.count && scalars[i].value == 0x0DD9 { prefixes += 1; i += 1 }
                guard i < scalars.count, isConsonant(scalars[i]) else {
                    output += String(repeating: "ෙ", count: prefixes)
                    continue
                }
                output.unicodeScalars.append(scalars[i]); i += 1
                if prefixes >= 2 { output += "ෛ" }
                else if i < scalars.count {
                    switch scalars[i].value {
                    case 0x0DCA: output += "ේ"; i += 1
                    case 0x0DCF:
                        i += 1
                        if i < scalars.count, scalars[i].value == 0x0DCA { output += "ෝ"; i += 1 } else { output += "ො" }
                    case 0x0DDF: output += "ෞ"; i += 1
                    default: output += "ෙ"
                    }
                } else { output += "ෙ" }
                continue
            }
            // Direct combining marks follow their base in the output.
            if scalar.value == 0xE004 { output += "්‍ර"; i += 1; continue }
            if scalar.value == 0xE005 { output += "්‍ය"; i += 1; continue }
            if scalar.value == 0xE002 { output += "ර්‍"; i += 1; continue }
            if scalar.value == 0xE000 || scalar.value == 0xE001 || scalar.value == 0xE003 { i += 1; continue }
            output.unicodeScalars.append(scalar)
            i += 1
        }
        return output.precomposedStringWithCanonicalMapping
    }

    static func transliterate(_ source: String, mode: Mode) -> String {
        if mode == .sls { return normalizeSLS(source) }
        if mode == .smartPhonetic { return transliterateSmartPhonetic(source) }
        var output = ""
        var index = source.startIndex

        func match<T>(_ entries: [(String, T)]) -> (String, T)? {
            entries.first { source[index...].hasPrefix($0.0) }
        }
        func matchVowel() -> (String, String, String)? {
            vowels.first { source[index...].hasPrefix($0.0) }
        }
        func advance(_ count: Int) { index = source.index(index, offsetBy: count) }

        while index < source.endIndex {
            let character = String(source[index])
            if character == "M" {
                output += "ං"; advance(1); continue
            }
            if character == "H" { output += "ඃ"; advance(1); continue }

            if let (key, consonant) = match(consonants) {
                output += consonant
                advance(key.count)
                if let (vowelKey, _, vowelSign) = matchVowel() {
                    output += vowelSign
                    advance(vowelKey.count)
                } else if index < source.endIndex, source[index] == "r" {
                    output += "්‍ර"
                    advance(1)
                    if let (vowelKey, _, vowelSign) = matchVowel() {
                        output += vowelSign
                        advance(vowelKey.count)
                    }
                } else if let (nextKey, _) = match(consonants) {
                    output += nextKey == "y" ? "්‍" : "්"
                } else {
                    output += "්"
                }
                continue
            }
            if let (key, independentVowel, _) = matchVowel() {
                output += independentVowel; advance(key.count); continue
            }
            output += character
            advance(1)
        }
        return output
    }

    private static func transliterateSmartPhonetic(_ source: String) -> String {
        var output = ""
        var index = source.startIndex

        func matchConsonant() -> (String, String)? {
            smartConsonants.first { source[index...].hasPrefix($0.0) }
        }
        func matchVowel() -> (String, String, String?)? {
            smartVowels.first { source[index...].hasPrefix($0.0) }
        }
        func advance(_ count: Int) { index = source.index(index, offsetBy: count) }

        while index < source.endIndex {
            let character = String(source[index])
            if character == "M" || character == "x" {
                output += "ං"; advance(1); continue
            }
            if source[index...].hasPrefix("zn") {
                output += "ං"; advance(2); continue
            }
            // z is a prefix for the smart prenasalized consonants. A lone or
            // unknown z is intentionally swallowed, matching the desktop IME.
            if character == "z" && !["zg", "zj", "zd", "zdh", "zq", "zk", "zh"].contains(where: { source[index...].hasPrefix($0) }) {
                advance(1); continue
            }
            if character == "H" {
                output += "ඃ"; advance(1); continue
            }
            if let (key, consonant) = matchConsonant() {
                output += consonant
                advance(key.count)
                if let (vowelKey, _, vowelSign) = matchVowel(), let vowelSign {
                    output += vowelSign
                    advance(vowelKey.count)
                } else if let (nextKey, _) = matchConsonant() {
                    let joins = nextKey == "y" || (nextKey == "r" && !["m", "n", "l"].contains(key))
                    output += joins ? "්‍" : "්"
                } else {
                    output += "්"
                }
                continue
            }
            if let (vowelKey, vowel, _) = matchVowel(), !vowel.isEmpty {
                output += vowel; advance(vowelKey.count); continue
            }
            output += character
            advance(1)
        }
        return output
    }
}
