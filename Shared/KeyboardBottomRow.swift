import Foundation

/// Letter shape must not change the bottom-row geometry. Both languages and
/// all three Sinhala methods share these controls, including Numbers/Symbols.
enum KeyboardBottomRow {
    static func keys(isPad: Bool, emoji: Bool, language: Bool, globe: Bool, punctuation: [String]) -> [String] {
        ["123"] + (language ? ["language"] : []) + (emoji ? ["emoji"] : [])
            + (globe ? ["globe"] : []) + (isPad ? ["space", "123", "dismiss"] : ["space"] + punctuation + ["return"])
    }

    static func controlScale(keys: [String], availableWidth: CGFloat, gap: CGFloat,
                             smallWidth: CGFloat, returnWidth: CGFloat) -> CGFloat {
        let widthWithoutGaps = max(0, availableWidth - gap * CGFloat(max(0, keys.count - 1)))
        let preferred = keys.reduce(CGFloat.zero) { total, key in
            total + (key == "space" ? 0 : key == "return" ? returnWidth : smallWidth)
        }
        guard preferred > 0 else { return 1 }
        // An added language key or two URL keys must not squeeze Space to a
        // sliver. Scale controls together, retaining their relative sizes.
        return min(1, widthWithoutGaps * 0.68 / preferred)
    }
}
