import CoreGraphics
import Foundation

/// Where the on-screen keyboard's letter keys are, for typing by tapping them.
///
/// What the HID keys type depends on the app: on one iPhone, Dubeolsik in Notes (so "Hello" came out as
/// loose jamo) and Latin in another app (so "홍길동" came out as `ghdrlfehd`), and nothing we send changes
/// that (PITFALLS #58). The keys on the screen always type what they show, so the script the HID keys
/// can't type here is tapped (PITFALLS #64).
struct OnScreenKeys {
    /// The letter rows by Latin position, their Dubeolsik labels (compared with what the device shows),
    /// and how far the first key's center is from the left edge, in key widths.
    private static let rows: [(latin: String, jamo: String, first: Double)] = [
        ("qwertyuiop", "ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", 0.5), ("asdfghjkl", "ㅁㄴㅇㄹㅎㅗㅓㅏㅣ", 1), ("zxcvbnm", "ㅋㅌㅊㅍㅠㅜㅡ", 2),
    ]

    /// Key centers in screenshot pixels, by Latin position (lowercase).
    let keys: [Character: CGPoint]
    let shift: CGPoint
    /// The keys show capitals: Shift is on (the start of a sentence).
    let uppercase: Bool

    /// The layout, fitted to the key labels OCR read: an iPhone's portrait keyboard has ten keys across
    /// the screen's width, the second row half a key in, the third two keys in. Nil when fewer than six
    /// keys sit where that predicts (an iPad, landscape, another layout), so nothing is tapped blind.
    static func fit(_ language: KeyboardLanguage, in lines: [TextRecognizer.Line], width: CGFloat, height: CGFloat)
        -> OnScreenKeys?
    {
        guard let top = TextRecognizer.keysTop(in: lines, height: height) else { return nil }
        let pitch = width / 10
        var seen: [[CGFloat]] = [[], [], []]
        var capitals = 0, small = 0
        for line in lines where line.frame.midY >= top - height * 0.005 {
            for (label, x) in labels(of: line) {
                for (index, row) in rows.enumerated() {
                    let labels = Array(language == .korean ? row.jamo : row.latin)
                    guard let column = labels.firstIndex(of: Character(label.lowercased())) else { continue }
                    if abs(x - (Double(column) + row.first) * pitch) < pitch * 0.3 {
                        seen[index].append(line.frame.midY)
                        if label.isUppercase { capitals += 1 } else { small += 1 }
                    }
                }
            }
        }
        guard seen.map(\.count).reduce(0, +) >= 6 else { return nil }
        let known = seen.enumerated().compactMap { index, ys in
            ys.isEmpty ? nil : (row: index, y: ys.sorted()[ys.count / 2])
        }
        guard let first = known.first, let last = known.last, last.row > first.row else { return nil }
        let rowPitch = (last.y - first.y) / Double(last.row - first.row)
        guard rowPitch > height * 0.03, rowPitch < height * 0.1 else { return nil }
        var keys: [Character: CGPoint] = [:]
        var third: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let y = known.first { $0.row == index }?.y ?? first.y + Double(index - first.row) * rowPitch
            if index == 2 { third = y }
            for (column, letter) in row.latin.enumerated() {
                keys[letter] = CGPoint(x: (Double(column) + row.first) * pitch, y: y)
            }
        }
        return OnScreenKeys(keys: keys, shift: CGPoint(x: pitch * 0.7, y: third), uppercase: capitals > small)
    }

    /// The key labels in one OCR line, with the center x of each. OCR often reads neighboring keys as
    /// one line ("QWERT", "BN", "X C"): with only single-letter lines counted, Settings' search found
    /// five Latin keys, gave up tapping, and the HID keys typed jamo (PITFALLS #68). The labels in such
    /// a line are taken as evenly spaced, the first and last half a label in from its ends (a label is
    /// about as wide as the line is tall).
    private static func labels(of line: TextRecognizer.Line) -> [(Character, CGFloat)] {
        let text = line.text.filter { !$0.isWhitespace && !"•·".contains($0) }
        if text.count == 1, let label = text.first { return [(label, line.frame.midX)] }
        guard (2...10).contains(text.count), text.allSatisfy(\.isLetter) else { return [] }
        let inset = min(line.frame.height, line.frame.width / Double(text.count)) / 2
        let step = (line.frame.width - inset * 2) / Double(text.count - 1)
        return text.enumerated().map { ($1, line.frame.minX + inset + Double($0) * step) }
    }

    private func touch(_ point: CGPoint, input: InputSession) throws {
        let at = input.normalized(point.x, point.y)
        try input.hid.tap(x: at.x, y: at.y, hold: 0.05)
        // Closer together, the keyboard dropped a tap now and then.
        Thread.sleep(forTimeInterval: 0.08)
    }

    /// Taps a run of one script. On the Korean keys a stroke in capitals is the shifted key (Q for ㅃ).
    /// On the Latin keys Shift may already be on (a sentence's first letter), and goes off after a letter.
    func tap(_ run: ArraySlice<Character>, language: KeyboardLanguage, shifted: Bool, input: InputSession) throws {
        var shifted = shifted
        for character in run {
            for stroke in language == .korean ? Array(HangulKeys.keys(for: character) ?? "") : [character] {
                guard let point = keys[Character(stroke.lowercased())] else { continue }
                if stroke.isUppercase != shifted { try touch(shift, input: input) }
                try touch(point, input: input)
                shifted = false
            }
        }
    }

    /// What `type` did besides sending HID keys.
    struct Outcome {
        var switched = false
        var tappedHangul = false
        var tappedLatin = false

        func printNotes() {
            if switched { print(KeyboardLanguage.switchedNote) }
            if tappedHangul {
                print("(here the HID keys type Latin letters, so the Hangul was typed by tapping the on-screen keys)")
            }
            if tappedLatin {
                print(
                    "(here the HID keys type Hangul, so the Latin letters were typed by tapping the on-screen keys; "
                        + "check the result — autocorrection can change a tapped word)")
            }
        }
    }

    private enum Script { case hangul, latin, other }

    private static func script(_ character: Character) -> Script {
        if HangulKeys.keys(for: character) != nil { return .hangul }
        return character.isASCII && character.isLetter ? .latin : .other
    }

    /// Types `text`, already checked by `TextCommand.keys`.
    ///
    /// `language` is what the on-screen keyboard shows; with nil (not read, or unreadable) everything
    /// goes by HID. Otherwise the text goes run by run. Digits, symbols and spaces sit on the same HID
    /// keys in every layout. The first run of letters goes by HID with the on-screen keyboard in its
    /// script, and the screen is read once to learn what the HID keys type here: if the letters came out
    /// in the other script, they are deleted (there, one character per key), and that script is tapped
    /// on the screen from then on. Hangul only composes with Korean keys showing, and tapping needs the
    /// script's keys, so the on-screen keyboard is switched as the runs need and put back at the end.
    static func type(
        _ text: String, input: InputSession, rsd: RemoteServiceDiscovery, before: [TextRecognizer.Line],
        language: KeyboardLanguage?, beforeReturn: Bool
    ) throws -> Outcome {
        var outcome = Outcome()
        let characters = Array(text)
        func press(_ run: ArraySlice<Character>) throws {
            for character in run {
                for stroke in HangulKeys.keys(for: character).map(Array.init) ?? [character] {
                    guard let (usage, shift) = TextCommand.usage(for: stroke) else { continue }
                    try input.hid.typeKey(usage, modifiers: shift ? [0xE1] : [])
                }
            }
        }
        guard let original = language else {
            try press(characters[...])
            return outcome
        }
        var showing = original
        var layout: KeyboardLanguage?
        var seen = before
        var lastSwitch = Date.distantPast

        func show(_ target: KeyboardLanguage) throws -> Bool {
            if showing == target { return true }
            guard let lines = try KeyboardLanguage.step(to: target, hid: input.hid, rsd: rsd) else { return false }
            showing = target
            seen = lines
            outcome.switched = true
            lastSwitch = Date()
            return true
        }
        func read() throws -> (lines: [TextRecognizer.Line], width: CGFloat, height: CGFloat) {
            Thread.sleep(forTimeInterval: 0.3)
            let image = try ScreenText.litImage(rsd: rsd)
            return (try TextRecognizer.lines(in: image), CGFloat(image.width), CGFloat(image.height))
        }
        /// The lines above the keys that weren't there before the run.
        func fresh() throws -> [String] {
            let (lines, _, height) = try read()
            let old = Set(seen.map(\.text))
            let top = TextRecognizer.keysTop(in: lines, height: height) ?? height
            return lines.filter { $0.frame.midY < top && !old.contains($0.text) }.map(\.text)
        }
        // The keys are read again only when Shift may have come on by itself: at the start, and after
        // the end of a sentence. Reading before every word took a second a word.
        var board: (keys: OnScreenKeys, language: KeyboardLanguage)?
        var shiftKnownOff = false
        func tap(_ run: ArraySlice<Character>) throws -> Bool {
            if board?.language != showing || !shiftKnownOff {
                let (lines, width, height) = try read()
                guard let keys = fit(showing, in: lines, width: width, height: height) else { return false }
                board = (keys, showing)
                shiftKnownOff = !(showing == .latin && keys.uppercase)
            }
            guard let board else { return false }
            try board.keys.tap(run, language: showing, shifted: !shiftKnownOff, input: input)
            shiftKnownOff = true
            return true
        }
        /// The input-source list ctrl+space brings up stays for about two seconds, over the middle of
        /// the screen: it can cover the field, and it takes a Return for itself.
        func waitOutList() throws {
            let wait = max(0.8, 2.3 - Date().timeIntervalSince(lastSwitch))
            Thread.sleep(forTimeInterval: wait)
        }
        func backspace(_ count: Int) throws {
            for _ in 0..<count { try input.hid.typeKey(0x2A, modifiers: []) }
        }

        var index = 0
        while index < characters.count {
            let kind = script(characters[index])
            var end = index
            while end < characters.count, script(characters[end]) == kind { end += 1 }
            var run = characters[index..<end]
            index = end
            switch kind {
            case .other:
                try press(run)
                if run.contains(where: { ".!?\n".contains($0) }) { shiftKnownOff = false }
            case .hangul:
                guard try show(.korean) else {
                    _ = try show(original)
                    throw InputFailure.noKorean(
                        """
                        The on-screen keyboard is not Korean, and ctrl+space did not reach a Korean keyboard \
                        (\(KeyboardLanguage.maxSwitches) tries). Hangul only composes with a Korean on-screen \
                        keyboard: ask the user to add one (Settings › General › Keyboard › Keyboards), or use paste.
                        """)
                }
                if layout == nil, let syllable = run.first, let probe = HangulKeys.keys(for: syllable) {
                    try press(run.prefix(1))
                    var new = try fresh()
                    // The input-source list that ctrl+space brings up can cover the field for a second.
                    // The keys as a word of their own. Whether the syllable shows too says nothing: a
                    // search field that kept "vks" listed suggestions with "판" under it.
                    // One letter may differ in three or more: OCR read a field's "vks" as "uks".
                    func asLatin(_ lines: [String]) -> Bool {
                        let keys = Array(probe.lowercased())
                        return lines.contains { line in
                            line.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) }).contains { word in
                                word.count == keys.count
                                    && zip(word, keys).filter { $0 != $1 }.count <= (keys.count >= 3 ? 1 : 0)
                            }
                        }
                    }
                    if !asLatin(new), !new.contains(where: { $0.contains(syllable) }) {
                        try waitOutList()
                        new = try fresh()
                    }
                    if asLatin(new) {
                        layout = .latin
                        try backspace(probe.count)
                    } else {
                        layout = .korean
                        run = run.dropFirst()
                    }
                }
                if layout == .latin, try tap(run) { outcome.tappedHangul = true } else { try press(run) }
            case .latin:
                // Probed with Latin keys showing: there, a Dubeolsik layout leaves loose jamo, one per key.
                if layout == nil, try show(.latin) {
                    try press(run)
                    let word = String(run)
                    var new = try fresh()
                    if !new.contains(where: { $0.localizedCaseInsensitiveContains(word) }) {
                        try waitOutList()
                        new = try fresh()
                    }
                    let hangul = new.contains { line in
                        line.unicodeScalars.contains { (0x3131...0x3163).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
                    }
                    // The jamo spelling the word's keys settle it even with the word on the screen too: a
                    // translator listed "where" as a suggestion under "ㅉㅗㄷㄱㄷ", and the word check
                    // alone kept typing jamo (PITFALLS #68).
                    let spelled = run.count >= 2
                        && new.contains { KeyboardLanguage.hangulKeys($0).contains(word.lowercased()) }
                    if spelled || hangul && !new.contains(where: { $0.localizedCaseInsensitiveContains(word) }) {
                        layout = .korean
                        try backspace(run.count)
                    } else {
                        layout = .latin
                        continue
                    }
                }
                if layout == .korean, try show(.latin), try tap(run) { outcome.tappedLatin = true } else { try press(run) }
            }
        }
        // Before the caller's Return: a Return that sends or searches can take the keyboard away.
        _ = try show(original)
        // The input-source list ctrl+space brings up stays for about two seconds and takes a Return for
        // itself: a search typed with a switch at the end was never submitted (PITFALLS #64).
        let wait = 2.3 - Date().timeIntervalSince(lastSwitch)
        if beforeReturn, wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return outcome
    }
}
