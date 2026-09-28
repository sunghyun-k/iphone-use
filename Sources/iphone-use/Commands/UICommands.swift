import ArgumentParser
import CoreGraphics
import Foundation

/// Takes the accessibility elements on the current screen, with refs.
struct UICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Print the current screen's elements with @e refs, 20 at a time (accessibility name, value, traits).",
        discussion: """
            Each line is `@eN<TAB>description`. A description looks like "name, value, traits"
            (e.g. "Wi-Fi, HomeWiFi, Button"). Pass the ref to press / type. The list runs top to bottom and
            includes off-screen elements (pressing scrolls to them). The screen may scroll a little while sweeping.
            On the same screen refs stay the same. When the screen changes, numbering restarts at 1.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Flag(name: .long, help: "Continue with the next 20.")
    var more = false

    @Flag(name: .long, help: "Start from the last element and sweep backward, for screens that sit at their end, like a chat: lists the newest messages and the input field without scrolling to the top. --more then continues with earlier elements.")
    var last = false

    @Option(name: .long, help: "Keep sweeping until an element whose description contains this text appears, and print only the matches.")
    var find: String?

    func run() throws {
        try UIScreen.with(udid: device.udid) { screen in
            if let find {
                // Finding elements at the end of the list, like the bottom search bar (iOS 26+) or a close
                // button, used to take several --more calls; this makes it one. If a swept list exists,
                // search it first.
                if screen.state.entries.isEmpty || !more || screen.state.anchoredAtEnd {
                    _ = try screen.observe(limit: UIScreen.page, fromEnd: false)
                    screen.state.shown = min(UIScreen.page, screen.state.entries.count)
                }
                let hits = try screen.find(find)
                print(screen.header)
                if hits.isEmpty {
                    print("(no element contains \"\(find)\" — checked all \(screen.state.entries.count) in the list)")
                } else {
                    for entry in hits { print("@e\(entry.ref)\t\(UIScreen.caption(entry))") }
                }
                return
            }
            if more {
                let slice = try screen.more()
                if slice.isEmpty {
                    print("(end — nothing more)")
                } else {
                    screen.printPage(slice)
                }
                return
            }
            _ = try screen.observe(limit: UIScreen.page, fromEnd: last)
            screen.state.shown = min(UIScreen.page, screen.state.entries.count)
            print(screen.header)
            if last, !screen.state.anchoredAtEnd {
                print("(this screen can't be swept from the end — listed from the start)")
            }
            screen.printPage(screen.firstPage)
        }
    }
}

/// `@e12` -> 12.
func parseRef(_ text: String) throws -> Int {
    let body = text.hasPrefix("@e") ? text.dropFirst(2) : text.hasPrefix("e") ? text.dropFirst() : Substring(text)
    guard let ref = Int(body), ref > 0 else { throw UIError.badRef(text) }
    return ref
}

/// Presses an element.
struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press an element from the ui list (@eN) and report how the screen changed.",
        discussion: """
            Moves focus to the element, measures it, and taps there. Off-screen elements are scrolled to first.
            Once the screen settles, reports the result:
              a new screen gives a new list (refs from 1),
              the same screen gives only changed (value/state changed) / added / removed. Refs stay the same.
            If the screen changed since the list was taken, fails without pressing — run ui again.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "Ref of the element to press (@e12).")
    var ref: String

    @Option(name: .long, help: "How long to hold, in seconds. 0.6 or more for a long press.")
    var hold: Double = 0.08

    @Option(name: .long, help: "Press the row's action button instead of the row (a name from [actions: …] in the list). Currently only ⓘ (\"More Info\") works.")
    var action: String?

    @Flag(name: .long, help: "Press the right end of the element instead of its center (for buttons like a row's trailing ⓘ that aren't separate elements).")
    var trailing = false

    @Option(name: .long, help: "Instead of pressing, swipe inside the element to reveal hidden buttons: left (right-side buttons, e.g. Delete) / right (left-side buttons).")
    var swipe: SwipeSide?

    enum SwipeSide: String, ExpressibleByArgument { case left, right }

    @Flag(name: .long, help: "Don't take the list again after pressing.")
    var noUi = false

    @Flag(name: .long, help: "Take the list after pressing from the end, like ui --last (for opening a chat).")
    var last = false

    func run() throws {
        let ref = try parseRef(ref)
        try UIScreen.with(udid: device.udid) { screen in
            let position = try screen.position(of: ref)
            if screen.state.entries[position].revealed == true {
                // Revealed button: don't walk; tap the rect measured at swipe time (walking can move the list
                // and close it). If it already closed, that rect is the row itself and opens the chat — a new
                // screen in the result means that happened.
                let entry = screen.state.entries[position]
                guard let rect = entry.tapCGRect else { throw UIError.revealLost }
                try tap(rect, udid: device.udid, hold: hold)
                print("Pressed @e\(ref) \(UIScreen.caption(entry))")
                if noUi { return }
                try screen.settle()
                screen.printReport(try screen.observe(limit: screen.batchLimit(position)))
                return
            }
            let item = try screen.go(to: position)
            if let action {
                // Performing the action through accessibility (`performAction`) is silently ignored by the
                // device (PITFALLS #35). Instead we tap where the action's button is. The only one whose
                // position we know is UIKit's ⓘ — its selector is `_accessibilityHandleDetailButtonPress:`
                // and it's always at the row's right end (Bluetooth rows). "More Info" on Wi-Fi rows is
                // attached as a block with no selector (`Selector:(null)`), so it can't be told apart from
                // other actions like Delete — the caller looks and presses it with --trailing.
                guard let found = item.actions.first(where: { $0.name == action })
                    ?? item.actions.first(where: { $0.name.localizedCaseInsensitiveContains(action) })
                else { throw UIError.noAction(action, available: item.actions.map(\.name)) }
                guard found.attribute.contains("_accessibilityHandleDetailButtonPress:") else {
                    throw UIError.actionNotTappable(found.name, ref: ref)
                }
                try tap(Self.trailing(of: try screen.measure(item)), udid: device.udid, hold: hold)
                print("Pressed @e\(ref) \(found.name)(ⓘ) — \(UIScreen.oneLine(item.caption))")
            } else if let swipe {
                let row = try Self.swipeableRow(item, at: position, screen: screen, udid: device.udid)
                try Self.reveal(in: row, toward: swipe, udid: device.udid)
                print("Swiped \(swipe.rawValue) @e\(ref) — \(UIScreen.oneLine(item.caption))")
                if noUi { return }
                try screen.settle()
                let found = try screen.probeRevealed(after: position, row: row)
                if found.isEmpty {
                    print("Found no revealed buttons (the row didn't slide, or the buttons aren't in the list). Try a long press (press @e\(ref) --hold 0.8).")
                } else {
                    print("\(found.count) revealed button(s) — press right away (they close if another command scrolls the list):")
                    for revealed in found {
                        let place = revealed.entry.tapRect == nil
                            ? "\t(could not measure the element — can't press)"
                            : revealed.fromRight.map { "\t(#\($0) from the row's right end)" } ?? ""
                        print("added\t@e\(revealed.entry.ref)\t\(UIScreen.caption(revealed.entry))\(place)")
                    }
                }
                return
            } else if trailing {
                try tap(Self.trailing(of: try screen.measure(item)), udid: device.udid, hold: hold)
                print("Pressed @e\(ref) right end — \(UIScreen.oneLine(item.caption))")
            } else {
                let rect = try screen.measure(item)
                try tap(rect, udid: device.udid, hold: hold)
                print("Pressed @e\(ref) \(UIScreen.oneLine(item.caption))")
            }
            if noUi { return }
            try screen.settle()
            let limit = screen.batchLimit(position)
            screen.printReport(try screen.observe(limit: limit, fromEnd: last ? true : nil))
        }
    }

    /// A row rect that's safe to swipe. If it's near the top/bottom bar, drag the row toward the middle and
    /// measure again.
    ///
    /// When a row overlaps the bottom tab bar (in a messenger app) or the top navigation bar, the box is
    /// covered and the rect is measured wrong, and swiping there opens the neighboring row (trying to swipe
    /// a channel chat opened the private chat row below it). Dragging is fine because it happens **before**
    /// the buttons are revealed. If it still doesn't look like a row after moving, don't swipe.
    static func swipeableRow(
        _ item: AXWalker.Item, at position: Int, screen: UIScreen, udid: String?
    ) throws -> CGRect {
        let size: (width: Double, height: Double)
        do {
            let input = try InputSession.open(udid: udid)
            defer { input.close() }
            size = (input.screen.width, input.screen.height)
        }
        func fits(_ row: CGRect) -> Bool {
            row.height >= size.height * 0.03 && row.width >= size.width * 0.5
                && row.minY >= size.height * 0.12 && row.maxY <= size.height * 0.85
        }
        let first = try? screen.measure(item)
        if let first, fits(first) { return first }

        // Drag toward the middle (45%). If it couldn't be measured, the row is usually under the bottom bar,
        // so move it up a bit.
        let target = size.height * 0.45
        let delta = max(-size.height * 0.35, min(size.height * 0.35, (first?.midY ?? size.height * 0.8) - target))
        do {
            let input = try InputSession.open(udid: udid)
            defer { input.close() }
            let startY = size.height * 0.55
            try input.hid.swipe(
                from: input.normalized(size.width * 0.5, startY),
                to: input.normalized(size.width * 0.5, startY - delta), duration: 0.5, holdAtEnd: 0.2)
        }
        try screen.settle()
        // Step to a neighbor and back so the box is redrawn. If we don't land back on that row, the list is
        // out of sync.
        _ = try screen.walker.move(.next)
        guard let back = try screen.walker.move(.previous),
            back.hex == item.hex || back.caption == item.caption
        else { throw UIError.stale }
        let again = try? screen.measure(back)
        guard let row = again, fits(row) else { throw UIError.rowNotSwipeable(item.caption) }
        return row
    }

    /// Swipes only 35% of the row width inside the row, just enough to reveal the buttons. A full swipe
    /// **triggers the first button immediately** — in Messages it deletes the conversation. So push short and
    /// slow. The outer 4px are system gestures, so start 10% inside the row.
    static func reveal(in row: CGRect, toward side: SwipeSide, udid: String?) throws {
        let input = try InputSession.open(udid: udid)
        defer { input.close() }
        let near = row.width * 0.1, travel = row.width * 0.35
        let startX = side == .left ? row.maxX - near : row.minX + near
        let endX = side == .left ? startX - travel : startX + travel
        try input.hid.swipe(
            from: input.normalized(startX, row.midY), to: input.normalized(endX, row.midY), duration: 0.4)
    }

    /// Rect of the button at the row's right end (ⓘ etc.). Its center sits about 0.6× the row height in from
    /// the right end (Settings Bluetooth row: height 164px, ⓘ center 100px from the end — verified by drawing
    /// on a screenshot). Scaling by height means we don't need the pixel scale or text size.
    static func trailing(of row: CGRect) -> CGRect {
        let inset = row.height * 0.6
        return CGRect(x: row.maxX - inset * 2, y: row.minY, width: inset * 2, height: row.height)
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
        abstract: "Press a text field (@eN) and type text (Hangul and ASCII). Without a ref, types into the already focused field.",
        discussion: """
            iphone-use type @e3 "iphone case" --enter
            iphone-use type @e3 "New Name" --clear
            iphone-use type "아이폰 케이스"
            If the on-screen keyboard doesn't appear, nothing is typed (it's not a text field). Hangul comes out
            right when the device input source is Korean, Latin letters when it's English (switch with
            `key ctrl+space`). Characters not on the keyboard layout, like emoji, can't be typed.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "A text field ref (@e3) and the text, or just the text.")
    var arguments: [String]

    @Flag(name: .long, help: "Press Return at the end (e.g. to run a search).")
    var enter = false

    @Flag(name: .long, help: "Clear the existing content first (⌘A → Backspace).")
    var clear = false

    @Flag(name: .long, help: "Don't take the list again after typing.")
    var noUi = false

    func validate() throws {
        guard (1...2).contains(arguments.count) else {
            throw ValidationError("Call it as type @e3 \"text\" or type \"text\".")
        }
    }

    func run() throws {
        let ref = arguments.count == 2 ? try parseRef(arguments[0]) : nil
        let text = arguments.last!
        // Check that all of it can be typed before typing. Stopping halfway leaves the field half-filled.
        let keys = try TextCommand.keys(for: text)

        try UIScreen.with(udid: device.udid) { screen in
            var position: Int?
            if let ref {
                let index = try screen.position(of: ref)
                let item = try screen.go(to: index)
                try tap(try screen.measure(item), udid: device.udid)
                position = index
            }
            guard try keyboardAppears(rsd: screen.rsd(), wait: ref != nil) else { throw UIError.noKeyboard }

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

            print("Typed\(ref.map { " @e\($0)" } ?? "") ← \"\(text)\"\(enter ? " + Return" : "")")
            if noUi { return }
            try screen.settle()
            screen.printReport(
                try screen.observe(limit: position.map(screen.batchLimit) ?? UIScreen.page))
        }
    }

    /// Is the on-screen keyboard up? If a text field was just pressed, wait a little for the slide-up
    /// animation.
    ///
    /// Keyboard keys are accessibility elements too, but they're at the very end of the focus order, so
    /// we'd have to walk all the way there. With a long list that takes seconds, so we look at the text near
    /// the bottom of the screen instead (`TextRecognizer.keyboardVisible`; it doesn't pick targets).
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

/// Back to the previous screen.
struct BackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Go to the previous screen (back button, then edge swipe) and report the new screen.",
        discussion: """
            1. If one of the first elements has a back/close button identifier (BackButton etc.), press it.
            2. Otherwise swipe in from the left edge and check whether the screen changed.
            3. If it still didn't change, don't press anything; report the element at the top-left of the
               screen — press it if it's the back button. For sheets/modals, find a Close/Cancel button in the
               ui list and press it.
            Refuses on the home screen (it would open the widget screen).
            """
    )

    @OptionGroup var device: DeviceOptions

    /// How many elements from the front to check for a back button. Usually it's first; on some screens it
    /// comes after the bar title.
    static let front = 6

    func run() throws {
        try UIScreen.with(udid: device.udid) { screen in
            screen.state.cursor = nil
            guard let head = try screen.walker.first() else { throw ScanError.noFocusEvents }
            // An edge swipe on the home screen opened the widget screen.
            let home = head.pid == screen.state.pid ? screen.state.isHome : isSpringBoard(head.pid, screen)
            if home { throw UIError.homeScreen }
            // If the list isn't for the current screen (after acting without a list), clear it. Otherwise the
            // screen we return to matches the old list and reports "nothing changed". Tokens can't tell them
            // apart — the navigation bar's back button keeps its token across screens and only its name
            // changed ("Settings" → "Back").
            if let first = screen.state.entries.first, first.caption != head.caption {
                screen.state = UIState(udid: screen.state.udid)
            }

            // 1. Identifier. A back button's name is the previous screen's title ("Settings") or "Back", so
            //    names can't pick it, but UIKit's is `BackButton` in every language and custom buttons
            //    usually have an English identifier too.
            var items = [head]
            while items.count < Self.front, let item = try screen.walker.move(.next) {
                if item.token == head.token { break }
                items.append(item)
            }
            if let index = items.firstIndex(where: { Self.looksLikeBack($0.identifier) }) {
                let button = items[index]
                // Walk to the button again. The green focus box is drawn when focus changes to that element.
                _ = try screen.walker.first()
                for _ in 0..<index { _ = try screen.walker.move(.next) }
                try tap(try screen.measure(button), udid: device.udid)
                print("Back (back button \(button.identifier ?? ""))")
                try screen.settle()
                screen.printReport(try screen.observe(limit: UIScreen.page))
                return
            }

            // 2. Edge swipe. Some apps block the gesture, so check whether the screen changed.
            let before = try ScreenCapture.image(rsd: screen.rsd())
            let input = try InputSession.open(udid: device.udid)
            // The system back gesture only takes it if it starts just inside the outer 4 pixels (see swipe help).
            try input.hid.swipe(
                from: input.normalized(6, input.screen.height * 0.45),
                to: input.normalized(input.screen.width * 0.75, input.screen.height * 0.45),
                duration: 0.3)
            let (width, height) = (input.screen.width, input.screen.height)
            input.close()
            Thread.sleep(forTimeInterval: 0.3)
            let after = try ScreenCapture.settled(rsd: screen.rsd(), timeout: 6)
            if try !ScreenCapture.unchanged(before, after.image, ignoring: after.moving) {
                print("Back (edge swipe)")
                screen.printReport(try screen.observe(limit: UIScreen.page))
                return
            }

            // 3. Top-left element. Likely the back button, but it could be a side menu or profile (some apps,
            //    e.g. a social app, put a "side menu" there), so report it instead of pressing.
            print("Could not go back — no back button identifier, and the edge swipe had no effect.")
            _ = try screen.observe(limit: UIScreen.page)
            let corner = try topLeft(screen, width: width, height: height)
            if let corner {
                print("Top-left element: @e\(corner.ref)\t\(corner.caption)")
                print("If it's the back button, press @e\(corner.ref). Otherwise pick a Close/Cancel button from the list below.")
            } else {
                print("No element at the top-left. Pick a Close/Cancel button from the list below and press it.")
            }
            print(screen.header)
            screen.printPage(screen.state.entries.prefix(UIScreen.page))
        }
    }

    /// Identifiers that look like a back/close button. Filters out "back" inside a word, like "playback".
    static func looksLikeBack(_ identifier: String?) -> Bool {
        guard let id = identifier?.lowercased(), !id.isEmpty else { return false }
        let words = ["back", "close", "dismiss", "cancel"]
        let parts = id.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if parts.contains(where: words.contains) { return true }
        return ["backbutton", "closebutton", "navback", "navigationback", "dismissbutton", "cancelbutton"]
            .contains(where: id.contains)
    }

    /// Among the first elements, one at the top-left of the screen (within 25% width, 15% height). Measures
    /// them one by one.
    private func topLeft(_ screen: UIScreen, width: Double, height: Double) throws -> UIState.Entry? {
        for index in 0..<min(4, screen.state.entries.count) {
            let item = try screen.go(to: index)
            guard let rect = try? screen.measure(item) else { continue }
            if rect.midX < width * 0.25, rect.midY < height * 0.15 { return screen.state.entries[index] }
            if rect.midY > height * 0.15 { break }  // already past the top
        }
        return nil
    }

    private func isSpringBoard(_ pid: Int, _ screen: UIScreen) -> Bool {
        guard let rsd = try? screen.rsd(), let path = try? AppService.processes(rsd: rsd)[pid] else {
            return false
        }
        return path.hasSuffix("/SpringBoard")
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
