import Foundation

/// Applies the shared default Fitzpatrick tone to catalog and suggestion emoji.
/// Recents keep whatever the user actually inserted.
enum EmojiSkinToneApplicator {
    static func applyingPreferredSkinTone(
        to emoji: [String],
        tone: KeyboardPreferences.EmojiSkinTone = KeyboardPreferences.emojiSkinTone()
    ) -> [String] {
        var seen = Set<String>()
        return emoji.compactMap { value in
            let key = skinToneFreeKey(for: value)
            guard seen.insert(key).inserted else { return nil }
            return withPreferredSkinTone(key, tone: tone)
        }
    }

    static func withPreferredSkinTone(
        _ emoji: String,
        tone: KeyboardPreferences.EmojiSkinTone = KeyboardPreferences.emojiSkinTone()
    ) -> String {
        guard let modifier = tone.modifierScalar else {
            return skinToneFreeKey(for: emoji)
        }
        let base = skinToneFreeKey(for: emoji)
        guard base.unicodeScalars.contains(where: { $0.properties.isEmojiModifierBase }) else {
            return base
        }
        var scalars = String.UnicodeScalarView()
        var pendingModifier = false
        for scalar in base.unicodeScalars {
            if scalar.value == 0xFE0F, pendingModifier {
                scalars.append(modifier)
                pendingModifier = false
                continue
            }
            if pendingModifier {
                scalars.append(modifier)
                pendingModifier = false
            }
            scalars.append(scalar)
            if scalar.properties.isEmojiModifierBase {
                pendingModifier = true
            }
        }
        if pendingModifier {
            scalars.append(modifier)
        }
        return String(scalars)
    }

    static func skinToneFreeKey(for emoji: String) -> String {
        String(String.UnicodeScalarView(emoji.unicodeScalars.filter { !$0.properties.isEmojiModifier }))
    }
}
