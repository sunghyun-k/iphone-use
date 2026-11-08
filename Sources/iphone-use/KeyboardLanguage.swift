import CoreGraphics
import Foundation

/// The on-screen keyboard's language, read off its key labels, and switching it for Hangul.
///
/// The HID keyboard's layout is fixed per device, but Hangul only composes when the **on-screen**
/// keyboard is Korean too: on an iPhone whose layout is Dubeolsik, typing "언제와" while the on-screen
/// keyboard was English left the loose jamo `ㅇㅓㄴㅈㅔㅇㅗㅏ` in a chat's input field, one tap away from
/// being sent (PITFALLS #11, #58). `ctrl+space` switches the on-screen keyboard, so `type` and `text`
/// switch it to Korean before Hangul and back afterwards.
enum KeyboardLanguage: String {
    case korean, latin

    /// The language of the keys on screen, or nil when it can't tell (no keyboard, the number or emoji
    /// pad). Keys come out of OCR as single-character lines below the top key row.
    static func detect(in lines: [TextRecognizer.Line], height: CGFloat) -> KeyboardLanguage? {
        guard let top = TextRecognizer.keysTop(in: lines, height: height) else { return nil }
        var jamo = 0, latin = 0
        for line in lines where line.frame.midY >= top - height * 0.005 {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.count == 1, let character = text.first, let scalar = text.unicodeScalars.first else { continue }
            if (0x3131...0x3163).contains(scalar.value) {
                jamo += 1
            } else if character.isASCII && character.isLetter {
                latin += 1
            }
        }
        // OCR reads a few Korean keys as Latin look-alikes (ㅇ as "o", ㅣ as "l"), so Latin must clearly win.
        if jamo >= 5 && jamo > latin { return .korean }
        if latin >= 5 && latin > jamo * 2 { return .latin }
        return nil
    }

    /// Reads the keyboard language from a fresh screenshot.
    static func current(rsd: RemoteServiceDiscovery) throws -> KeyboardLanguage? {
        let image = try ScreenText.litImage(rsd: rsd)
        return detect(in: try TextRecognizer.lines(in: image), height: CGFloat(image.height))
    }

    /// `ctrl+space` steps to the next input source. A device rarely has more than three or four.
    static let maxSwitches = 4

    static func pressSwitch(_ hid: HIDService) throws {
        try hid.typeKey(0x2C, modifiers: [0xE0])
        // The keys redraw about 0.2 s after the press.
        Thread.sleep(forTimeInterval: 0.35)
    }

    /// Switches the on-screen keyboard to Korean when it shows Latin keys. Returns whether it switched,
    /// so the caller can switch back with `restore`. Does nothing when the language can't be read (the
    /// number pad): typing goes ahead, and `type` checks the result.
    static func switchToKorean(from start: KeyboardLanguage?, hid: HIDService, rsd: RemoteServiceDiscovery) throws -> Bool {
        guard start == .latin else { return false }
        for _ in 0..<maxSwitches {
            try pressSwitch(hid)
            if try current(rsd: rsd) == .korean { return true }
        }
        try restore(hid: hid, rsd: rsd)
        throw InputFailure.noKorean(
            """
            The on-screen keyboard is not Korean, and ctrl+space did not reach a Korean keyboard \
            (\(maxSwitches) tries). Nothing was typed. Hangul only composes with a Korean on-screen \
            keyboard: ask the user to add one (Settings › General › Keyboard › Keyboards), or use paste.
            """)
    }

    static let switchedNote = "(switched the on-screen keyboard to Korean for the Hangul, then back)"

    /// Steps the on-screen keyboard back to a Latin one. With several Latin keyboards it stops at the
    /// first it reaches, which may not be the one the user had.
    static func restore(hid: HIDService, rsd: RemoteServiceDiscovery) throws {
        for _ in 0..<maxSwitches {
            try pressSwitch(hid)
            if try current(rsd: rsd) == .latin { return }
        }
    }

    /// True when `typed` reads like Hangul that didn't compose: three or more loose jamo in a row
    /// (`ㅇㅓㄴ`), or the Dubeolsik keys as Latin letters (`djswp`, on a device whose layout is English).
    /// `intended` is what was typed, so text that really has loose jamo isn't flagged.
    static func looksUncomposed(_ typed: String, intended: String) -> Bool {
        if intended.unicodeScalars.contains(where: { (0x3131...0x3163).contains($0.value) }) { return false }
        var run = 0
        for scalar in typed.unicodeScalars {
            run = (0x3131...0x3163).contains(scalar.value) ? run + 1 : 0
            if run >= 3 { return true }
        }
        let keys = intended.compactMap { HangulKeys.keys(for: $0) }.joined().lowercased()
        guard keys.count >= 3 else { return false }
        // OCR often gets the last or first letter wrong ("qoxjf°" for "qoxjfl").
        let seen = typed.replacingOccurrences(of: " ", with: "").lowercased()
        // Only for longer keys: every line on the screen is checked, and three letters like "rks" turn up in
        // ordinary words.
        let part = keys.count >= 5 ? keys.count - 1 : keys.count
        return seen.contains(String(keys.prefix(part))) || seen.contains(String(keys.suffix(part)))
    }
}
