import CoreGraphics
import Foundation

/// The text lines read off the last screenshot, with refs (`@tN`), kept between commands.
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

        var frame: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }

        init(ref: Int, line: TextRecognizer.Line, image: CGImage) {
            self.ref = ref
            text = line.text
            let r = line.frame
            rect = [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 }
            pixels = ScreenCapture.areaPixels(image, in: UIState.checkArea(r)).map { Data($0).base64EncodedString() }
        }
    }

    var udid: String
    var width = 0
    var height = 0
    var entries: [Entry] = []
    var keyboard = false
    var nextRef = 1

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

    /// The text lines of a screenshot in reading order, without the status bar and the keyboard keys.
    static func read(_ image: CGImage) throws -> (lines: [TextRecognizer.Line], keyboard: Bool) {
        let height = CGFloat(image.height)
        var lines = try TextRecognizer.lines(in: image)
        let keyboard = TextRecognizer.keyboardVisible(in: lines, height: height)
        if let keys = TextRecognizer.keysTop(in: lines, height: height) {
            lines.removeAll { $0.frame.midY > keys - height * 0.005 }
        }
        lines.removeAll { isStatusBar($0, height: height) }
        lines = lines.compactMap { line in
            let text = oneLine(line.text)
            return text.isEmpty ? nil : TextRecognizer.Line(text: text, frame: line.frame)
        }
        return (readingOrder(lines), keyboard)
    }

    /// The clock, battery and signal at the very top. Only short digit-like lines go: on an iPad the
    /// navigation bar's title sits almost as high as the status bar, so cutting by height alone loses it.
    private static func isStatusBar(_ line: TextRecognizer.Line, height: CGFloat) -> Bool {
        guard line.frame.midY < height * 0.05 else { return false }
        let text = line.text.trimmingCharacters(in: .whitespaces)
        if ["5G", "5G+", "5GE", "LTE", "4G", "3G", "SOS"].contains(text.uppercased()) { return true }
        return !text.isEmpty && text.allSatisfy { $0.isNumber || ":%. ".contains($0) }
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
    func settle() throws -> CGImage {
        // If the reaction (press highlight, start of a transition) comes after the first capture, two frames
        // of the pre-input screen are taken as "settled".
        Thread.sleep(forTimeInterval: 0.3)
        let image = try ScreenCapture.settled(rsd: rsd, timeout: 6).image
        guard !ScreenCapture.isDark(image) else { throw ScreenText.Failure.screenOff }
        return image
    }

    // MARK: - Comparing

    enum Report {
        case newScreen
        case sameScreen(
            changed: [(ref: Int, before: String, after: String)], added: [UIState.Entry],
            removed: [UIState.Entry], unchanged: Int)
    }

    /// Reads `image`, matches it against the stored list, stores the result and saves the screenshot.
    func observe(_ image: CGImage) throws -> Report {
        let (lines, keyboard) = try Self.read(image)
        try saveImage(image)
        let old = state
        let sameSize = old.width == image.width && old.height == image.height
        state.width = image.width
        state.height = image.height
        state.keyboard = keyboard

        guard sameSize, !old.entries.isEmpty else { return reset(lines, image) }

        let height = Double(image.height)
        var refs = [Int?](repeating: nil, count: lines.count)
        var used = Set<Int>()
        // Same text near the same place, then same text anywhere (the list moved).
        for pass in 0..<2 {
            for (index, line) in lines.enumerated() where refs[index] == nil {
                let candidates = old.entries.enumerated().filter { !used.contains($0.offset) && $0.element.text == line.text }
                let near = candidates.min { distance($0.element.frame, line.frame) < distance($1.element.frame, line.frame) }
                guard let near, pass == 1 || distance(near.element.frame, line.frame) < height * 0.03 else { continue }
                refs[index] = near.element.ref
                used.insert(near.offset)
            }
        }
        let unchanged = refs.compactMap { $0 }.count
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
        return .sameScreen(changed: changed, added: added, removed: removed, unchanged: unchanged)
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

    private func saveImage(_ image: CGImage) throws {
        let width = min(Self.imageWidth, image.width)
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        let base = width == image.width ? image : try ScreenCapture.resize(image, width: width, height: height)
        let grid = ScreenGrid(width: Double(image.width), height: Double(image.height))
        let (data, _) = try ScreenCapture.encode(try grid.draw(on: base))
        let url = UIState.imageURL(udid: udid)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
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
        let matches = try Self.read(image).lines.filter { $0.text == entry.text }
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
    func cell(_ entry: UIState.Entry) -> String {
        let grid = ScreenGrid(width: Double(state.width), height: Double(state.height))
        let column = min(grid.columns - 1, Int(entry.frame.midX / grid.cell))
        let row = min(grid.rows - 1, Int(entry.frame.midY / grid.cell))
        return grid.name(column: column, row: row)
    }

    func line(_ entry: UIState.Entry) -> String { "@t\(entry.ref)\t\(entry.text)\t\(cell(entry))" }

    var imageNote: String {
        "Screenshot: \(UIState.imageURL(udid: udid).path) (grid cells as in the third column; icons without text: touch --cell)"
    }

    func printList(_ entries: [UIState.Entry]) {
        if state.entries.isEmpty { print("(no text on this screen — look at the screenshot)") }
        for entry in entries { print(line(entry)) }
        if state.keyboard { print("(the on-screen keyboard is up; its keys are left out)") }
        print(imageNote)
    }

    func printReport(_ report: Report) {
        switch report {
        case .newScreen:
            print("New screen — \(state.entries.count) text lines")
            printList(state.entries)
        case .sameScreen(let changed, let added, let removed, let unchanged):
            if changed.isEmpty, added.isEmpty, removed.isEmpty {
                print("Same screen — no text changed (\(unchanged) unchanged). Check the screenshot: a toggle or an icon may have changed; if nothing reacted, pick a different target.")
                print(imageNote)
                return
            }
            print("Same screen — changed \(changed.count), added \(added.count), removed \(removed.count), unchanged \(unchanged)")
            for item in changed {
                if let entry = state.entries.first(where: { $0.ref == item.ref }) {
                    print("changed\t\(line(entry))\t(was: \(item.before))")
                }
            }
            for entry in added { print("added\t\(line(entry))") }
            for entry in removed { print("removed\t@t\(entry.ref)\t\(entry.text)") }
            if state.keyboard { print("(the on-screen keyboard is up; its keys are left out)") }
            print(imageNote)
        }
    }

    /// The list appended after action commands. The action itself succeeded, so a failure to read the screen
    /// doesn't fail the command — it's said in one line.
    static func report(afterActionOn udid: String?) {
        do {
            try with(udid: udid) { screen in
                screen.printReport(try screen.observe(try screen.settle()))
            }
        } catch {
            print("(could not read the screen: \(error))")
        }
    }
}
