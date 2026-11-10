import CoreGraphics
import Foundation
import AppKit
import Vision

/// Reads the text on a screenshot (`ui`) and detects the on-screen keyboard. Runs on the Mac's Vision, so
/// the device isn't touched.
///
/// OCR once picked tap targets by matching a string the caller guessed (`tap "text"`), and that often
/// pressed the wrong place: the guess matched several lines, or a misread line. `ui` instead lists every
/// line it read with a ref and saves the screenshot next to it, so the caller picks a line it has seen
/// (PITFALLS #48).
enum TextRecognizer {
    struct Line: Sendable {
        let text: String
        /// Screenshot pixel coordinates (origin top-left).
        let frame: CGRect
        /// The button shape this line is the label of, if it sits on one (`ScreenElements`). Pixels.
        var button: CGRect? = nil
    }

    /// All text lines on the screen.
    ///
    /// Reading the Korean keyboard layout needs `accurate` level (`fast` only reads Latin script).
    /// About 0.3–0.6 s for one 1290×2796 image on Apple Silicon.
    static func lines(in image: CGImage, languages: [String] = ["ko-KR", "en-US"]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Half size is enough to tell a glyph's color.
        let colors = PointBitmap(image, scale: 2)
        return (request.results ?? []).flatMap { observation -> [Line] in
            guard let best = observation.topCandidates(1).first else { return [] }
            // Vision's normalized coordinates (origin bottom-left) -> pixel coordinates (origin top-left).
            func line(_ text: String, _ box: CGRect) -> Line {
                Line(
                    text: text,
                    frame: CGRect(
                        x: box.minX * width, y: (1 - box.maxY) * height,
                        width: box.width * width, height: box.height * height))
            }
            // A run of short numbers is a row of separate things to press (a calendar's days, a page
            // list), not a sentence: a date picker's week came out as one line "12 13 14", and pressing
            // it could only reach the day in the middle (PITFALLS #64).
            let string = Self.withoutStraySyllable(best.string)
            let words = string.split(separator: " ")
            if words.count > 1, words.allSatisfy({ $0.count <= 2 && $0.allSatisfy(\.isNumber) }) {
                let parts = words.compactMap { word in
                    (try? best.boundingBox(for: word.startIndex..<word.endIndex)).flatMap { $0 }
                        .map { line(String(word), $0.boundingBox) }
                }
                if parts.count == words.count { return parts }
            }
            // A stepper's − count + came out as one line ("- 2 +", "1 +"), so neither button had a ref
            // and they could only be tapped by grid cell (PITFALLS #72). Each sign is its own button.
            // A disabled − (an outlined circle) reads as "•", which is only taken for one here, among
            // a count and a + or −.
            if words.count > 1, words.contains(where: { ["+", "-", "−", "–"].contains(String($0)) }),
                words.allSatisfy({ Self.stepperSigns[String($0)] != nil || ($0.count <= 3 && $0.allSatisfy(\.isNumber)) })
            {
                // Vision gave no box for the "+" of "1 +" while it did for "- 2 +"; then the line's box
                // is cut by character position, which puts the sign at the end where the button is.
                let whole = observation.boundingBox
                let count = CGFloat(string.count)
                return words.map { word in
                    let text = Self.stepperSigns[String(word)] ?? String(word)
                    if let box = (try? best.boundingBox(for: word.startIndex..<word.endIndex)).flatMap({ $0 }) {
                        return line(text, box.boundingBox)
                    }
                    let start = CGFloat(string.distance(from: string.startIndex, to: word.startIndex))
                    return line(text, CGRect(
                        x: whole.minX + whole.width * start / count, y: whole.minY,
                        width: whole.width * CGFloat(word.count) / count, height: whole.height))
                }
            }
            // A menu's check mark read as the first "word" of its row ("V Free", "~ Apple") goes on a
            // line of its own, where the symbol matcher names it like any other lone glyph.
            if words.count > 1, let mark = words.first, Self.checkMarks.contains(String(mark)),
                string == best.string,
                let markBox = (try? best.boundingBox(for: mark.startIndex..<mark.endIndex)).flatMap({ $0 }),
                let restBox = (try? best.boundingBox(for: words[1].startIndex..<string.endIndex)).flatMap({ $0 })
            {
                return [
                    line(String(mark), markBox.boundingBox),
                    line(String(string[words[1].startIndex...]), restBox.boundingBox),
                ]
            }
            // An icon right before a word is read as the word's first letter: an airplane before "파리"
            // gave "쓰파리", a calendar before a date "뼈 11월 20일" (PITFALLS #66). The icon is tinted and
            // the word isn't, so a first character in another color than the rest is listed as `[icon]`.
            // Only a non-ASCII first character: a price's red first digit is part of the price.
            if let colors, string == best.string, string.count >= 3, let first = string.unicodeScalars.first, !first.isASCII,
                let headBox = (try? best.boundingBox(for: string.startIndex..<string.index(after: string.startIndex))).flatMap({ $0 })
            {
                let restStart = string.index(after: string.startIndex)
                let rest = string[restStart...].drop(while: { $0 == " " })
                if rest.count >= 2, let restBox = (try? best.boundingBox(for: rest.startIndex..<string.endIndex)).flatMap({ $0 }) {
                    let head = line("[icon]", headBox.boundingBox)
                    let tail = line(String(rest), restBox.boundingBox)
                    func half(_ r: CGRect) -> CGRect { CGRect(x: r.minX / 2, y: r.minY / 2, width: r.width / 2, height: r.height / 2) }
                    if let a = ScreenState.colors(of: half(head.frame), in: colors), let b = ScreenState.colors(of: half(tail.frame), in: colors),
                        PointBitmap.distance(a.ink, b.ink) > 120, PointBitmap.distance(a.ground, b.ground) <= 40
                    {
                        return [head, tail]
                    }
                }
            }
            return [line(string, observation.boundingBox)]
        }
    }

    /// What OCR makes of a stepper's buttons, and how they're listed.
    static let stepperSigns: [String: String] = ["+": "[plus]", "-": "[minus]", "−": "[minus]", "–": "[minus]", "•": "[minus]"]

    /// What OCR makes of a check mark at the start of a row.
    static let checkMarks: Set<String> = ["v", "V", "~", "√", "✓", "✔"]

    private static let commonHangul = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    /// `text` without a Hangul syllable stuck to the end of a Latin word. With Korean among the
    /// languages, Vision ends a Latin word with a made-up syllable now and then, mostly on blurred or
    /// translucent text: a menu's "Cherry" came out as "Cherry옓" and the diff reported the line as
    /// changed (PITFALLS #64). Only syllables outside the 2,350 of KS X 1001 are dropped (what EUC-KR
    /// can't encode): real particles after a Latin word ("Wi-Fi를") are all inside it.
    static func withoutStraySyllable(_ text: String) -> String {
        guard let last = text.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value),
            String(last).data(using: commonHangul) == nil,
            let before = text.unicodeScalars.dropLast().last, before.isASCII, before.properties.isAlphabetic
        else { return text }
        return String(text.dropLast())
    }

    /// The glyphs on buttons the screen-wide pass left unread (`glyphs`, pixels), read again one by one:
    /// the text of each, or nil where nothing was read.
    ///
    /// Vision drops a lone character on a big screen: on the Calculator, a full read missed half the
    /// single-digit keys. A crop of the key alone doesn't fix it: an isolated digit is often read upside
    /// down (a 9 as "6") or not at all. What reads reliably is the glyph as the last letter of a word:
    /// each glyph, turned dark on white, goes right after a drawn "Key" on its own row, and the rows are
    /// stacked in one image, so it's one request for all of them (PITFALLS #62).
    static func labels(forGlyphs glyphs: [(glyph: CGRect, button: CGRect)], in image: CGImage) throws -> [String?] {
        guard !glyphs.isEmpty else { return [] }
        let row = 60, gap = 30
        let font = NSFont.systemFont(ofSize: CGFloat(row) / 2)
        let word = NSAttributedString(string: Self.labelPrefix, attributes: [.font: font, .foregroundColor: NSColor.black])
        let glyphX = 10 + Int(word.size().width.rounded(.up)) + row / 8
        let width = glyphX + row + 20, height = glyphs.count * (row + gap) + gap
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return glyphs.map { _ in nil } }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (index, (glyph, button)) in glyphs.enumerated() {
            // CoreGraphics' origin is the bottom-left.
            let y = height - gap - (index + 1) * row - index * gap
            word.draw(at: NSPoint(x: 10, y: CGFloat(y) + CGFloat(row) * 0.22))
            // A square 2.4 times the glyph: drawn into the row, the glyph comes out about as tall as the word.
            // Kept inside the button's fill (a disc's inscribed square), so the border is all fill: past it,
            // the page around the button became the background and the fill read as a dark blot.
            let side = max(glyph.width, glyph.height) * 2.4
            let area = CGRect(x: glyph.midX - side / 2, y: glyph.midY - side / 2, width: side, height: side)
                .intersection(button.insetBy(dx: button.width * 0.15, dy: button.height * 0.15))
            guard !area.isNull, let crop = image.cropping(to: area.integral), let ink = darkOnWhite(crop) else { continue }
            ctx.draw(ink, in: CGRect(x: glyphX, y: y, width: row, height: row))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let stacked = ctx.makeImage() else { return glyphs.map { _ in nil } }

        // Two passes with different language settings: each drops a different lone glyph now and then (one
        // missed a 9 the other read), and the image is small, so the second costs about 0.05 s.
        var found = [String?](repeating: nil, count: glyphs.count)
        for languages in [["en-US"], ["ko-KR", "en-US"]] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: stacked).perform([request])
            for observation in request.results ?? [] {
                guard let best = observation.topCandidates(1).first else { continue }
                let midY = (1 - observation.boundingBox.midY) * CGFloat(height)
                let index = Int(midY) / (row + gap)
                guard index >= 0, index < glyphs.count, found[index] == nil else { continue }
                // The word is sometimes a separate observation, and sometimes misread ("KeY", "Kay").
                var text = best.string.trimmingCharacters(in: .whitespaces)
                if text.lowercased().hasPrefix("k"), text.count >= 3 { text = String(text.dropFirst(3)) }
                text = text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { found[index] = text }
            }
        }
        return found
    }

    private static let labelPrefix = "Key"

    /// The crop with its background (the border's median gray) white and what differs from it dark, so
    /// white-on-color and dark-on-light glyphs read alike next to the black word.
    private static func darkOnWhite(_ crop: CGImage) -> CGImage? {
        let w = crop.width, h = crop.height
        guard w > 2, h > 2 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard
            let ctx = CGContext(
                data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var border: [UInt8] = []
        for x in 0..<w { border.append(gray[x]); border.append(gray[(h - 1) * w + x]) }
        for y in 0..<h { border.append(gray[y * w]); border.append(gray[y * w + w - 1]) }
        let background = Int(border.sorted()[border.count / 2])
        for i in gray.indices { gray[i] = UInt8(max(0, 255 - abs(Int(gray[i]) - background) * 2)) }
        return ctx.makeImage()
    }

    /// The top edge (pixel y) of the on-screen keyboard if it's up, otherwise nil.
    ///
    /// OCR picks up keyboard keys as single-character lines like "Q", "W" or a single Hangul jamo, several per row. The first
    /// row with more than four single-character lines side by side is taken as the top key row, and we move
    /// up further by the suggestion bar / toolbar allowance (14% of screen height). Once, with the keyboard up,
    /// a `scroll` in the middle of the screen landed its swipe on the keys and typed "G" into a search field.
    static func keyboardTop(in lines: [Line], height: CGFloat) -> CGFloat? {
        keysTop(in: lines, height: height).map { max(height * 0.2, $0 - height * 0.14) }
    }

    /// The top edge (pixel y) of the keyboard's top key row, without the suggestion bar allowance. `ui`
    /// leaves out the lines below it: forty single letters would bury the screen's own text, and the field
    /// just above the keys (a chat's input) must stay in the list.
    static func keysTop(in lines: [Line], height: CGFloat) -> CGFloat? {
        let keys = keyLines(in: lines, below: height * 0.35)
        guard keys.map(keyCount).reduce(0, +) >= 10 else { return nil }
        let sorted = keys.sorted { $0.frame.midY < $1.frame.midY }
        for key in sorted {
            let row = sorted.filter { abs($0.frame.midY - key.frame.midY) < height * 0.015 }
            // Six or more: a keyboard's top row has ten keys, and OCR misses a few thin ones. With four, the
            // Calculator's keypad (five round keys a row) counted as a keyboard, and its keys were left out
            // of the list (PITFALLS #61).
            if row.map(keyCount).reduce(0, +) >= 6 { return row.map(\.frame.minY).min() }
        }
        return nil
    }

    /// The lines below `top` that look like keys. A month calendar is not a keyboard: a date picker's
    /// grid has a row of seven single digits ("3 4 5 6 7 8 9") and, in Korean, seven single-syllable
    /// weekdays, so it counted as one and `ui` left out everything from that row down, tab bar included
    /// (PITFALLS #64). A calendar always shows the days 10 to 28, and no keyboard layout has two-digit
    /// keys, so when those are on screen the digits and weekday letters stop counting.
    static func keyLines(in lines: [Line], below top: CGFloat) -> [Line] {
        let days = lines.flatMap { $0.text.split(separator: " ") }.filter { $0.count == 2 && (10...31).contains(Int($0) ?? 0) }
        let calendar = Set(days).count >= 8
        return lines.filter { line in
            guard keyCount(line) > 0, line.frame.midY > top else { return false }
            // Weekday initials, compared with what the device shows.
            return !calendar || !line.text.allSatisfy { $0.isNumber || $0.isWhitespace || "SMTWF일월화수목금토".contains($0) }
        }
    }

    /// How many keyboard keys a line looks like: a single character is one; a run of up to ten letters
    /// with no lowercase-uppercase mix is that many. Notes' keyboard (with its formatting bar) came out
    /// as "QWERT", "YU 1", "ASD": no line was a single character, the keyboard wasn't found, and `type`
    /// refused to type into the open note (PITFALLS #63).
    static func keyCount(_ line: Line) -> Int {
        let text = line.text.filter { !$0.isWhitespace && !"•·".contains($0) }
        if text.count == 1 { return 1 }
        guard (2...10).contains(text.count), text.allSatisfy({ $0.isLetter || $0.isNumber }),
            text.allSatisfy({ $0.isUppercase || !$0.isCased }) || text.allSatisfy({ $0.isLowercase || !$0.isCased }),
            // Words aren't keys: a row of keys has no vowels in a pattern; a real word ("The") is short and
            // sits in the suggestion bar above the keys, which `keyboardTop` allows for anyway.
            line.frame.width > line.frame.height * Double(text.count) * 1.6
        else { return 0 }
        return text.count
    }

    /// Is the on-screen keyboard up? Looser than `keyboardTop` — layouts with only three keys per row,
    /// like the number pad, still count as a keyboard if more than ten single-character lines cluster near
    /// the bottom of the screen.
    static func keyboardVisible(in lines: [Line], height: CGFloat) -> Bool {
        if keyboardTop(in: lines, height: height) != nil { return true }
        let keys = keyLines(in: lines, below: height * 0.45)
        return keys.map(keyCount).reduce(0, +) >= 10
    }
}
