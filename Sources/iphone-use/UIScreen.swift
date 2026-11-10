import CoreGraphics
import Foundation

/// The lines read off the last screenshot, with refs (`@tN`), kept between commands: OCR text, and
/// controls without text found by their shape (`[toggle on] Wi-Fi`, see `ScreenElements`).
///
/// Refs stay the same while it's the same screen: after an action, a line with the same text near the
/// same place keeps its ref, new lines get new refs. When most lines differ, it's a new screen and
/// numbering restarts at 1. Each line keeps a small grayscale crop of where it was read, so `press` can
/// tell whether the line is still there before tapping (PITFALLS #48).
struct UIState: Codable {
    struct Entry: Codable {
        var ref: Int
        var text: String
        /// Where the line was read (device pixels x, y, width, height).
        var rect: [Double]
        /// `ScreenCapture.areaPixels` around the line, base64.
        var pixels: String?
        /// The button shape a text line sits on (`ui --boxes` outlines it instead of the text).
        var button: [Double]?

        var frame: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }

        init(ref: Int, line: TextRecognizer.Line, image: CGImage) {
            self.ref = ref
            text = line.text
            let r = line.frame
            rect = [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 }
            pixels = ScreenCapture.areaPixels(image, in: UIState.checkArea(r)).map { Data($0).base64EncodedString() }
            button = line.button.map { [$0.minX, $0.minY, $0.width, $0.height].map { (Double($0) * 10).rounded() / 10 } }
        }

        /// What `ui --boxes` outlines: the button the line sits on, or the line itself.
        var box: CGRect { button.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? frame }
    }

    var udid: String
    var width = 0
    var height = 0
    var entries: [Entry] = []
    var keyboard = false
    /// A popup over a dimmed screen (`ScreenState.popup`): the card, then pieces beside it. Pixels.
    var popup: [[Double]]?
    /// Lines drawn over a dimmed screen with no card under them (`ScreenState.overlay`). Pixels.
    var overlay: [[Double]]?
    var nextRef = 1
    /// Pixels per point for screens of `scaleSize` (`[width, height]`), so it's asked once, not per read.
    var scale: Int?
    var scaleSize: [Int]?

    init(udid: String) { self.udid = udid }

    /// The area compared before pressing: the line plus half its height above and below, so a list that
    /// moved by less than a row still counts as moved.
    static func checkArea(_ rect: CGRect) -> CGRect { rect.insetBy(dx: 0, dy: -rect.height / 2) }

    static func directory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iphone-use")
    }

    static func url(udid: String) -> URL { directory().appendingPathComponent("screen-\(udid).json") }

    /// Where `ui` saves the screenshot that goes with the list.
    static func imageURL(udid: String) -> URL { directory().appendingPathComponent("screen-\(udid).png") }

    static func load(udid: String) -> UIState {
        guard let data = try? Data(contentsOf: url(udid: udid)),
            let state = try? JSONDecoder().decode(UIState.self, from: data)
        else { return UIState(udid: udid) }
        return state
    }

    func save() {
        let url = Self.url(udid: udid)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url)
    }

    static func clear(udid: String) {
        try? FileManager.default.removeItem(at: url(udid: udid))
    }
}

/// Why we stopped before pressing or typing.
enum UIError: Error, CustomStringConvertible {
    case noList
    case unknownRef(Int, last: Int)
    case badRef(String, matches: [String])
    case stale(String)
    case noKeyboard
    case rowNotSwipeable(String)

    var description: String {
        switch self {
        case .noList:
            return "No text list. Run ui first."
        case .unknownRef(let ref, let last):
            return "@t\(ref) is not in the list (last ref is @t\(last)). Run ui to get a fresh list."
        case .badRef(let text, let matches):
            if matches.isEmpty { return "\(text) is not a ref. Pass a ref from the ui list, like @t12." }
            return "\(text) is not a ref. In the last list: \(matches.joined(separator: ", ")). Pass the ref of the one you mean."
        case .stale(let text):
            return """
                "\(text)" is no longer where the list saw it, and it isn't anywhere else on the screen once — the \
                screen changed since the list was taken. Did not press. Run ui to get a fresh list.
                """
        case .noKeyboard:
            return """
                The on-screen keyboard did not appear — this doesn't look like a text field. Did not type (typing \
                without focus sends keys to app shortcuts). Look at the screenshot, pick the field (its placeholder \
                text, or touch --cell for an empty one) and call type again. If it is a password field, its \
                keyboard never shows in screenshots: call type again with --secure.
                """
        case .rowNotSwipeable(let text):
            return """
                "\(text)" is under the top or bottom bar. Did not swipe — it could hit the wrong row. Use scroll to \
                bring that row near the middle and run ui again.
                """
        }
    }
}

/// The OCR screen for one request: reads the text, compares with the last list, finds a line to press.
final class UIScreen {
    /// Width of the saved screenshot. Big enough to read small labels and grid names, small enough for an
    /// agent to load every turn.
    static let imageWidth = 720

    let udid: String
    var state: UIState
    let rsd: RemoteServiceDiscovery

    private init(udid: String, rsd: RemoteServiceDiscovery) {
        self.udid = udid
        self.rsd = rsd
        self.state = UIState.load(udid: udid)
    }

    static func with<T>(udid wanted: String?, _ body: (UIScreen) throws -> T) throws -> T {
        let udid = try DeviceResolver.udid(for: wanted)
        let rsd = try SessionPool.rsd(udid: udid)
        defer { SessionPool.release(rsd) }
        let screen = UIScreen(udid: udid, rsd: rsd)
        defer { screen.state.save() }
        return try body(screen)
    }

    // MARK: - Reading

    /// The text lines of a screenshot in reading order, without the status bar and the keyboard keys, with
    /// the controls that have no text (`[toggle on] Wi-Fi`, `[chevron left]`) in among them.
    static func read(_ image: CGImage, scale: Int) throws -> (lines: [TextRecognizer.Line], keyboard: Bool, popup: [CGRect]?, overlay: [CGRect]) {
        let height = CGFloat(image.height)
        var lines = try TextRecognizer.lines(in: image)
        // Found against all the text, so glyphs OCR already read (status items included) aren't repeated.
        var (controls, buttons, tiles) = ScreenElements.find(in: image, text: lines, scale: scale)
        for (index, button) in buttons { lines[index].button = button }
        for (index, name) in ScreenElements.symbolNames(for: lines, in: image, scale: scale) {
            lines[index] = TextRecognizer.Line(text: name, frame: lines[index].frame, button: lines[index].button)
        }
        // A ticked box's own mark, read by OCR as "v" or "✓": the box's line says it (PITFALLS #66).
        let ticked = controls.filter { $0.text.hasPrefix("[checkbox ") }.map { $0.frame.insetBy(dx: -4 * CGFloat(scale), dy: -4 * CGFloat(scale)) }
        lines.removeAll { line in
            (TextRecognizer.checkMarks.contains(line.text) || line.text == "[checkmark]")
                && ticked.contains { $0.contains(CGPoint(x: line.frame.midX, y: line.frame.midY)) }
        }
        // A mark the matcher didn't name (a web page's ticked box) goes back in front of its row's text.
        for index in lines.indices.dropLast().reversed() {
            let mark = lines[index], rest = lines[index + 1]
            guard TextRecognizer.checkMarks.contains(mark.text), mark.button == nil,
                abs(rest.frame.midY - mark.frame.midY) < mark.frame.height / 2,
                rest.frame.minX >= mark.frame.maxX, rest.frame.minX < mark.frame.maxX + mark.frame.height * 2
            else { continue }
            lines[index] = TextRecognizer.Line(
                // "√" is written as the mark it is. "~" stays: it's as often a leading icon (an airplane before
                // a city's name) as a ticked box, and "✓ Seoul" would claim a selection (PITFALLS #65).
                text: (mark.text == "√" ? "✓" : mark.text) + " " + rest.text,
                frame: mark.frame.union(rest.frame), button: rest.button)
            lines.remove(at: index + 1)
        }
        // A captioned button whose glyph OCR read as a character or two (a swipe action's trash can as
        // "타") is that button, not text: named by its caption like the ones OCR left unread, or the
        // caption would be the only line with a meaning, and tapping it does nothing (PITFALLS #64).
        for (index, line) in lines.enumerated() {
            guard let button = line.button, line.text.count <= 2, !line.text.contains(where: \.isNumber),
                let caption = ScreenElements.caption(under: button, in: lines, px: CGFloat(scale))
            else { continue }
            lines[index] = TextRecognizer.Line(text: "[button] " + caption.text, frame: button)
        }
        lines = withoutTileGlyphs(lines, tiles: tiles, scale: CGFloat(scale))
        // "Keys are left out" is said only when they were: the looser `keyboardVisible` also fires on a
        // keypad (the Phone app's, the Calculator's), whose keys stay in the list.
        let keysTop = TextRecognizer.keysTop(in: lines, height: height)
        let keyboard = keysTop != nil
        if let keys = keysTop {
            lines.removeAll { $0.frame.midY > keys - height * 0.005 }
            controls.removeAll { $0.frame.midY > keys - height * 0.005 }
            // The suggestion bar right above the keys: two or three short words at the thirds of the
            // width. They came and went with every key typed (PITFALLS #65). A lone line there stays: a
            // chat's input field sits in the same place when there is no bar.
            let width = CGFloat(image.width), band = 56 * CGFloat(scale)
            let third = { (line: TextRecognizer.Line) -> Bool in
                line.frame.midY > keys - band && line.text.count <= 12
                    && [1.0 / 6, 0.5, 5.0 / 6].contains { abs(line.frame.midX / width - $0) < 0.07 }
            }
            if lines.filter(third).count >= 2 {
                lines.removeAll(where: third)
                controls.removeAll { $0.frame.midY > keys - band }
            }
        }
        // Status glyphs (battery, signal, focus moon) sit around the clock, or in the strip along the top.
        let clocks = statusClocks(lines, height: height)
        // Only on the clock's own row: four clock-heights reached the Calculator's history button below the
        // clock, which went missing whenever the device's clock matched this Mac's (PITFALLS #63).
        controls.removeAll { control in
            control.frame.midY < height * 0.032 || clocks.contains {
                near(control.frame, $0) && abs(control.frame.midY - $0.midY) < $0.height * 1.5
            }
        }
        // What OCR made of a ticked box's mark ("v", "✓") or of a pager's dots ("•••") is in the control's
        // own line already.
        let marks = controls.filter { $0.text.hasPrefix("[checkbox ") || $0.text.hasPrefix("[page dots]") }.map(\.frame)
        lines.removeAll { line in
            oneLine(line.text).count <= 2 || line.text.hasPrefix("[") || line.text.allSatisfy({ "•·.●∙ ".contains($0) })
                ? marks.contains { $0.insetBy(dx: -4 * CGFloat(scale), dy: -4 * CGFloat(scale)).contains(CGPoint(x: line.frame.midX, y: line.frame.midY)) }
                : false
        }
        lines = withoutStatusItems(lines, height: height) + pageDotsMerged(controls, scale: CGFloat(scale))
        // A caption that named its button is in that line already. Listed too, it was the line to press
        // by its look, and pressing it does nothing.
        let captioned = lines.filter { $0.text.hasPrefix("[button] ") || $0.text.hasPrefix("[circle button] ") }
        lines.removeAll { line in
            captioned.contains { button in
                button.text.hasSuffix("] " + line.text)
                    && ScreenElements.caption(under: button.frame, in: [line], px: CGFloat(scale)) != nil
            }
        }
        // Rows that are icon bars: two or more bracketed controls and no text of more than a character.
        let iconRows = lines.filter { $0.text.hasPrefix("[") }.map(\.frame)
        let wordRows = lines.filter { !$0.text.hasPrefix("[") && oneLine($0.text).count > 1 }.map(\.frame)
        func inIconBar(_ frame: CGRect) -> Bool {
            let sameRow = { (other: CGRect) in abs(other.midY - frame.midY) < frame.height / 2 }
            return iconRows.filter(sameRow).count >= 2 && !wordRows.contains(where: sameRow)
        }
        lines = lines.compactMap { line in
            var text = oneLine(line.text)
            // A lone chevron OCR read as "<" is the same control the shape matcher calls [chevron left];
            // one name for it, so an agent looking for the back button finds it either way.
            if ["<", "‹"].contains(text) { text = "[chevron left]" }
            if [">", "›"].contains(text) { text = "[chevron right]" }
            // Punctuation as tall as an icon is an icon OCR took a guess at: a tab bar's icon came out as
            // ":" in one read, "⅛" in the next and [icon] in a third, a changed line in every report.
            // A password's dots come out as a different mix of "•" and "." each read.
            if text.count >= 3, text.allSatisfy({ "•·.●∙".contains($0) }), text.contains(where: { $0 != "." }) {
                text = String(repeating: "•", count: text.count)
            }
            if text.count <= 2, line.frame.height >= 18 * CGFloat(scale),
                text.allSatisfy({ ":;'\"`°|·^=".contains($0) || ($0.isNumber && !$0.isASCII) })
            {
                text = "[icon]"
            }
            // A lone letter among icons is an icon OCR took for a letter: a tab bar without captions listed
            // its house as "A" and a reload arrow as "C" (PITFALLS #65). Digits stay: a keypad's key that
            // has no button shape sits among `[circle button]`s too.
            if text.count == 1, line.button == nil, text.first!.isLetter, text.first!.isASCII, inIconBar(line.frame) {
                text = "[icon]"
            }
            return text.isEmpty ? nil : TextRecognizer.Line(text: text, frame: line.frame, button: line.button)
        }
        // A popup's close button often floats beside the card on a translucent disc, over whatever is
        // behind: no flat color around it, so no shape was found (PITFALLS #66). It's one of the few
        // things the dimming layer doesn't cover, and that is how it's found.
        let bitmap = PointBitmap(image, scale: scale)
        if let bitmap {
            for index in ScreenState.selected(lines, in: bitmap) {
                lines[index] = TextRecognizer.Line(text: "[selected] " + lines[index].text, frame: lines[index].frame, button: lines[index].button)
            }
            let px = CGFloat(scale)
            let textInPoints = lines.filter { !$0.text.hasPrefix("[") }.map {
                CGRect(x: $0.frame.minX / px, y: $0.frame.minY / px, width: $0.frame.width / px, height: $0.frame.height / px)
            }
            for slider in ScreenState.sliders(in: bitmap, text: textInPoints) {
                // Whatever was made of the knob (an [icon], a [toggle]) is this.
                lines.removeAll { $0.text.hasPrefix("[") && slider.knob.insetBy(dx: -4 * px, dy: 0).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                lines.append(TextRecognizer.Line(text: "[slider \(Int((slider.value * 100).rounded()))%]", frame: slider.knob))
            }
        }
        let popup = bitmap.flatMap(ScreenState.popup)
        for piece in popup?.dropFirst() ?? [] where !lines.contains(where: { $0.frame.intersects(piece) || ($0.button?.intersects(piece) ?? false) }) {
            lines.append(TextRecognizer.Line(text: "[circle button]", frame: piece))
        }
        let overlay = popup == nil ? bitmap.map { bitmap in ScreenState.overlay(lines, in: bitmap).map { lines[$0].frame } } ?? [] : []
        return (readingOrder(lines), keyboard, popup, overlay)
    }

    /// A pager's dots as one line, `[page dots] 13`: a carousel of thirteen pictures listed thirteen
    /// `[icon]` lines, and each read found a different number of them (PITFALLS #65). Dots are small
    /// unnamed icons of one size in a row, evenly spaced.
    static func pageDotsMerged(_ controls: [TextRecognizer.Line], scale: CGFloat) -> [TextRecognizer.Line] {
        let dots = controls.indices.filter {
            controls[$0].text == "[icon]" && controls[$0].frame.width <= 12 * scale && controls[$0].frame.height <= 12 * scale
        }.sorted { controls[$0].frame.midX < controls[$1].frame.midX }
        var merged: [TextRecognizer.Line] = [], used = Set<Int>()
        for start in dots where !used.contains(start) {
            var run = [start]
            var pitch: CGFloat?
            for next in dots where !used.contains(next) && controls[next].frame.midX > controls[run.last!].frame.midX {
                let last = controls[run.last!].frame, frame = controls[next].frame
                guard abs(frame.midY - last.midY) < 2 * scale else { continue }
                let gap = frame.midX - last.midX
                guard gap <= 30 * scale, pitch.map({ abs(gap - $0) < $0 * 0.25 }) ?? true else { continue }
                pitch = pitch ?? gap
                run.append(next)
            }
            guard run.count >= 3 else { continue }
            used.formUnion(run)
            let frame = run.dropFirst().reduce(controls[run[0]].frame) { $0.union(controls[$1].frame) }
            merged.append(TextRecognizer.Line(text: "[page dots] \(run.count)", frame: frame))
        }
        return controls.indices.filter { !used.contains($0) }.map { controls[$0] } + merged
    }

    /// Drops what OCR read off the glyph of a row's leading icon (a Settings row's colored square): a
    /// few characters inside the tile, with the row's label right after it. "*" for Bluetooth or "이"
    /// for Wi-Fi said nothing, and pressing the label does the same (PITFALLS #62).
    static func withoutTileGlyphs(_ lines: [TextRecognizer.Line], tiles: [CGRect], scale: CGFloat) -> [TextRecognizer.Line] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let start = CGPoint(x: line.frame.minX + line.frame.height * 0.3, y: line.frame.midY)
            let mid = CGPoint(x: line.frame.midX, y: line.frame.midY)
            if text.count <= 4, let tile = tiles.first(where: { $0.insetBy(dx: -scale, dy: -scale).contains(mid) }) {
                let labelled = lines.contains { other in
                    other.frame.minX > tile.maxX && other.frame.minX - tile.maxX < 24 * scale
                        && abs(other.frame.midY - tile.midY) < tile.height * 0.7
                }
                return labelled ? nil : line
            }
            // The glyph read together with the label ("8 제어 센터"): the first word starts inside a tile and
            // the rest runs past it.
            guard let tile = tiles.first(where: { $0.contains(start) }), line.frame.maxX > tile.maxX + 24 * scale,
                let space = text.firstIndex(of: " "), text.distance(from: text.startIndex, to: space) <= 2
            else { return line }
            let rest = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            let cut = min(line.frame.maxX - 1, tile.maxX)
            return TextRecognizer.Line(
                text: rest, frame: CGRect(x: cut, y: line.frame.minY, width: line.frame.maxX - cut, height: line.frame.height),
                button: line.button)
        }
    }

    /// Drops the status items: the clock, battery level, carrier and signal glyphs OCR reads as text.
    ///
    /// Where they sit differs by device: a strip along the top on most iPhones and iPads, a floating pill at
    /// the right on the foldable iPhone, so neither a top band nor a corner can be cut. The clock is found
    /// by its value instead — the device shows the same time as this Mac — and short digit-like lines
    /// next to it go with it. Without a clock (misread, or hidden by a full-screen app) only short
    /// digit-like lines at the very top go: cutting more there loses an iPad's navigation title, which
    /// sits almost as high as its status bar (PITFALLS #48).
    static func withoutStatusItems(_ lines: [TextRecognizer.Line], height: CGFloat) -> [TextRecognizer.Line] {
        let clocks = statusClocks(lines, height: height)
        return lines.compactMap { line in
            if clocks.contains(line.frame) { return backBreadcrumb(in: line) }
            if let clock = clocks.first {
                // On the clock's own row a short line is a status glyph: the Wi-Fi fan and the battery came
                // out as "이4" in one read and "..이" in the next (PITFALLS #65).
                if line.text.count <= 4, abs(line.frame.midY - clock.midY) < clock.height * 0.6 { return nil }
                // Right under an iPhone's clock is the way back to the app that opened this one. Its arrow
                // read as "A", "•" or "<" from one read to the next, a changed line in every report.
                if line.frame.midY > clock.midY, line.frame.midY < height * 0.05, line.frame.minX < clock.maxX,
                    let space = line.text.firstIndex(of: " "), line.text.distance(from: line.text.startIndex, to: space) == 1
                {
                    return TextRecognizer.Line(text: "◀" + line.text[space...], frame: line.frame, button: line.button)
                }
            }
            guard statusLike(line.text) else { return line }
            if line.frame.midY < height * 0.05 { return nil }
            return clocks.contains { near(line.frame, $0) } ? nil : line
        }
    }

    /// "◀ Settings" in front of an iPad's clock, the way back to the app that opened this one. OCR reads it
    /// in one line with the clock and date, so it's cut out by its share of the characters; without this it
    /// went with the clock (PITFALLS #56).
    private static func backBreadcrumb(in line: TextRecognizer.Line) -> TextRecognizer.Line? {
        let words = line.text.split(separator: " ", omittingEmptySubsequences: false)
        guard let first = words.first, let marker = first.first, "◀<‹".contains(marker),
            let clock = words.firstIndex(where: { showsClock(String($0)) }), clock > 0
        else { return nil }
        let prefix = words[..<clock].joined(separator: " ")
        // The word before the clock is often the AM/PM marker ("오후", "PM"); it belongs to the clock.
        let kept = words[..<clock].count > 1 && ["AM", "PM", "오전", "오후"].contains(String(words[clock - 1]).uppercased())
            ? words[..<(clock - 1)].joined(separator: " ") : prefix
        let share = CGFloat(kept.count) / CGFloat(max(line.text.count, 1))
        let frame = CGRect(x: line.frame.minX, y: line.frame.minY, width: line.frame.width * share, height: line.frame.height)
        return TextRecognizer.Line(text: kept, frame: frame)
    }

    /// Where the status clock is (one, or none if it's hidden or misread).
    private static func statusClocks(_ lines: [TextRecognizer.Line], height: CGFloat) -> [CGRect] {
        lines.filter { line in
            if line.frame.midY < height * 0.3 && showsClock(line.text) { return true }
            // An iPad puts the date next to the clock and OCR reads both as one line ("9:41 Mon Jun 9").
            // Only at the very top: lower down, a line holding the current time is content (an alarm). PITFALLS #56.
            if line.frame.midY < height * 0.05 && line.text.count <= 30
                && line.text.split(separator: " ").contains(where: { showsClock(String($0)) })
            {
                return true
            }
            // Any time at all in the top strip, starting a short line: the device's time zone can differ from
            // this Mac's. Pinning the location to Cupertino moved the device's clock to Pacific time, and
            // "5:21" with the focus moon read as "C" stayed in the list (PITFALLS #63).
            guard line.frame.midY < height * 0.03, line.text.count <= 12,
                let first = line.text.split(separator: " ").first
            else { return false }
            // The focus moon often sticks to the minutes ("3:51L").
            let parts = first.split(separator: ":")
            guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count >= 2,
                !parts[1].dropFirst(2).contains(where: \.isNumber)
            else { return false }
            return Int(parts[0]).map { $0 <= 23 } == true && Int(parts[1].prefix(2)).map { $0 <= 59 } == true
        }.map(\.frame)
    }

    /// Within four clock-heights of the clock: the rest of the status items.
    private static func near(_ rect: CGRect, _ clock: CGRect) -> Bool {
        let reach = clock.height * 4
        return abs(rect.midX - clock.midX) < reach && abs(rect.midY - clock.midY) < reach
    }

    /// "9:41" matching this Mac's time within a minute, in 12- or 24-hour form.
    private static func showsClock(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        // The location arrow next to the clock is read into it as a stray character ("11:30①").
        guard parts.count == 2, (2...4).contains(parts[1].count),
            parts[1].dropFirst(2).allSatisfy({ !($0.isNumber && $0.isASCII) }),
            let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2))
        else { return false }
        let calendar = Calendar.current
        return [-60.0, 0, 60].contains { offset in
            let now = calendar.dateComponents([.hour, .minute], from: Date().addingTimeInterval(offset))
            guard let h = now.hour, let m = now.minute, m == minute else { return false }
            return hour == h || hour == (h + 11) % 12 + 1
        }
    }

    /// Battery ("80%", "80+" for the charging bolt), carrier ("5G", "LTE") or signal dots ("::;").
    private static func statusLike(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        // The VPN badge; its bracket glyph comes out as "{}" or "()" (PITFALLS #56).
        // With the Wi-Fi glyph and battery level beside it, OCR may read them as one line ("{} VPN ⑦ 80)").
        if text.filter({ $0.isLetter }).uppercased() == "VPN" && text.count <= 16 { return true }
        // The signal bars read as dots, often with the Wi-Fi glyph after them as a letter ("•••• 이", "....옛").
        if text.count <= 8, text.prefix(while: { ".•·∙".contains($0) }).count >= 3 { return true }
        guard !text.isEmpty, text.count <= 5 else { return false }
        if ["5G", "5G+", "5GE", "5G UC", "LTE", "4G", "3G", "SOS"].contains(text.uppercased()) { return true }
        return text.allSatisfy { $0.isNumber || ":;.,%+ ".contains($0) }
    }

    /// Top to bottom, then left to right within a row. Vision returns lines roughly by column, which puts
    /// a row's right-hand value after everything on the left.
    private static func readingOrder(_ lines: [TextRecognizer.Line]) -> [TextRecognizer.Line] {
        var rows: [[TextRecognizer.Line]] = []
        for line in lines.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let first = rows.last?.first, line.frame.midY - first.frame.midY < min(first.frame.height, line.frame.height) * 0.6 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// One capture. A screen that's off gives a black image, which reads as "no text".
    func capture() throws -> CGImage { try ScreenText.litImage(rsd: rsd) }

    /// Waits until the input reaches the device and the screen settles, and returns the settled frame.
    func settle() throws -> CGImage { try settleKeepingEarly().image }

    private func settleKeepingEarly() throws -> ScreenCapture.Settle {
        // If the reaction (press highlight, start of a transition) comes after the first capture, two frames
        // of the pre-input screen are taken as "settled".
        Thread.sleep(forTimeInterval: Self.reactionDelay)
        var settle = try ScreenCapture.settled(rsd: rsd, timeout: 6)
        guard !ScreenCapture.isDark(settle.image) else { throw ScreenText.Failure.screenOff }
        // A new screen often holds still while it loads (a splash, an article's blank page, a search's
        // first results) and fills in a second later: the list showed 2–9 lines and the agent had to run
        // `ui` again (PITFALLS #69). So a new screen gets another look a moment later, and settles again
        // if it changed.
        guard settle.transition || looksNew(settle.image) else { return settle }
        // Looked at again until a look finds no big change: values and pictures filling in on a
        // settings page cost a second settle for 1% of the screen, which read the same lines anyway.
        var looks = 0
        while looks < Self.maxLooks {
            looks += 1
            Thread.sleep(forTimeInterval: Self.lookAgainAfter)
            let change = try ScreenCapture.changedShare(settle.image, try ScreenCapture.image(rsd: rsd), ignoring: settle.moving)
            guard change.share >= Self.bigChange, try settleAgain(&settle) else { break }
        }
        settle.transition = true
        return settle
    }

    /// Settles again after the screen changed. False if the screen went dark.
    private func settleAgain(_ settle: inout ScreenCapture.Settle) throws -> Bool {
        let next = try ScreenCapture.settled(rsd: rsd, timeout: 4)
        guard !ScreenCapture.isDark(next.image) else { return false }
        // The early frames show the loading screen, not this one: a frame from them was read for a
        // moving banner, and the list showed the splash (`observeAfterAction`).
        settle = ScreenCapture.Settle(image: next.image, early: [], stable: next.stable, moving: next.moving, transition: true)
        return true
    }

    private static let reactionDelay = 0.3
    /// Before looking again. A capture itself takes 0.3–0.7 s, so the look lands about a second after
    /// the screen first held still; a loading article filled in about then.
    private static let lookAgainAfter = 0.2
    /// Share of the screen that has to change for a second settle: a loading screen replaced by its
    /// content changes far more.
    private static let bigChange = 0.025
    private static let maxLooks = 3
    /// A new screen with fewer lines than this is watched for up to `sparseWatch` seconds more. Loading
    /// screens read 2–9 lines; an app's real screens rarely have so few.
    private static let sparseLines = 10
    private static let sparseWatch = 3.0

    /// Most of the listed lines look different in `image`: a new screen, even when the change finished
    /// before the first frame of the wait (an app's splash screen).
    private func looksNew(_ image: CGImage) -> Bool {
        guard state.width == image.width, state.height == image.height else { return true }
        let checked = state.entries.compactMap { entry -> Bool? in
            guard let saved = entry.pixels.flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return ScreenCapture.sameArea([UInt8](saved), image, in: UIState.checkArea(entry.frame))
        }
        guard checked.count >= 3 else { return true }
        return checked.filter { !$0 }.count * 2 > checked.count
    }

    /// How long after the input a video player's controls are reliably up: they fade in about 0.8 s after
    /// a tap and hide again about 3 s later.
    private static let controlsUp = 1.2

    /// True when the last `observeAfterAction` read the frame at `controlsUp` instead of the settled one.
    private(set) var readEarly = false

    /// After an action: settles and compares. When part of the screen kept moving (a playing video), the
    /// frame about 1.2 s after the input is read instead of the settled one. A video player's controls
    /// appear late and hide on their own, so by the time a playing video counts as settled they were
    /// usually gone, and the list never showed them (PITFALLS #49).
    func observeAfterAction() throws -> Report {
        var settle = try settleKeepingEarly()
        readEarly = false
        if settle.moving != nil || !settle.stable,
            let early = settle.early.first(where: { $0.at + Self.reactionDelay >= Self.controlsUp }),
            !ScreenCapture.isDark(early.image)
        {
            readEarly = true
            return try observe(early.image)
        }
        var read = try Self.read(settle.image, scale: pointScale(for: settle.image))
        // A splash screen held still for two seconds before the app's first screen came (PITFALLS #69).
        // Waiting that long after every new screen would slow every step, so only a new screen with few
        // lines is watched for longer, and settled again on any change.
        if settle.transition, read.lines.count < Self.sparseLines {
            let deadline = Date().addingTimeInterval(Self.sparseWatch)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                guard try !ScreenCapture.unchanged(settle.image, try ScreenCapture.image(rsd: rsd), ignoring: settle.moving)
                else { continue }
                guard try settleAgain(&settle) else { break }
                read = try Self.read(settle.image, scale: pointScale(for: settle.image))
                if read.lines.count >= Self.sparseLines { break }
            }
        }
        return try observe(settle.image, read: read)
    }

    /// Pixels per point of the panel `image` came from, which `ScreenElements` sizes controls by. Kept with
    /// the list while the screen size stays (unfolding the foldable or turning an iPad changes it).
    private func pointScale(for image: CGImage) -> Int {
        let size = [image.width, image.height]
        if state.scaleSize == size, let scale = state.scale { return scale }
        let scale = (try? ScreenSize.query(rsd: rsd).pointScale).flatMap { $0 }.map { Int($0.rounded()) }
            ?? ScreenElements.guessScale(width: image.width, height: image.height)
        state.scale = scale
        state.scaleSize = size
        return scale
    }

    // MARK: - Comparing

    enum Report {
        case newScreen
        case sameScreen(
            changed: [(ref: Int, before: String, after: String)], added: [UIState.Entry],
            removed: [UIState.Entry], moved: [(ref: Int, was: CGRect)], unchanged: Int)
    }

    /// Reads `image`, matches it against the stored list, stores the result and saves the screenshot.
    func observe(
        _ image: CGImage, read: (lines: [TextRecognizer.Line], keyboard: Bool, popup: [CGRect]?, overlay: [CGRect])? = nil
    ) throws -> Report {
        var (lines, keyboard, popup, overlay) = try read ?? Self.read(image, scale: pointScale(for: image))
        try saveImage(image)
        let old = state
        // An icon named by `ui --icons` keeps its name while it stays put and looks the same, so the next read doesn't report
        // every named icon as changed back to [icon].
        if old.width == image.width, old.height == image.height {
            lines = lines.map { line in
                guard line.text == "[icon]",
                    let named = old.entries.first(where: {
                        $0.text.hasPrefix("[icon: ") && distance($0.frame, line.frame) < max(line.frame.width, line.frame.height) * 0.3
                    }),
                    // Same pixels too: a carousel puts a different picture in the same place.
                    let saved = named.pixels.flatMap({ Data(base64Encoded: $0) }),
                    ScreenCapture.sameArea([UInt8](saved), image, in: UIState.checkArea(named.frame))
                else { return line }
                return TextRecognizer.Line(text: named.text, frame: line.frame)
            }
        }
        let sameSize = old.width == image.width && old.height == image.height
        state.width = image.width
        state.height = image.height
        state.keyboard = keyboard
        state.popup = popup.map { $0.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } }
        state.overlay = overlay.isEmpty ? nil : overlay.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }

        guard sameSize, !old.entries.isEmpty else { return reset(lines, image) }

        let height = Double(image.height)
        var refs = [Int?](repeating: nil, count: lines.count)
        var used = Set<Int>()
        var moved: [(ref: Int, was: CGRect)] = []
        // Same text near the same place, nearest pairs first: in line order, a line could take the entry
        // that belonged to its neighbor, and a generic name ([circle button]) hopped between keys.
        var pairs: [(line: Int, entry: Int, distance: Double)] = []
        for (index, line) in lines.enumerated() {
            for (offset, entry) in old.entries.enumerated() where Self.sameText(entry.text, line.text) {
                let d = distance(entry.frame, line.frame)
                if d < height * 0.03 { pairs.append((index, offset, d)) }
            }
        }
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where refs[pair.line] == nil && !used.contains(pair.entry) {
            refs[pair.line] = old.entries[pair.entry].ref
            used.insert(pair.entry)
        }
        // Then same text farther away, only along with the rest of the list (it scrolled): the shift is the
        // median of the lines whose text appears once, before and after. Matching same text anywhere
        // gave the Calculator's 7 key's ref to the 7 that appeared in its display (PITFALLS #62).
        if let shift = listShift(lines: lines, refs: refs, old: old.entries, used: used) {
            for (index, line) in lines.enumerated() where refs[index] == nil {
                let expected = line.frame.offsetBy(dx: -shift.dx, dy: -shift.dy)
                let near = old.entries.enumerated().filter { !used.contains($0.offset) && Self.sameText($0.element.text, line.text) }
                    .min { distance($0.element.frame, expected) < distance($1.element.frame, expected) }
                guard let near, distance(near.element.frame, expected) < height * 0.03 else { continue }
                refs[index] = near.element.ref
                used.insert(near.offset)
                moved.append((near.element.ref, near.element.frame))
            }
        }
        var unchanged = refs.compactMap { $0 }.count
        // A few lines that moved while the rest stayed are news: a check mark that went to another row. When
        // many moved, the list scrolled, and listing every line would bury what changed.
        if moved.count * 4 <= unchanged - moved.count {
            unchanged -= moved.count
        } else {
            moved = []
        }
        // Different text in the same place: a field's contents, a value that changed.
        var changed: [(ref: Int, before: String, after: String)] = []
        for (index, line) in lines.enumerated() where refs[index] == nil {
            guard
                let match = old.entries.enumerated().first(where: {
                    !used.contains($0.offset) && sameSpot($0.element.frame, line.frame)
                })
            else { continue }
            refs[index] = match.element.ref
            used.insert(match.offset)
            changed.append((match.element.ref, match.element.text, line.text))
        }

        let kept = unchanged + changed.count
        if kept * 2 < max(old.entries.count, lines.count) { return reset(lines, image) }

        var nextRef = old.nextRef
        var added: [UIState.Entry] = []
        state.entries = lines.enumerated().map { index, line in
            if let ref = refs[index] { return UIState.Entry(ref: ref, line: line, image: image) }
            let entry = UIState.Entry(ref: nextRef, line: line, image: image)
            nextRef += 1
            added.append(entry)
            return entry
        }
        state.nextRef = nextRef
        let removed = old.entries.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        return .sameScreen(changed: changed, added: added, removed: removed, moved: moved, unchanged: unchanged)
    }

    /// How far the unmatched lines moved together, from those whose text is distinctive (three or more
    /// characters, not a bracketed control) and appears once among the unmatched lines on both sides.
    /// Nil with fewer than two of them: one line moving alone says nothing about the rest.
    private func listShift(lines: [TextRecognizer.Line], refs: [Int?], old: [UIState.Entry], used: Set<Int>)
        -> (dx: Double, dy: Double)?
    {
        let open = lines.indices.filter { refs[$0] == nil }.map { lines[$0] }
        let left = old.indices.filter { !used.contains($0) }.map { old[$0] }
        var dx: [Double] = [], dy: [Double] = []
        for line in open where line.text.count >= 3 && !line.text.hasPrefix("[") {
            guard open.filter({ Self.sameText($0.text, line.text) }).count == 1 else { continue }
            let same = left.filter { Self.sameText($0.text, line.text) }
            guard same.count == 1, let entry = same.first else { continue }
            dx.append(line.frame.midX - entry.frame.midX)
            dy.append(line.frame.midY - entry.frame.midY)
        }
        guard dx.count >= 2 else { return nil }
        return (dx.sorted()[dx.count / 2], dy.sorted()[dy.count / 2])
    }

    private func reset(_ lines: [TextRecognizer.Line], _ image: CGImage) -> Report {
        state.entries = lines.enumerated().map { UIState.Entry(ref: $0.offset + 1, line: $0.element, image: image) }
        state.nextRef = lines.count + 1
        return .newScreen
    }

    /// The same line read twice. Case aside: OCR flips it between reads ("Row 2" then "ROW 2" for the
    /// same pixels' neighbor), and each flip showed as one line removed and another added, or made
    /// `press` say the line was gone (PITFALLS #64).
    /// So is one letter inside a word of a longer line ("subtitle of" then "subtitle ot"). A digit, or a
    /// letter standing alone ("Plan A" to "Plan B"), is a real change.
    static func sameText(_ a: String, _ b: String) -> Bool {
        if a == b || a.caseInsensitiveCompare(b) == .orderedSame { return true }
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard x.count == y.count, x.count >= 8 else { return false }
        let differing = x.indices.filter { x[$0] != y[$0] }
        guard differing.count == 1, let at = differing.first, x[at].isLetter, y[at].isLetter else { return false }
        return (at > 0 && x[at - 1].isLetter) || (at + 1 < x.count && x[at + 1].isLetter)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> Double {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// On the same row and starting at about the same x (a field whose text changed, a label that grew).
    private func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < max(a.height, b.height) * 0.5 && abs(a.minX - b.minX) < max(a.height, b.height) * 1.5
    }

    /// Saves the screenshot with the grid; with `boxes`, also each listed line's box and ref (`ui --boxes`),
    /// which needs the refs, so it's saved again after the list is made.
    func saveImage(_ image: CGImage, boxes: Bool = false) throws {
        let width = min(Self.imageWidth, image.width)
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        let base = width == image.width ? image : try ScreenCapture.resize(image, width: width, height: height)
        let grid = ScreenGrid(width: Double(image.width), height: Double(image.height), pointScale: state.scale.map(Double.init))
        let outlined = boxes ? state.entries.map { (rect: $0.box, label: "t\($0.ref)") } : []
        let (data, _) = try ScreenCapture.encode(try grid.draw(on: base, boxes: outlined))
        let url = UIState.imageURL(udid: udid)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - Naming icons

    /// Asks the on-device model to name the unnamed `[icon]` entries (`ui --icons`), in place.
    func nameIcons(in image: CGImage) {
        let unnamed = state.entries.indices.filter { state.entries[$0].text == "[icon]" }
        guard !unnamed.isEmpty else { return }
        if let reason = IconNamer.unavailableReason {
            print("(--icons: \(reason); icons stay [icon])")
            return
        }
        let asked = Array(unnamed.prefix(IconNamer.limit))
        let names = IconNamer.names(
            for: asked.map { state.entries[$0].frame }, in: image, pointScale: pointScale(for: image))
        for (index, name) in zip(asked, names) {
            if let name { state.entries[index].text = "[icon: \(name)]" }
        }
        if unnamed.count > asked.count {
            print("(--icons: named the first \(asked.count) of \(unnamed.count) icons; run it again for the rest)")
        }
    }

    // MARK: - Finding a line to press

    func entry(_ ref: Int) throws -> UIState.Entry {
        guard !state.entries.isEmpty else { throw UIError.noList }
        guard let entry = state.entries.first(where: { $0.ref == ref }) else {
            throw UIError.unknownRef(ref, last: state.entries.map(\.ref).max() ?? 0)
        }
        return entry
    }

    /// Where `entry` is on the screen now. Normally exactly where it was read. If that spot changed (the list
    /// scrolled a little, something loaded above), the line is looked up again by its text, and used only if
    /// it appears exactly once.
    func locate(_ entry: UIState.Entry) throws -> (rect: CGRect, moved: Bool) {
        let image = try capture()
        if image.width == state.width, image.height == state.height,
            let saved = entry.pixels.flatMap({ Data(base64Encoded: $0) }),
            ScreenCapture.sameArea([UInt8](saved), image, in: UIState.checkArea(entry.frame))
        {
            return (entry.frame, false)
        }
        // A named icon is plain [icon] to a fresh read.
        let wanted = entry.text.hasPrefix("[icon: ") ? "[icon]" : entry.text
        let matches = try Self.read(image, scale: pointScale(for: image)).lines.filter { Self.sameText($0.text, wanted) }
        guard matches.count == 1, let line = matches.first else { throw UIError.stale(entry.text) }
        return (line.frame, true)
    }

    // MARK: - Printing

    /// Turns newlines and tabs into spaces so one line of output stays one line.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The grid cell under a line's center, as named on the saved screenshot.
    func cell(_ entry: UIState.Entry) -> String { cell(entry.frame) }

    func cell(_ rect: CGRect) -> String {
        let grid = ScreenGrid(width: Double(state.width), height: Double(state.height), pointScale: state.scale.map(Double.init))
        let column = min(grid.columns - 1, max(0, Int(rect.midX / grid.cell)))
        let row = min(grid.rows - 1, max(0, Int(rect.midY / grid.cell)))
        return grid.name(column: column, row: row)
    }

    func line(_ entry: UIState.Entry) -> String { "@t\(entry.ref)\t\(entry.text)\t\(cell(entry))" }

    var imageNote: String {
        "Screenshot: \(UIState.imageURL(udid: udid).path) (grid cells as in the third column; [bracketed] lines are controls found by their shape — check the image when it matters)"
    }

    func printList(_ entries: [UIState.Entry]) {
        if state.entries.isEmpty { print("(no text on this screen — look at the screenshot)") }
        for entry in entries { print(line(entry)) }
        printNotes()
        print(imageNote)
    }

    /// What holds for the whole screen: the keyboard, a popup.
    func printNotes() {
        if state.keyboard { print("(the on-screen keyboard is up; its keys are left out)") }
        if let rects = state.overlay?.map({ CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }) {
            let on = state.entries.filter { entry in rects.contains { $0.intersects(entry.frame.insetBy(dx: 2, dy: 2)) } }
            let refs = on.map { "@t\($0.ref)" }.joined(separator: " ")
            print("(the screen is dimmed under an overlay, like a tip or a tutorial. On it: \(refs). The other lines are behind it and won't react until it's closed; a button on it (OK, Close, ✕) usually closes it)")
        }
        guard let rects = state.popup?.map({ CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }), let card = rects.first else { return }
        let on = state.entries.filter { entry in rects.contains { $0.contains(CGPoint(x: entry.frame.midX, y: entry.frame.midY)) } }
        let refs = on.map { "@t\($0.ref)" }.joined(separator: " ")
        print("(a popup is up around \(cell(card)), over a dimmed screen. On it: \(refs.isEmpty ? "no listed line" : refs). The other lines are behind it and won't react until it's closed; if no line closes it, find its ✕ on the screenshot and tap that cell)")
    }

    func printReport(_ report: Report) {
        if readEarly {
            print("(part of the screen keeps moving, like a video or a running timer: read 1.2 s after the input, while a video's self-hiding controls are up. Over a video they may be gone by your next command: if press says the line moved, tap the video to bring them back and press within a second or two, chaining with --no-ui. A running timer's digits change on every read; that's expected)")
        }
        switch report {
        case .newScreen:
            print("New screen — \(state.entries.count) lines")
            printList(state.entries)
        case .sameScreen(let changed, let added, let removed, let moved, let unchanged):
            if changed.isEmpty, added.isEmpty, removed.isEmpty, moved.isEmpty {
                print("Same screen — no line changed (\(unchanged) unchanged). Check the screenshot: something without a line (an image, a color) may have changed; if nothing reacted, pick a different target.")
                printNotes()
                print(imageNote)
                return
            }
            let movedCount = moved.isEmpty ? "" : ", moved \(moved.count)"
            print("Same screen — changed \(changed.count), added \(added.count), removed \(removed.count)\(movedCount), unchanged \(unchanged)")
            for item in changed {
                if let entry = state.entries.first(where: { $0.ref == item.ref }) {
                    print("changed\t\(line(entry))\t(was: \(item.before))")
                }
            }
            for entry in added { print("added\t\(line(entry))") }
            for entry in removed { print("removed\t@t\(entry.ref)\t\(entry.text)") }
            for item in moved {
                if let entry = state.entries.first(where: { $0.ref == item.ref }) {
                    print("moved\t\(line(entry))\t(was: \(cell(item.was)))")
                }
            }
            printNotes()
            print(imageNote)
        }
    }

    /// The list appended after action commands. The action itself succeeded, so a failure to read the screen
    /// doesn't fail the command — it's said in one line.
    static func report(afterActionOn udid: String?) {
        do {
            try with(udid: udid) { screen in
                screen.printReport(try screen.observeAfterAction())
            }
        } catch {
            print("(could not read the screen: \(error))")
        }
    }
}
