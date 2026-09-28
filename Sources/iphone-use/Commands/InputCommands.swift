import ArgumentParser
import Foundation

/// Shared setup for commands that need HID input.
///
/// Opens tunnel -> RSD -> HID service in one go and asks for the screen size so pixel coordinates can be
/// normalized.
final class InputSession {
    let rsd: RemoteServiceDiscovery
    let hid: HIDService
    let screen: ScreenSize
    private var closed = false

    private init(rsd: RemoteServiceDiscovery, hid: HIDService, screen: ScreenSize) {
        self.rsd = rsd
        self.hid = hid
        self.screen = screen
    }

    static func open(udid: String?) throws -> InputSession {
        let rsd = try SessionPool.rsd(udid: udid)
        let screen = try SessionPool.screen(udid: udid, rsd: rsd)
        let hid = try SessionPool.hid(udid: udid, rsd: rsd)
        return InputSession(rsd: rsd, hid: hid, screen: screen)
    }

    /// Waits until the sent input has reached the device, then releases (`SessionPool.release`). Safe to
    /// call twice — `--shot` closes first before capturing, and `defer` calls it again.
    func close() {
        guard !closed else { return }
        closed = true
        SessionPool.release(hid)
        SessionPool.release(rsd)
    }

    func normalized(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
        screen.normalize(x: x, y: y)
    }

    /// Converts coordinates read off a downscaled image into device pixels. Unchanged without `imageWidth`.
    func devicePoint(_ x: Double, _ y: Double, imageWidth: Double?) -> (x: Double, y: Double) {
        guard let imageWidth, imageWidth > 0 else { return (x, y) }
        let scale = screen.width / imageWidth
        return (x * scale, y * scale)
    }
}

/// Shared option that fetches the screen after an action.
///
/// An agent has to "wait, then screenshot" after every action to see the result. As separate calls that's
/// three commands, and guessing the wait time leads to looking at the pre-input screen and misjudging.
/// `--shot` waits, after the input has reached the device (`InputSession.close`), for the screen to settle
/// and saves one image.
struct ShotOptions: ParsableArguments {
    @Option(
        name: .customLong("shot"),
        help: "After the action, wait for the screen to settle and save a screenshot (PNG, full resolution) here.")
    var path: String?

    /// Returns the saved screen (nil without `--shot`), so the caller can compare it with the pre-action screen.
    @discardableResult
    func capture(after session: InputSession?, udid: String?) throws -> ScreenCapture.Settle? {
        session?.close()
        guard let path else { return nil }

        let rsd = try SessionPool.rsd(udid: udid)
        defer { SessionPool.release(rsd) }
        // If the reaction to the input (press highlight, start of a transition) comes later than the first
        // capture, two pre-input frames get taken as "settled". Give the reaction a moment to start.
        Thread.sleep(forTimeInterval: 0.3)
        let settle = try ScreenCapture.settled(rsd: rsd, timeout: 6)
        let image = settle.image
        let (data, _) = try ScreenCapture.encode(image)
        try data.write(to: URL(fileURLWithPath: path))
        let state =
            !settle.stable
            ? ", still moving"
            : settle.moving.map { ", \(ScreenCapture.describe($0)) keeps moving (video etc.) — the rest has settled" } ?? ""
        print("Screen \(path) (\(image.width)x\(image.height)\(state))")
        if ScreenCapture.isDark(image) { print(ScreenCapture.darkNotice) }
        return settle
    }
}

/// Taps a coordinate.
struct TouchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Tap a screen coordinate or grid cell (screenshot pixels).",
        discussion: """
            Coordinates: touch X Y [--image-width W]. Grid cell: touch --cell C12 — the cell name printed on a
            screenshot --grid image. Cell names work as-is even on a downscaled image (no --image-width needed).
            """
    )

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(help: "X coordinate (screenshot pixels).")
    var x: Double?

    @Argument(help: "Y coordinate (screenshot pixels).")
    var y: Double?

    @Option(name: .long, help: "Cell name from screenshot --grid (C12). Taps the center of that cell.")
    var cell: String?

    @Option(name: .long, help: "Grid density. Must match screenshot --grid-size.")
    var gridSize = ScreenGrid.defaultDensity

    @Option(name: .long, help: "Hold time (seconds). 0.6 or more for a long press.")
    var hold: Double = 0.08

    @Option(
        name: .long,
        help: "If you read the coordinates off an image downscaled to this width, that width. Converted to device pixels.")
    var imageWidth: Double?

    func validate() throws {
        switch (x, y, cell) {
        case (.some, .some, nil), (nil, nil, .some): return
        default: throw ValidationError("Give exactly one of: touch X Y, or touch --cell C12.")
        }
    }

    func run() throws {
        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        let (x, y): (Double, Double)
        if let cell {
            let layout = ScreenGrid(width: session.screen.width, height: session.screen.height, density: gridSize)
            let rect = try layout.rect(named: cell)
            (x, y) = (rect.midX, rect.midY)
        } else {
            (x, y) = session.devicePoint(self.x!, self.y!, imageWidth: imageWidth)
        }
        let point = session.normalized(x, y)
        if hold >= 0.4 {
            try session.hid.press(x: point.x, y: point.y, duration: hold)
        } else {
            try session.hid.tap(x: point.x, y: point.y, hold: hold)
        }
        print("Tapped \(cell.map { "\($0.uppercased()) " } ?? "")(\(Int(x)), \(Int(y)))")
        try shot.capture(after: session, udid: device.udid)
    }
}

/// A swipe between two points.
struct SwipeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two coordinates (screenshot pixels).",
        discussion: """
            Starting within 4 pixels of the screen edge gets intercepted as a system gesture (Control Center,
            app switcher, back). To scroll app content, start well away from the edges.
            """
    )

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(help: "Start X.") var x1: Double?
    @Argument(help: "Start Y.") var y1: Double?
    @Argument(help: "End X.") var x2: Double?
    @Argument(help: "End Y.") var y2: Double?

    @Option(name: .long, help: "Start cell from screenshot --grid (C12). Use with --to.")
    var from: String?

    @Option(name: .long, help: "End cell (C4).")
    var to: String?

    @Option(name: .long, help: "Grid density. Must match screenshot --grid-size.")
    var gridSize = ScreenGrid.defaultDensity

    @Option(name: .long, help: "Gesture duration (seconds). Shorter flicks harder (momentum scrolling).")
    var duration: Double = 0.35

    @Option(
        name: .long,
        help: "If you read the coordinates off an image downscaled to this width, that width. Converted to device pixels.")
    var imageWidth: Double?

    func validate() throws {
        let points = [x1, y1, x2, y2].compactMap { $0 }.count
        guard (points == 4 && from == nil && to == nil) || (points == 0 && from != nil && to != nil) else {
            throw ValidationError("Give exactly one of: swipe X1 Y1 X2 Y2, or swipe --from C12 --to C4.")
        }
    }

    func run() throws {
        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        let start: (x: Double, y: Double)
        let end: (x: Double, y: Double)
        if let from, let to {
            let layout = ScreenGrid(width: session.screen.width, height: session.screen.height, density: gridSize)
            let (a, b) = (try layout.rect(named: from), try layout.rect(named: to))
            (start, end) = ((a.midX, a.midY), (b.midX, b.midY))
        } else {
            start = session.devicePoint(x1!, y1!, imageWidth: imageWidth)
            end = session.devicePoint(x2!, y2!, imageWidth: imageWidth)
        }
        try session.hid.swipe(
            from: session.normalized(start.x, start.y), to: session.normalized(end.x, end.y),
            duration: duration)
        print("Swiped (\(Int(start.x)), \(Int(start.y))) -> (\(Int(end.x)), \(Int(end.y)))")
        try shot.capture(after: session, udid: device.udid)
    }
}

/// Scrolls in a direction without coordinates.
///
/// `swipe` needs coordinates, and starting at an edge leaks into a system gesture. This command uses a
/// line through the middle of the screen and, by default, pauses at the end before lifting to kill
/// momentum — a flick travels an unknown distance, so the next screen can't be predicted.
struct ScrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll content up, down, left or right.",
        discussion: "down means going to see content further down (the finger pushes up)."
    )

    enum Direction: String, ExpressibleByArgument, CaseIterable {
        case up, down, left, right
    }

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(help: "Direction: up, down, left, right.")
    var direction: Direction

    @Option(name: .long, help: "Drag distance as a fraction of the screen size (0.1-0.8). Actual movement is a bit less.")
    var amount: Double = 0.5

    @Option(name: .long, help: "Drag duration (seconds).")
    var duration: Double = 0.5

    @Flag(name: .long, help: "Flick instead of pausing at the end, so momentum carries it far. For reaching the end of a long list fast.")
    var fling = false

    func validate() throws {
        guard (0.1...0.8).contains(amount) else {
            throw ValidationError("--amount is 0.1-0.8. To go further, call it several times or use --fling.")
        }
    }

    func run() throws {
        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        let width = session.screen.width
        let height = session.screen.height

        // If the keyboard is up, drag only above it. Passing over keys types characters.
        let image = try ScreenCapture.image(rsd: session.rsd)
        let keyboard = TextRecognizer.keyboardTop(
            in: try TextRecognizer.lines(in: image), height: CGFloat(image.height)
        ).map { Double($0) / Double(image.height) }
        // The bottom 20% is where bars live: Safari's address/tab bar, Music's mini player. Dragging up
        // from there moves the bar, not the content — `scroll down --amount 0.7` started at 85% of the
        // screen (the iPhone Safari address bar) and opened the tab overview. The top 10% is the status
        // bar / Notification Center pull area, so avoid it too.
        let top = 0.1
        let bottom = min(keyboard ?? 1, 0.8)
        let middle = (top + bottom) / 2

        // To see content further down, the finger pushes up.
        let span = (bottom - top) * 0.9
        let vertical = min(amount, span) / 2
        let horizontal = amount / 2
        let (from, to): ((Double, Double), (Double, Double)) =
            switch direction {
            case .down: ((0.5, middle + vertical), (0.5, middle - vertical))
            case .up: ((0.5, middle - vertical), (0.5, middle + vertical))
            case .right: ((0.5 + horizontal, middle), (0.5 - horizontal, middle))
            case .left: ((0.5 - horizontal, middle), (0.5 + horizontal, middle))
            }

        try session.hid.swipe(
            from: session.normalized(from.0 * width, from.1 * height),
            to: session.normalized(to.0 * width, to.1 * height), duration: duration,
            holdAtEnd: fling ? 0 : 0.2)
        if keyboard != nil { print("(the keyboard is up, so dragged above it)") }
        if [.up, .down].contains(direction), amount > span {
            print("(dragged only \(String(format: "%.2f", span)) to avoid the top and bottom bars. To go further, repeat or use --fling)")
        }
        print("Scrolled \(direction.rawValue)")
        try shot.capture(after: session, udid: device.udid)
    }
}

/// Hardware buttons.
struct ButtonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button."
    )

    /// HID usage page/code. Standard codes from the Consumer (0x0C) page.
    enum Button: String, ExpressibleByArgument, CaseIterable {
        case home, lock, volumeUp = "volume-up", volumeDown = "volume-down"
        case power, snapshot

        var usage: (page: UInt64, code: UInt64) {
            switch self {
            case .home: return (0x0C, 0x40)
            case .lock, .power: return (0x0C, 0x30)
            case .volumeUp: return (0x0C, 0xE9)
            case .volumeDown: return (0x0C, 0xEA)
            case .snapshot: return (0x0C, 0x65)
            }
        }
    }

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(help: "Button name: \(Button.allCases.map(\.rawValue).joined(separator: ", ")).")
    var button: Button

    @Option(name: .long, help: "Hold time (seconds).")
    var hold: Double = 0.08

    func run() throws {
        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        let usage = button.usage
        try session.hid.pressButton(usagePage: usage.page, usageCode: usage.code, hold: hold)
        print("Button \(button.rawValue)")
        try shot.capture(after: session, udid: device.udid)
    }
}

/// Tunnel/HID diagnostics.
struct HIDInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hid-info",
        abstract: "Print the tunnel, screen size and registered HID surfaces (diagnostics)."
    )

    @OptionGroup var device: DeviceOptions

    func run() throws {
        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        let payload: [String: Any] = [
            "tunnelIP": session.rsd.tunnelIP,
            "screen": ["width": session.screen.width, "height": session.screen.height],
            "services": session.rsd.serviceNames,
            "surfaces": try session.hid.connectedSurfaces().mapValues { $0.jsonReady },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// Types with a physical (HID) keyboard.
///
/// An HID keyboard sends key positions, not characters, so what gets typed is **decided by the device's
/// input source** (PITFALLS #11). Hangul is decomposed into Dubeolsik keys (`HangulKeys`) and composes
/// correctly when the input source is Korean. Digits and symbols sit in the same place on the Korean
/// layout, so they work either way. Characters not on the keyboard, like emoji, need `paste`.
struct TextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "Type text into the focused field (ASCII, Hangul).",
        discussion: """
            Hangul comes out right when the device input source is Korean; Latin letters when it is English.
            `key ctrl+space` cycles the input source. Check with a screenshot after typing.
            """
    )

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(help: "Text to type.")
    var text: String

    @Flag(name: .long, help: "Press Return at the end.")
    var enter = false

    @Flag(name: .long, help: "Type even if the on-screen keyboard isn't visible (e.g. a physical keyboard is attached and hides it).")
    var force = false

    /// ASCII -> (HID usage, needs Shift).
    static func usage(for character: Character) -> (UInt8, Bool)? {
        switch character {
        case "a"..."z":
            return (UInt8(character.asciiValue! - 97 + 0x04), false)
        case "A"..."Z":
            return (UInt8(character.asciiValue! - 65 + 0x04), true)
        case "1"..."9":
            return (UInt8(character.asciiValue! - 49 + 0x1E), false)
        case "0": return (0x27, false)
        case " ": return (0x2C, false)
        case "\n": return (0x28, false)
        case "\t": return (0x2B, false)
        case "-": return (0x2D, false)
        case "=": return (0x2E, false)
        case "[": return (0x2F, false)
        case "]": return (0x30, false)
        case "\\": return (0x31, false)
        case ";": return (0x33, false)
        case "'": return (0x34, false)
        case "`": return (0x35, false)
        case ",": return (0x36, false)
        case ".": return (0x37, false)
        case "/": return (0x38, false)
        case "!": return (0x1E, true)
        case "@": return (0x1F, true)
        case "#": return (0x20, true)
        case "$": return (0x21, true)
        case "%": return (0x22, true)
        case "^": return (0x23, true)
        case "&": return (0x24, true)
        case "*": return (0x25, true)
        case "(": return (0x26, true)
        case ")": return (0x27, true)
        case "_": return (0x2D, true)
        case "+": return (0x2E, true)
        case "{": return (0x2F, true)
        case "}": return (0x30, true)
        case "|": return (0x31, true)
        case ":": return (0x33, true)
        case "\"": return (0x34, true)
        case "~": return (0x35, true)
        case "<": return (0x36, true)
        case ">": return (0x37, true)
        case "?": return (0x38, true)
        default: return nil
        }
    }

    /// Keys to type (HID usage, needs Shift). A Hangul syllable expands into several Dubeolsik keys.
    static func keys(for text: String) throws -> [(UInt8, Bool)] {
        var keys: [(UInt8, Bool)] = []
        for character in text {
            let strokes = HangulKeys.keys(for: character).map(Array.init) ?? [character]
            for stroke in strokes {
                guard let key = usage(for: stroke) else {
                    throw ValidationError(
                        "Can't type this character with the HID keyboard: '\(character)' (only ASCII and Hangul; use paste for the rest)")
                }
                keys.append(key)
            }
        }
        // No single input source types both correctly. Warn instead of silently typing it wrong.
        if text.contains(where: HangulKeys.isHangul),
            text.contains(where: { $0.isASCII && $0.isLetter })
        {
            FileHandle.standardError.write(
                Data("Warning: Hangul and Latin letters are mixed. With a Korean input source, Latin letters come out as jamo.\n".utf8))
        }
        return keys
    }

    func run() throws {
        var keys = try Self.keys(for: text)
        if enter { keys.append((0x28, false)) }

        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        // Without focus in a field, keys are eaten as the app's keyboard shortcuts. In Music, after tapping
        // only the Search tab and not the field, typing an artist name had the space start playback and
        // the letters flip to unrelated screens. Check focus by whether the on-screen keyboard is up (~0.5 s).
        if !force {
            let image = try ScreenText.litImage(rsd: session.rsd)
            guard TextRecognizer.keyboardVisible(in: try TextRecognizer.lines(in: image), height: CGFloat(image.height))
            else {
                throw InputFailure.noFocus(
                    """
                    The on-screen keyboard is not visible — the field seems to have no focus. Tap the field first, \
                    confirm the keyboard is up, then type again. Typing without focus sends keys as app shortcuts \
                    (space = play in Music). If a physical keyboard is hiding the on-screen keyboard, use --force.
                    """)
            }
        }

        for (usage, needsShift) in keys {
            try session.hid.typeKey(usage, modifiers: needsShift ? [0xE1] : [])
        }
        print(keys.count == text.count ? "Typed \(text.count) chars" : "Typed \(text.count) chars (\(keys.count) keystrokes)")
        try shot.capture(after: session, udid: device.udid)
    }
}

/// Blocked by the pre-input check. Throwing `ValidationError` would also print the usage and bury the message.
enum InputFailure: Error, CustomStringConvertible {
    case noFocus(String)

    var description: String {
        switch self {
        case .noFocus(let message): return message
        }
    }
}

/// Presses one named key.
///
/// For keys `text` can't send (arrows, Esc, Backspace) and for modifier combos. In particular, **switching
/// the input source is `ctrl+space`** — if the device keyboard is Korean, Latin letters typed with `text`
/// turn into Hangul jamo, so switch it back to English with this first.
struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press a named key (esc, enter, backspace, up, ctrl+space, ...)."
    )

    /// Name -> HID Keyboard usage (page 0x07).
    static let named: [String: UInt8] = [
        "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29,
        "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
        "delete": 0x4C,
        "lang1": 0x90, "lang2": 0x91,
    ]

    /// Modifier name -> usage.
    static let modifiers: [String: UInt8] = [
        "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "opt": 0xE2,
        "cmd": 0xE3, "command": 0xE3,
    ]

    @OptionGroup var device: DeviceOptions
    @OptionGroup var shot: ShotOptions

    @Argument(
        help: "Key name. Join modifiers with +, like `ctrl+space`. A single character types that character.")
    var key: String

    @Flag(name: .long, help: "Don't fetch the accessibility list (ui) after the key press.")
    var noUi = false

    func run() throws {
        let parts = key.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { throw ValidationError("Empty key name") }

        var modifierUsages: [UInt8] = []
        for part in parts.dropLast() {
            guard let usage = Self.modifiers[part] else {
                throw ValidationError("Unknown modifier: \(part)")
            }
            modifierUsages.append(usage)
        }

        let usage: UInt8
        if let named = Self.named[last] {
            usage = named
        } else if last.count == 1, let (code, needsShift) = TextCommand.usage(for: Character(last)) {
            usage = code
            if needsShift { modifierUsages.append(0xE1) }
        } else {
            throw ValidationError(
                "Unknown key: \(last). Known names: \(Self.named.keys.sorted().joined(separator: ", "))")
        }

        let session = try InputSession.open(udid: device.udid)
        defer { session.close() }

        try session.hid.typeKey(usage, modifiers: modifierUsages)
        print("Key \(key)")
        try shot.capture(after: session, udid: device.udid)
        session.close()
        if !noUi { UIScreen.report(afterActionOn: device.udid) }
    }
}
