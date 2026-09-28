import Foundation

/// Converts Hangul into the keys (Latin positions) to press on a Dubeolsik (2-set Korean) layout. "안녕" -> "dkssud".
///
/// An HID keyboard sends **key positions**, not characters. When the device's input source is Korean,
/// the device IME reads those positions as Dubeolsik and composes them, so sending Hangul decomposed
/// into key order types it exactly. The IME splits syllables itself — thanks to the Dubeolsik rule that
/// moves a final consonant to the next syllable when a vowel follows, sending "가나" as `rksk` yields
/// "가나", not "간ㅏ".
///
/// Pasting (`paste`) gets stuck without a human nearby because the device shows an "Allow Paste"
/// prompt per app (PITFALLS #30). This path gets in without any such prompt.
enum HangulKeys {
    private static let initials = [
        "r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g",
    ]
    private static let medials = [
        "k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl",
        "b", "m", "ml", "l",
    ]
    private static let finals = [
        "", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a",
        "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g",
    ]
    /// Single compatibility jamo (ㄱ U+3131 … ㅣ U+3163).
    private static let compatibility: [Character: String] = {
        let jamo = Array("ㄱㄲㄳㄴㄵㄶㄷㄸㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅃㅄㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
        let keys = [
            "r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg",
            "a", "q", "Q", "qt", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g",
            "k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl",
            "b", "m", "ml", "l",
        ]
        return Dictionary(uniqueKeysWithValues: zip(jamo, keys))
    }()

    static func isHangul(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1
        else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value) || compatibility[character] != nil
    }

    /// Keys for one Hangul character. nil if it isn't Hangul.
    static func keys(for character: Character) -> String? {
        if let jamo = compatibility[character] { return jamo }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
            (0xAC00...0xD7A3).contains(scalar.value)
        else { return nil }

        let index = Int(scalar.value) - 0xAC00
        return initials[index / (21 * 28)] + medials[(index % (21 * 28)) / 28] + finals[index % 28]
    }
}
