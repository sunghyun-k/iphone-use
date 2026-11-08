import ArgumentParser
import CoreGraphics
import Foundation

/// Reads the current screen's text with refs, and saves the screenshot next to it.
struct UICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Read the screen as a list of @t refs (text, plus toggles and icons), and save the screenshot with a grid.",
        discussion: """
            Each line is `@tN<TAB>text<TAB>grid cell`, top to bottom. Pass the ref to press / type. Controls
            without text are found by their shape and listed in brackets: `[toggle on] Wi-Fi` (a switch, its
            state and its row's label), `[chevron left]` (a common symbol), `[icon]` (an unrecognized icon).
            Only what's on screen is listed; scroll to see more. On the same screen refs stay the same; on a
            new screen numbering restarts at 1.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Option(name: .long, help: "Print only the lines containing this text (case-insensitive).")
    var find: String?

    @Flag(name: .long, help: "Wait for the screen to settle first (after a change you made with --no-ui or by hand).")
    var wait = false

    func run() throws {
        try UIScreen.with(udid: device.udid) { screen in
            let image = wait ? try screen.settle() : try screen.capture()
            // Matched against the last list, so refs from it stay valid on the same screen; the whole list
            // is printed either way.
            _ = try screen.observe(image)
            guard let find else {
                print("\(screen.state.entries.count) lines")
                screen.printList(screen.state.entries)
                return
            }
            let hits = screen.state.entries.filter { $0.text.localizedCaseInsensitiveContains(find) }
            print("\(hits.count) of \(screen.state.entries.count) lines contain \"\(find)\"")
            if hits.isEmpty {
                print("(not on this screen — look at the screenshot, or scroll and run ui again)")
            }
            for entry in hits { print(screen.line(entry)) }
            print(screen.imageNote)
        }
    }
}

/// `@t12` -> 12.
func parseRef(_ text: String) throws -> Int {
    var body = Substring(text)
    if body.hasPrefix("@") { body = body.dropFirst() }
    if body.hasPrefix("t") { body = body.dropFirst() }
    guard let ref = Int(body), ref > 0 else { throw UIError.badRef(text) }
    return ref
}

/// Presses a text line.
struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Tap a line from the ui list (@tN), text or [control], and report how the screen changed.",
        discussion: """
            Checks that the line is still where ui read it, then taps its center. If it moved, it's found again
            by its text; if it's gone, nothing is pressed. Once the screen settles, reports the result:
              a new screen gives a new list (refs from 1),
              the same screen gives only changed / added / removed lines. Refs stay the same.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "Ref of the line to press (@t12).")
    var ref: String

    @Option(name: .long, help: "How long to hold, in seconds. 0.6 or more for a long press.")
    var hold: Double = 0.08

    @Flag(name: .long, help: "Tap the right end of the line's row instead (a row's trailing ⓘ, a chevron, a toggle).")
    var trailing = false

    @Option(name: .long, help: "Instead of pressing, swipe the line's row to reveal hidden buttons: left (right-side buttons, e.g. Delete) / right (left-side buttons).")
    var swipe: SwipeSide?

    enum SwipeSide: String, ExpressibleByArgument { case left, right }

    @Flag(name: .long, help: "Don't read the screen again after pressing.")
    var noUi = false

    func run() throws {
        let ref = try parseRef(ref)
        try UIScreen.with(udid: device.udid) { screen in
            let entry = try screen.entry(ref)
            let (rect, moved) = try screen.locate(entry)
            let width = Double(screen.state.width), height = Double(screen.state.height)
            let label = "@t\(ref) \"\(entry.text)\"\(moved ? " (it had moved; found it again by its text)" : "")"
            if let swipe {
                guard rect.midY > height * 0.12, rect.midY < height * 0.85 else {
                    throw UIError.rowNotSwipeable(entry.text)
                }
                try Self.reveal(atY: rect.midY, width: width, toward: swipe, udid: device.udid)
                print("Swiped \(swipe.rawValue) the row of \(label)")
            } else if trailing {
                try tap(Self.trailing(rowAt: rect, width: width), udid: device.udid, hold: hold)
                print("Pressed the right end of the row of \(label)")
            } else {
                try tap(rect, udid: device.udid, hold: hold)
                print("Pressed \(label)")
            }
            if noUi { return }
            screen.printReport(try screen.observeAfterAction())
        }
    }

    /// Swipes only 35% of the screen width, just enough to reveal the buttons. A full swipe **triggers the
    /// first button immediately** — in Messages it deletes the conversation. So push short and slow. The
    /// outer 4px are system gestures, so start 10% inside.
    static func reveal(atY y: Double, width: Double, toward side: SwipeSide, udid: String?) throws {
        let input = try InputSession.open(udid: udid)
        defer { input.close() }
        let near = width * 0.1, travel = width * 0.35
        let startX = side == .left ? width - near : near
        let endX = side == .left ? startX - travel : startX + travel
        try input.hid.swipe(from: input.normalized(startX, y), to: input.normalized(endX, y), duration: 0.4)
    }

    /// The button at the right end of a row (ⓘ etc.). OCR gives only the line, not the row, so this
    /// assumes the row runs to the screen's right edge, as table rows do. The ⓘ center sits about 100px
    /// from the end of a 1290px-wide Settings row.
    static func trailing(rowAt line: CGRect, width: Double) -> CGRect {
        let size = width * 0.08
        return CGRect(x: width - size * 1.5, y: line.midY - size / 2, width: size, height: size)
    }
}

/// Taps the center of a rect.
func tap(_ rect: CGRect, udid: String?, hold: Double = 0.08) throws {
    let input = try InputSession.open(udid: udid)
    defer { input.close() }
    let point = input.normalized(rect.midX, rect.midY)
    if hold >= 0.4 {
        try input.hid.press(x: point.x, y: point.y, duration: hold)
    } else {
        try input.hid.tap(x: point.x, y: point.y, hold: hold)
    }
}

/// Types text into a text field.
struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Press a text field (@tN) and type text (Hangul and ASCII). Without a ref, types into the already focused field.",
        discussion: """
            iphone-use type @t3 "iphone case" --enter
            iphone-use type @t3 "New Name" --clear
            If the on-screen keyboard doesn't appear, nothing is typed (it's not a text field). Hangul comes out
            right when the device input source is Korean, Latin letters when it's English (switch with
            `key ctrl+space`). Characters not on the keyboard layout, like emoji, can't be typed.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "A text field ref (@t3, e.g. its placeholder text) and the text, or just the text.")
    var arguments: [String]

    @Flag(name: .long, help: "Press Return at the end (e.g. to run a search).")
    var enter = false

    @Flag(name: .long, help: "Clear the existing content first (⌘A → Backspace).")
    var clear = false

    @Flag(name: .long, help: "Don't read the screen again after typing.")
    var noUi = false

    func validate() throws {
        guard (1...2).contains(arguments.count) else {
            throw ValidationError("Call it as type @t3 \"text\" or type \"text\".")
        }
    }

    func run() throws {
        let ref = arguments.count == 2 ? try parseRef(arguments[0]) : nil
        let text = arguments.last!
        // Check that all of it can be typed before typing. Stopping halfway leaves the field half-filled.
        let keys = try TextCommand.keys(for: text)

        try UIScreen.with(udid: device.udid) { screen in
            if let ref {
                let (rect, _) = try screen.locate(try screen.entry(ref))
                try tap(rect, udid: device.udid)
            }
            guard try keyboardAppears(rsd: screen.rsd, wait: ref != nil) else { throw UIError.noKeyboard }

            let input = try InputSession.open(udid: device.udid)
            if clear {
                try input.hid.typeKey(0x04, modifiers: [0xE3])  // ⌘A
                try input.hid.typeKey(0x2A, modifiers: [])  // Backspace
            }
            for (usage, needsShift) in keys {
                try input.hid.typeKey(usage, modifiers: needsShift ? [0xE1] : [])
            }
            if enter { try input.hid.typeKey(0x28, modifiers: []) }
            input.close()

            print("Typed\(ref.map { " @t\($0)" } ?? "") ← \"\(text)\"\(enter ? " + Return" : "")")
            if noUi { return }
            screen.printReport(try screen.observeAfterAction())
        }
    }

    /// Is the on-screen keyboard up? If a text field was just pressed, wait a little for the slide-up
    /// animation.
    private func keyboardAppears(rsd: RemoteServiceDiscovery, wait: Bool) throws -> Bool {
        for attempt in 0..<(wait ? 6 : 1) {
            if attempt > 0 || wait { Thread.sleep(forTimeInterval: 0.3) }
            let image = try ScreenText.litImage(rsd: rsd)
            if TextRecognizer.keyboardVisible(
                in: try TextRecognizer.lines(in: image), height: CGFloat(image.height))
            {
                return true
            }
        }
        return false
    }
}

/// To the home screen.
struct HomeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "home",
        abstract: "Go to the home screen (home button). Gives no list — open apps with launch."
    )

    @OptionGroup var device: DeviceOptions

    func run() throws {
        let input = try InputSession.open(udid: device.udid)
        defer { input.close() }
        let usage = ButtonCommand.Button.home.usage
        try input.hid.pressButton(usagePage: usage.page, usageCode: usage.code, hold: 0.08)
        UIState.clear(udid: try DeviceResolver.udid(for: device.udid))
        print("Home")
    }
}
