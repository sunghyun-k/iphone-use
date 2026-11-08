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
    case badRef(String)
    case stale(String)
    case noKeyboard
    case rowNotSwipeable(String)

    var description: String {
        switch self {
        case .noList:
            return "No text list. Run ui first."
        case .unknownRef(let ref, let last):
            return "@t\(ref) is not in the list (last ref is @t\(last)). Run ui to get a fresh list."
        case .badRef(let text):
            return "\(text) is not a ref. Pass a ref from the ui list, like @t12."
        case .stale(let text):
            return """
                "\(text)" is no longer where the list saw it, and it isn't anywhere else on the screen once — the \
                screen changed since the list was taken. Did not press. Run ui to get a fresh list.
                """
        case .noKeyboard:
            return """
                The on-screen keyboard did not appear — this doesn't look like a text field. Did not type (typing \
                without focus sends keys to app shortcuts). Look at the screenshot, pick the field (its placeholder \
                text, or touch --cell for an empty one) and call type again.
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
    static func read(_ image: CGImage, scale: Int) throws -> (lines: [TextRecognizer.Line], keyboard: Bool) {
        let height = CGFloat(image.height)
        var lines = try TextRecognizer.lines(in: image)
        // Found against all the text, so glyphs OCR already read (status items included) aren't repeated.
        var (controls, buttons) = ScreenElements.find(in: image, text: lines, scale: scale)
        for (index, button) in buttons { lines[index].button = button }
        // "Keys are left out" is said only when they were: the looser `keyboardVisible` also fires on a
        // keypad (the Phone app's, the Calculator's), whose keys stay in the list.
        let keysTop = TextRecognizer.keysTop(in: lines, height: height)
        let keyboard = keysTop != nil
        if let keys = keysTop {
            lines.removeAll { $0.frame.midY > keys - height * 0.005 }
            controls.removeAll { $0.frame.midY > keys - height * 0.005 }
        }
        // Status glyphs (battery, signal, focus moon) sit around the clock, or in the strip along the top.
        let clocks = statusClocks(lines, height: height)
        controls.removeAll { control in
            control.frame.midY < height * 0.032 || clocks.contains { near(control.frame, $0) }
        }
        lines = withoutStatusItems(lines, height: height) + controls
        lines = lines.compactMap { line in
            var text = oneLine(line.text)
            // A lone chevron OCR read as "<" is the same control the shape matcher calls [chevron left];
            // one name for it, so an agent looking for the back button finds it either way.
            if ["<", "‹"].contains(text) { text = "[chevron left]" }
            if [">", "›"].contains(text) { text = "[chevron right]" }
            return text.isEmpty ? nil : TextRecognizer.Line(text: text, frame: line.frame, button: line.button)
        }
        return (readingOrder(lines), keyboard)
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
            return line.frame.midY < height * 0.05 && line.text.count <= 30
                && line.text.split(separator: " ").contains { showsClock(String($0)) }
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
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return false
        }
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
        let settle = try ScreenCapture.settled(rsd: rsd, timeout: 6)
        guard !ScreenCapture.isDark(settle.image) else { throw ScreenText.Failure.screenOff }
        return settle
    }

    private static let reactionDelay = 0.3

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
        let settle = try settleKeepingEarly()
        readEarly = false
        if settle.moving != nil || !settle.stable,
            let early = settle.early.first(where: { $0.at + Self.reactionDelay >= Self.controlsUp }),
            !ScreenCapture.isDark(early.image)
        {
            readEarly = true
            return try observe(early.image)
        }
        return try observe(settle.image)
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
    func observe(_ image: CGImage) throws -> Report {
        var (lines, keyboard) = try Self.read(image, scale: pointScale(for: image))
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

        guard sameSize, !old.entries.isEmpty else { return reset(lines, image) }

        let height = Double(image.height)
        var refs = [Int?](repeating: nil, count: lines.count)
        var used = Set<Int>()
        var moved: [(ref: Int, was: CGRect)] = []
        // Same text near the same place, then same text anywhere (the list moved).
        for pass in 0..<2 {
            for (index, line) in lines.enumerated() where refs[index] == nil {
                let candidates = old.entries.enumerated().filter { !used.contains($0.offset) && $0.element.text == line.text }
                let near = candidates.min { distance($0.element.frame, line.frame) < distance($1.element.frame, line.frame) }
                guard let near, pass == 1 || distance(near.element.frame, line.frame) < height * 0.03 else { continue }
                refs[index] = near.element.ref
                used.insert(near.offset)
                if pass == 1 { moved.append((near.element.ref, near.element.frame)) }
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

    private func reset(_ lines: [TextRecognizer.Line], _ image: CGImage) -> Report {
        state.entries = lines.enumerated().map { UIState.Entry(ref: $0.offset + 1, line: $0.element, image: image) }
        state.nextRef = lines.count + 1
        return .newScreen
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
        let matches = try Self.read(image, scale: pointScale(for: image)).lines.filter { $0.text == wanted }
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
        if state.keyboard { print("(the on-screen keyboard is up; its keys are left out)") }
        print(imageNote)
    }

    func printReport(_ report: Report) {
        if readEarly {
            print("(part of the screen keeps moving, like a video: read 1.2 s after the input, while self-hiding controls are up. They may be gone by your next command: if press says the line moved, tap the video to bring them back and press within a second or two, chaining with --no-ui)")
        }
        switch report {
        case .newScreen:
            print("New screen — \(state.entries.count) lines")
            printList(state.entries)
        case .sameScreen(let changed, let added, let removed, let moved, let unchanged):
            if changed.isEmpty, added.isEmpty, removed.isEmpty, moved.isEmpty {
                print("Same screen — no line changed (\(unchanged) unchanged). Check the screenshot: something without a line (an image, a color) may have changed; if nothing reacted, pick a different target.")
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
            if state.keyboard { print("(the on-screen keyboard is up; its keys are left out)") }
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
