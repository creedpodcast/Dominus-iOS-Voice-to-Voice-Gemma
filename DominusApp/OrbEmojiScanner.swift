import Foundation

/// Phase 1 of the emoji-orb feature: turns a streaming/complete AI text string
/// into an ordered list of emoji-bearing characters and their position in the
/// text. Phase 2 will use the positions to schedule fade-in animations against
/// AVSpeechSynthesizer's `willSpeakRangeOfSpeechString` callbacks.
///
/// "Orb glyphs" are the characters that should appear inside the orb during
/// voice mode:
///   - Any Unicode scalar with `isEmoji` and `isEmojiPresentation`
///   - Emphatic `!` and `?` punctuation (sentence-ending exclamation/question)
///
/// Words themselves never go in the orb; only these glyphs.
enum OrbEmojiScanner {

    /// A single character that should appear inside the orb, tagged with the
    /// character index in the source text where it occurs (UTF-16 view, which
    /// is what AVSpeechSynthesizer uses for its `NSRange` callbacks).
    struct Placement: Equatable {
        let glyph: String          // a single emoji or "!" / "?"
        let utf16Index: Int        // matches NSRange.location from speech callbacks
    }

    /// Scan `text` and return every orb-eligible glyph in order, with the
    /// UTF-16 index of its first scalar.
    static func extract(from text: String) -> [Placement] {
        guard !text.isEmpty else { return [] }

        var placements: [Placement] = []
        var utf16Offset = 0

        for character in text {
            let scalars = character.unicodeScalars
            let utf16Width = character.utf16.count

            if isOrbEmoji(character) {
                placements.append(Placement(
                    glyph:      String(character),
                    utf16Index: utf16Offset
                ))
            } else if isEmphaticPunctuation(character, scalars: scalars) {
                placements.append(Placement(
                    glyph:      String(character),
                    utf16Index: utf16Offset
                ))
            }

            utf16Offset += utf16Width
        }

        return placements
    }

    // MARK: - Classifiers

    /// True if `character` is a full emoji (presented as a pictograph).
    /// Excludes ASCII digits/letters that incidentally carry an emoji property
    /// without the presentation flag (e.g. plain `0`-`9`).
    private static func isOrbEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }

        // Real emoji presentation: either the scalar prefers emoji presentation
        // by default, or the character carries a variation selector / ZWJ
        // sequence indicating an emoji glyph.
        if first.properties.isEmojiPresentation { return true }

        // Multi-scalar sequences (skin tones, ZWJ families, flags, etc.) are
        // always emoji if any scalar carries the emoji property.
        if scalars.count > 1 {
            return scalars.contains { $0.properties.isEmoji }
        }
        return false
    }

    /// Emphatic punctuation = `!` or `?`. Per the spec these are the only
    /// non-emoji glyphs allowed in the orb. (We index every `!` / `?`; Phase 2
    /// can decide whether to fade them in vs. ignore based on context.)
    private static func isEmphaticPunctuation(
        _ character: Character,
        scalars: String.UnicodeScalarView
    ) -> Bool {
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return scalar == "!" || scalar == "?"
    }
}
