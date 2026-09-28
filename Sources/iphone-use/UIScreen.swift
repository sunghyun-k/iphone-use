import CoreGraphics
import Foundation

/// The accessibility screen kept between commands: the list of elements with refs (`@eN`) and where the
/// device focus is.
///
/// The list is in focus order (usually top to bottom). Refs don't change while it's the same screen — if a
/// press leaves us on the same screen the old refs stay and only new elements get new refs. When the screen
/// changes, numbering restarts at 1. A token is only stable while its screen is alive, so we check the
/// element by token before pressing.
struct UIState: Codable {
    struct Entry: Codable {
        var ref: Int
        var token: String
        var caption: String
        /// Custom action names (`press --action`). nil when there are none — old list files still decode.
        var actions: [String]?
        /// A button revealed by swiping its row. Walking to it can move the list and close it, so we tap
        /// the measured rect directly.
        var revealed: Bool?
        /// Where to tap the revealed button (screenshot pixels x, y, width, height). Measured at swipe time.
        var tapRect: [Double]?

        var tapCGRect: CGRect? {
            guard let r = tapRect, r.count == 4 else { return nil }
            return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }

        init(ref: Int, item: AXWalker.Item) {
            self.ref = ref
            token = item.hex
            caption = item.caption
            actions = item.actions.isEmpty ? nil : item.actions.map(\.name)
        }
    }

    var udid: String
    /// pid and executable name of the app that owns the list (Preferences, SpringBoard …).
    var pid = 0
    var app = ""
    var entries: [Entry] = []
    /// Index in `entries` where the device focus is. nil if unknown (the next move walks from the start).
    var cursor: Int?
    /// How many have been shown to the caller. `ui --more` continues from here.
    var shown = 0
    /// Swept to the end (wrapped around once). With `fromEnd`, swept back to the first element.
    var done = false
    /// Taken from the last element backward (`ui --last`). `shown` then counts from the end, `--more`
    /// continues toward earlier elements, and walks start from the last element. nil in old list files.
    var fromEnd: Bool?
    var nextRef = 1

    init(udid: String) { self.udid = udid }

    var isHome: Bool { app == "SpringBoard" }
    var anchoredAtEnd: Bool { fromEnd == true }

    static func url(udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".iphone-use/ui-\(udid).json")
    }

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

/// Why we stopped before pressing or typing. The accessibility session itself is fine (`KeepsSession`).
enum UIError: Error, CustomStringConvertible, KeepsSession {
    case noList
    case unknownRef(Int, last: Int)
    case badRef(String)
    case stale
    case noRect(String)
    case homeScreen
    case noKeyboard
    case noAction(String, available: [String])
    case actionNotTappable(String, ref: Int)
    case revealLost
    case rowNotSwipeable(String)
    case moving(String)

    var description: String {
        switch self {
        case .noList:
            return "No element list. Run ui first."
        case .unknownRef(let ref, let last):
            return "@e\(ref) is not in the list (last ref is @e\(last)). Run ui to get a fresh list."
        case .badRef(let text):
            return "\(text) is not an element ref. Pass a ref from the ui list, like @e12."
        case .stale:
            return "The screen changed since the list was taken — did not press. Run ui to get a fresh list."
        case .noRect(let caption):
            return """
                Focus reached "\(caption)" but could not measure the element on screen (it may be covered or \
                have no size). Did not press. Look at a screenshot and press it with touch X Y.
                """
        case .homeScreen:
            return "There is no back on the home screen. Open apps with launch."
        case .noKeyboard:
            return """
                The on-screen keyboard did not appear — this doesn't look like a text field. Did not type (typing \
                without focus sends keys to app shortcuts). Pick a text field or search field from the ui list and \
                call type @eN "…" again.
                """
        case .noAction(let name, let available):
            if available.isEmpty { return "This element has no actions (\"\(name)\"). Did not press. Run press without --action." }
            return "This element has no \"\(name)\" action. Did not press. Available actions: \(available.joined(separator: ", "))"
        case .rowNotSwipeable(let caption):
            return """
                The rect of "\(caption)" doesn't look like a row (too thin, or under the top/bottom bar). Did not \
                swipe — it could hit the wrong row. Use scroll to bring that row near the middle and run ui again.
                """
        case .moving(let caption):
            return """
                "\(caption)" kept moving on screen after it was measured (the list scrolled or content loaded \
                above it). Did not press. Run ui and try again.
                """
        case .revealLost:
            return "The revealed button's position is unknown (it closed or the list moved). Did not press. --swipe that row again."
        case .actionNotTappable(let name, let ref):
            return """
                "\(name)" is an action whose button can't be located. Did not press. If it's the ⓘ at the right end \
                of the row (e.g. "More Info" on a Wi-Fi row), press it with press @e\(ref) --trailing. Otherwise find \
                that button separately in the list (ui --find).
                """
        }
    }
}

/// The accessibility screen for one request. Takes the list, walks to elements, and compares after a press.
final class UIScreen {
    /// How many `ui` shows at once. About one Settings screen's worth.
    static let page = 20

    let udid: String
    let walker: AXWalker
    var state: UIState
    private var tunnel: RemoteServiceDiscovery?

    private init(udid: String, walker: AXWalker) {
        self.udid = udid
        self.walker = walker
        self.state = UIState.load(udid: udid)
    }

    static func with<T>(udid wanted: String?, _ body: (UIScreen) throws -> T) throws -> T {
        let udid = try DeviceResolver.udid(for: wanted)
        return try AXSession.with(udid: udid) { session in
            let walker = try AXWalker(session: session)
            defer { walker.finish() }
            let screen = UIScreen(udid: udid, walker: walker)
            defer {
                screen.state.save()
                screen.tunnel.map(SessionPool.release)
            }
            return try body(screen)
        }
    }

    /// The tunnel. Only needed for measuring, pressing and app names — on iOS 16 and earlier the list still
    /// works without a tunnel.
    func rsd() throws -> RemoteServiceDiscovery {
        if let tunnel { return tunnel }
        let fresh = try SessionPool.rsd(udid: udid)
        tunnel = fresh
        return fresh
    }

    // MARK: - Walking to an element

    func position(of ref: Int) throws -> Int {
        guard !state.entries.isEmpty else { throw UIError.noList }
        guard let index = state.entries.firstIndex(where: { $0.ref == ref }) else {
            throw UIError.unknownRef(ref, last: state.entries.map(\.ref).max() ?? 0)
        }
        return index
    }

    /// Moves focus to `entries[target]` and returns that element, checking at every step that the element
    /// at that position is the expected one.
    ///
    /// Jumping directly (`deviceInspectorFocusOnElement:`) doesn't scroll to off-screen elements, so the box
    /// is drawn off screen. A step is ~50ms, so walking is cheap. We walk from whichever is closer: the
    /// current position or the start. If any element along the way differs, the screen changed — walk once
    /// more from the start, and stop if it still differs.
    ///
    /// If a step doesn't line up, we try once more by description (`seek`) before stopping. If the screen
    /// itself changed (another app, or that description is gone) we stop rather than press the wrong thing.
    @discardableResult
    func go(to target: Int) throws -> AXWalker.Item {
        let wanted = state.entries[target]
        // Don't walk to a revealed button — if the list moves while walking, it closes. Tap the measured
        // rect directly (`PressCommand`).
        if wanted.revealed == true { throw UIError.revealLost }
        do {
            return try walk(to: target)
        } catch UIError.stale {
            return try seek(wanted)
        }
    }

    /// Walks **by description** instead of counting steps. Used when `walk`, which checks every step, fails.
    ///
    /// Bluetooth / Wi-Fi nearby lists and chat lists in messenger apps (ad rows come and go) gain and lose
    /// rows even while we walk, so we stopped with "screen changed" right after taking the list. Here we walk
    /// from the start and stop at the element with the same description. If several share it, the
    /// occurrence index in the list disambiguates. Landing in another app means the screen changed.
    private func seek(_ wanted: UIState.Entry) throws -> AXWalker.Item {
        guard let index = state.entries.firstIndex(where: { $0.ref == wanted.ref }) else { throw UIError.stale }
        let fromEnd = state.anchoredAtEnd
        let occurrence = (fromEnd ? state.entries[(index + 1)...] : state.entries[..<index])
            .filter { $0.caption == wanted.caption }.count
        state.cursor = nil
        var seen = 0
        var item = try fromEnd ? walker.end() : walker.first()
        for _ in 0..<(state.entries.count + Self.page) {
            guard let current = item, current.pid == state.pid else { throw UIError.stale }
            if current.hex == wanted.token || current.caption == wanted.caption {
                if current.hex == wanted.token || seen == occurrence {
                    // The list is out of sync, so this element's neighbors can't be trusted. Skip the
                    // three-step overshoot.
                    state.entries[index].token = current.hex
                    state.cursor = index
                    return current
                }
                seen += 1
            }
            item = try walker.move(fromEnd ? .previous : .next)
        }
        throw UIError.stale
    }

    private func walk(to target: Int) throws -> AXWalker.Item {
        func matches(_ item: AXWalker.Item?, _ index: Int) -> Bool {
            guard let item else { return false }
            return refresh(index, with: item)
        }

        // Steps from where walks start: the first element, or the last one for a list taken from the end.
        let fromAnchor = state.anchoredAtEnd ? state.entries.count - 1 - target : target
        if let cursor = state.cursor, abs(target - cursor) <= fromAnchor + 1 {
            state.cursor = nil
            if let item = try walkFromCursor(cursor, to: target, matches: matches) {
                state.cursor = target
                return item
            }
        }

        state.cursor = nil
        if state.anchoredAtEnd {
            let end = state.entries.count - 1
            var last = try walker.end()
            guard matches(last, end) else { throw UIError.stale }
            if target < end {
                for index in stride(from: end - 1, through: target, by: -1) {
                    last = try walker.move(.previous)
                    guard matches(last, index) else { throw UIError.stale }
                }
                last = try overshoot(target, forward: false, matches: matches) ?? last
            }
            state.cursor = target
            return last!
        }
        var last = try walker.first()
        guard matches(last, 0) else { throw UIError.stale }
        if target > 0 {
            for index in 1...target {
                last = try walker.move(.next)
                guard matches(last, index) else { throw UIError.stale }
            }
            last = try overshoot(target, forward: true, matches: matches) ?? last
        }
        state.cursor = target
        return last!
    }

    /// Goes a few steps further in the walking direction, then comes back.
    ///
    /// When focus moves to an off-screen element, the system scrolls **just barely enough** to show it.
    /// Walking back up from the end of Settings to "General" left "General" at the very top, half under the
    /// translucent navigation bar, and tapping it hit the bar. Walking down, it ends up under the bottom
    /// search bar / tab bar instead. Going three more steps puts *that* element at the edge and pulls the
    /// target inward. Coming back doesn't scroll since it's already visible. At 50ms a step it's cheap.
    /// Originally we dragged the content to the middle when the target was near an edge, but that meant
    /// measuring twice (even for back buttons stuck to the bar) and cost 4 more seconds.
    private func overshoot(
        _ target: Int, forward: Bool, matches: (AXWalker.Item?, Int) -> Bool
    ) throws -> AXWalker.Item? {
        let extra = forward ? min(3, state.entries.count - 1 - target) : min(3, target)
        guard extra > 0 else { return nil }
        let (away, back): (AXWire.Direction, AXWire.Direction) = forward ? (.next, .previous) : (.previous, .next)
        for step in 1...extra {
            guard matches(try walker.move(away), forward ? target + step : target - step) else { return nil }
        }
        var item: AXWalker.Item?
        for step in stride(from: extra - 1, through: 0, by: -1) {
            item = try walker.move(back)
            guard matches(item, forward ? target + step : target - step) else { return nil }
        }
        return item
    }

    /// Is `item` the same element as `entries[index]`? If so, store its new token.
    ///
    /// Tokens alone aren't enough. When a list cell scrolls off screen and back, its description stays but
    /// its token changes (the cell seems to be reused with a fresh accessibility element). After sweeping to
    /// the end of the Settings root with `ui --more`, the account row came back with a new token and we
    /// stopped with "screen changed" on a list we had just taken. Same position plus same description
    /// counts as the same element.
    private func refresh(_ index: Int, with item: AXWalker.Item) -> Bool {
        let entry = state.entries[index]
        guard entry.token == item.hex || entry.caption == item.caption else { return false }
        state.entries[index].token = item.hex
        state.entries[index].actions = item.actions.isEmpty ? nil : item.actions.map(\.name)
        return true
    }

    private func walkFromCursor(
        _ cursor: Int, to target: Int, matches: (AXWalker.Item?, Int) -> Bool
    ) throws -> AXWalker.Item? {
        if cursor == target {
            // Already there. If focus doesn't change the green focus box isn't drawn, so step to a neighbor
            // and back.
            let count = state.entries.count
            let (away, back): (AXWire.Direction, AXWire.Direction)
            if target + 1 < count {
                (away, back) = (.next, .previous)
            } else if target > 0 {
                (away, back) = (.previous, .next)
            } else {
                return nil
            }
            guard matches(try walker.move(away), away == .next ? target + 1 : target - 1) else { return nil }
            let item = try walker.move(back)
            return matches(item, target) ? item : nil
        }
        let step = target > cursor ? 1 : -1
        var item: AXWalker.Item?
        for index in stride(from: cursor + step, through: target, by: step) {
            item = try walker.move(step > 0 ? .next : .previous)
            guard matches(item, index) else { return nil }
        }
        return try overshoot(target, forward: step > 0, matches: matches) ?? item
    }

    /// Measures the currently focused element. If it can't be measured, stop without pressing.
    ///
    /// Before returning, one more frame checks that the element's area still looks the same as when it was
    /// measured. In a messenger's chat list the rows moved after measuring and the tap opened the chat
    /// three rows above the one asked for (PITFALLS #42). If it moved, wait for the screen to settle, step
    /// away and back so the green box is drawn where the element is now, and measure again. If it keeps
    /// moving, stop: tapping an old rect is exactly what opened the wrong chat.
    func measure(_ item: AXWalker.Item) throws -> CGRect {
        var item = item
        for attempt in 0..<3 {
            // A side under 24px (8pt) is a box fragment, not an element — a chat row stuck under the bottom
            // tab bar measured as a 16px strip, and swiping there opened **a different chat below it**.
            // Don't press such rects.
            guard let (rect, frame) = try walker.measure(item.token, rsd: rsd()), rect.width >= 24,
                rect.height >= 24
            else { throw UIError.noRect(item.caption) }
            let now = try walker.captureWithoutBoxes(rsd: rsd())
            if ScreenCapture.sameArea(frame, now, in: rect.insetBy(dx: 0, dy: -rect.height / 2)) { return rect }
            guard attempt < 2 else { break }
            _ = try ScreenCapture.settled(rsd: rsd(), timeout: 3)
            // Without a known position (`back` walks on its own), measuring again falls back to the
            // yellow preview box.
            if let cursor = state.cursor, state.entries.indices.contains(cursor) { item = try go(to: cursor) }
        }
        throw UIError.moving(item.caption)
    }

    /// Waits until the input reaches the device and the screen settles.
    func settle() throws {
        // If the reaction (press highlight, start of a transition) comes after the first capture, two frames
        // of the pre-input screen are taken as "settled".
        Thread.sleep(forTimeInterval: 0.3)
        _ = try ScreenCapture.settled(rsd: rsd(), timeout: 6)
    }

    /// End (count) of the 20-element batch containing `position`. After a press we re-sweep up to here and
    /// compare.
    /// A button revealed by swiping. Called with focus on `entries[position]` (the swiped row) and `row` as
    /// that row's rect.
    struct Revealed {
        let entry: UIState.Entry
        /// Position counted from the row's right end (1-based). A hint for unnamed buttons (e.g. a
        /// messenger's "Leave").
        let fromRight: Int?
    }

    /// Looks for revealed buttons starting right after the swiped row. Focus must be on the swiped row
    /// (`entries[position]`).
    ///
    /// - Don't walk far. Re-sweeping from the start sends the row off screen and back, the cell is redrawn
    ///   and the buttons close (a messenger's "Leave" vanished that way). The small scroll that follows focus
    ///   didn't close them.
    /// - The buttons came **right after the swiped row** in focus order (a messenger's `Leave, Button`,
    ///   Messages' `Hide Alerts` / `Delete`). We step one at a time, measure each, and count it as a button
    ///   only if it's **within the row's height** and has no actions (`[actions: …]`). Neighboring chat rows
    ///   have actions and a different height. At first we re-measured the row after swiping and used the
    ///   vacated space as the button's rect, but the list moved while walking back and gave a wrong rect.
    /// - Afterwards focus is somewhere near the swiped row. We don't know its list position so we clear
    ///   `cursor` — revealed buttons are tapped at their measured rect, so we never need to walk
    ///   (`PressCommand`).
    func probeRevealed(after position: Int, row: CGRect, limit: Int = 4) throws -> [Revealed] {
        let rowEntry = state.entries[position]
        var found: [(item: AXWalker.Item, rect: CGRect?)] = []
        for _ in 0..<limit {
            guard let item = try walker.move(.next), item.pid == state.pid, item.actions.isEmpty,
                item.hex != rowEntry.token, item.caption != rowEntry.caption
            else { break }
            // Right after moving, measuring sometimes fails (a messenger's "Leave" was nil the first time,
            // then measured exactly 1110,1120 150x150 after stepping away and back). So step away and back
            // once more and measure. If it measures outside the row's height, it's not a button (something
            // in a neighboring row).
            var rect = try? walker.measure(item.token, rsd: rsd())?.rect
            if rect == nil, try walker.move(.previous) != nil, let again = try walker.move(.next),
                again.hex == item.hex || again.caption == item.caption
            {
                rect = try? walker.measure(again.token, rsd: rsd())?.rect
            }
            if let rect, !(rect.midY > row.minY && rect.midY < row.maxY) { break }
            found.append((item, rect))
        }
        state.cursor = nil

        // If the buttons are already in the list (ui was taken while they were open), remove them and insert
        // fresh. Two entries with the same token would be confusing.
        var position = position
        let tokens = Set(found.map(\.item.hex))
        for index in state.entries.indices.reversed() where tokens.contains(state.entries[index].token) {
            state.entries.remove(at: index)
            if index < position { position -= 1 }
        }
        let entries = found.map { pair -> UIState.Entry in
            var entry = UIState.Entry(ref: state.nextRef, item: pair.item)
            state.nextRef += 1
            entry.revealed = true
            entry.tapRect = pair.rect.map { [$0.minX, $0.minY, $0.width, $0.height] }
            return entry
        }
        state.entries.insert(contentsOf: entries, at: position + 1)
        state.shown = min(state.shown + entries.count, state.entries.count)

        let placed = found.enumerated().compactMap { index, pair in pair.rect.map { (index, $0.midX) } }
        let order = placed.sorted { $0.1 > $1.1 }.map(\.0)
        return entries.enumerated().map { index, entry in
            Revealed(entry: entry, fromRight: order.firstIndex(of: index).map { $0 + 1 })
        }
    }

    static func batchEnd(_ position: Int) -> Int {
        (position / page + 1) * page
    }

    /// How far to re-sweep after acting on `position`: its batch, counted from the end for a list taken
    /// from the end.
    func batchLimit(_ position: Int) -> Int {
        Self.batchEnd(state.anchoredAtEnd ? state.entries.count - 1 - position : position)
    }

    // MARK: - Taking and comparing the list

    enum Report {
        case newScreen
        case sameScreen(
            changed: [(ref: Int, before: String, after: String)],
            added: [UIState.Entry], removed: [UIState.Entry], unchanged: Int)
    }

    /// Re-sweeps the first `limit` elements and compares with the previous list.
    ///
    /// Same app and more than half the elements overlap means same screen — keep the refs and report only
    /// what changed. Otherwise it's a new screen and refs restart at 1.
    ///
    /// `fromEnd` sweeps backward from the last element instead (`ui --last`); nil keeps the current list's
    /// direction. If "move to last" doesn't work on the screen, it sweeps from the start as usual.
    func observe(limit: Int, fromEnd wanted: Bool? = nil) throws -> Report {
        state.cursor = nil
        if wanted ?? state.anchoredAtEnd, let swept = try walker.walkFromLast(limit: limit) {
            let report = compare(swept.items, complete: swept.complete, focus: swept.focus, fromEnd: true)
            // Taking the list from the end was for that screen (a chat). If an action led elsewhere (back
            // to the chat list), list the new screen from the start as usual.
            guard wanted == nil, case .newScreen = report else { return report }
            state.entries = []
            state.cursor = nil
        }
        let (items, wrapped) = try walker.walkFromFirst(limit: limit)
        return compare(items, complete: wrapped, focus: wrapped ? 0 : items.count - 1, fromEnd: false)
    }

    /// Diffs a fresh sweep against the stored list. `focus` is the index in `items` where focus was left.
    private func compare(_ items: [AXWalker.Item], complete: Bool, focus: Int?, fromEnd: Bool) -> Report {
        let pid = items[0].pid
        let old = state.entries
        // Where an element sits, counted from the side the sweep started on.
        func place(_ index: Int, among count: Int) -> Int { fromEnd ? count - 1 - index : index }
        // Which old entry is this element? Same token means same element. Tokens can change (see
        // `refresh`), so if not found, pick an unmatched entry with the same description, nearest first.
        var matchedOld = Set<Int>()
        var tokenIndex: [String: Int] = [:]
        for (index, entry) in old.enumerated() where tokenIndex[entry.token] == nil { tokenIndex[entry.token] = index }
        var pairs: [Int?] = items.map { item in
            guard let index = tokenIndex[item.hex], !matchedOld.contains(index) else { return nil }
            matchedOld.insert(index)
            return index
        }
        for (position, item) in items.enumerated() where pairs[position] == nil {
            let candidates = old.indices.filter { !matchedOld.contains($0) && old[$0].caption == item.caption }
            let wanted = place(position, among: items.count)
            if let index = candidates.min(by: {
                abs(place($0, among: old.count) - wanted) < abs(place($1, among: old.count) - wanted)
            }) {
                matchedOld.insert(index)
                pairs[position] = index
            }
        }

        let overlap = pairs.compactMap { $0 }.count
        let comparable = min(items.count, old.count)
        guard pid == state.pid, fromEnd == state.anchoredAtEnd, comparable > 0, overlap * 2 >= comparable else {
            reset(items, complete: complete, focus: focus, fromEnd: fromEnd, pid: pid)
            return .newScreen
        }

        var fresh: [UIState.Entry] = []
        var changed: [(ref: Int, before: String, after: String)] = []
        var added: [UIState.Entry] = []
        var unchanged = 0
        // From the end, elements before the earliest one seen again are older ones that slid into the
        // window (a sent message pushes the window back), not new. Only a list swept to the start knows.
        let slidIn = fromEnd && !state.done ? pairs.firstIndex { $0 != nil } ?? 0 : 0
        for (position, item) in items.enumerated() {
            if let index = pairs[position] {
                let known = old[index]
                if known.caption != item.caption {
                    changed.append((known.ref, known.caption, item.caption))
                } else {
                    unchanged += 1
                }
                fresh.append(.init(ref: known.ref, item: item))
            } else {
                let entry = UIState.Entry(ref: state.nextRef, item: item)
                state.nextRef += 1
                if position >= slidIn { added.append(entry) }
                fresh.append(entry)
            }
        }
        // Only what disappeared within the range swept this time counts as removed. The part beyond it
        // (not swept) is kept as is. From the end, that's everything before the earliest element seen again:
        // a new message pushes the oldest one out of the swept window without removing it.
        var removed: [UIState.Entry] = []
        var head: [UIState.Entry] = []
        var tail: [UIState.Entry] = []
        let earliestSeen = matchedOld.min() ?? 0
        for (index, entry) in old.enumerated() where !matchedOld.contains(index) {
            if complete || (fromEnd ? index > earliestSeen : index < items.count) {
                removed.append(entry)
            } else if fromEnd {
                head.append(entry)
            } else {
                tail.append(entry)
            }
        }
        state.entries = head + fresh + tail
        state.cursor = focus.map { head.count + $0 }
        state.done = complete
        // From the end, `shown` counts back from the last element, so what arrived at the end (a sent
        // message) or left it shifts it. Otherwise --more repeated an element.
        let shown = fromEnd ? state.shown + added.count - removed.count : state.shown
        state.shown = min(max(shown, items.count), state.entries.count)
        return .sameScreen(changed: changed, added: added, removed: removed, unchanged: unchanged)
    }

    private func reset(_ items: [AXWalker.Item], complete: Bool, focus: Int?, fromEnd: Bool, pid: Int) {
        let app = pid == state.pid ? state.app : appName(pid: pid)
        state = UIState(udid: udid)
        state.pid = pid
        state.app = app
        state.entries = items.enumerated().map {
            .init(ref: $0.offset + 1, item: $0.element)
        }
        state.nextRef = items.count + 1
        state.cursor = focus
        state.done = complete
        state.fromEnd = fromEnd ? true : nil
        state.shown = min(Self.page, items.count)
    }

    /// Executable name for a pid. Empty string without a tunnel (iOS 16 and earlier).
    private func appName(pid: Int) -> String {
        guard let rsd = try? rsd(), let path = try? AppService.processes(rsd: rsd)[pid] else { return "" }
        return (path as NSString).lastPathComponent
    }

    /// Continues the list. Shows anything already swept first; if that's not enough, keeps walking from
    /// the last element.
    func more() throws -> ArraySlice<UIState.Entry> {
        guard !state.entries.isEmpty else { throw UIError.noList }
        if state.anchoredAtEnd { return try moreEarlier() }
        let start = state.shown
        try extend(to: start + Self.page)
        let end = min(start + Self.page, state.entries.count)
        state.shown = end
        return state.entries[start..<end]
    }

    /// Walks on from the last swept element until the list holds `count` elements or wraps around.
    private func extend(to count: Int) throws {
        if state.entries.count < count, !state.done {
            try go(to: state.entries.count - 1)
            var known = Dictionary(
                state.entries.enumerated().map { ($0.element.token, $0.offset) },
                uniquingKeysWith: { first, _ in first })
            while state.entries.count < count {
                state.cursor = nil
                guard let item = try walker.move(.next) else { break }
                // Wrapped around: a token we've seen, or back at the first element (its token may have
                // changed, see `refresh`).
                if let index = known[item.hex] ?? (item.caption == state.entries[0].caption ? 0 : nil) {
                    state.done = true
                    state.cursor = index
                    if index == 0, state.entries.count > 1 { try walker.returnToStartPage() }
                    break
                }
                guard item.pid == state.pid else { throw UIError.stale }
                let entry = UIState.Entry(ref: state.nextRef, item: item)
                state.nextRef += 1
                state.entries.append(entry)
                known[item.hex] = state.entries.count - 1
                state.cursor = state.entries.count - 1
            }
        }
    }

    /// `more` for a list taken from the end: walks on backward from the earliest element and puts what it
    /// finds in front. The returned batch is in focus order, like every page.
    private func moreEarlier() throws -> ArraySlice<UIState.Entry> {
        let start = state.shown
        if state.entries.count < start + Self.page, !state.done {
            try go(to: 0)
            var known = Set(state.entries.map(\.token))
            while state.entries.count < start + Self.page {
                state.cursor = nil
                // `previous` from the first element sends no event (PITFALLS #38).
                guard let item = try walker.move(.previous) else {
                    state.done = true
                    state.cursor = 0
                    break
                }
                // Wrapped around to the end.
                if known.contains(item.hex) || item.caption == state.entries.last?.caption {
                    state.done = true
                    state.cursor = state.entries.lastIndex { $0.token == item.hex } ?? state.entries.count - 1
                    break
                }
                guard item.pid == state.pid else { throw UIError.stale }
                state.entries.insert(UIState.Entry(ref: state.nextRef, item: item), at: 0)
                state.nextRef += 1
                known.insert(item.hex)
                state.cursor = 0
            }
        }
        let end = min(start + Self.page, state.entries.count)
        state.shown = end
        let count = state.entries.count
        return state.entries[(count - end)..<(count - start)]
    }

    /// Elements whose description contains `text`, and whether the sweep stopped at `findLimit` before
    /// reaching the end. Searches the already-swept list first; if nothing, sweeps from the start up to
    /// `findLimit`. `continuing` (`ui --find --more`) walks on from the end of the list for another
    /// `findLimit` instead and returns only what it found there.
    ///
    /// The limit was 300, which made a search for something that isn't there take 15 s or more; one
    /// Settings screen with the keyboard up is about 80 elements, so 100 covers a screen and a long list is
    /// searched on in steps.
    static let findLimit = 100

    func find(_ text: String, continuing: Bool) throws -> (hits: [UIState.Entry], stopped: Bool) {
        func hits(from start: Int) -> [UIState.Entry] {
            state.entries[start...].filter { $0.caption.localizedCaseInsensitiveContains(text) }
        }
        if continuing {
            let start = state.entries.count
            try extend(to: start + Self.findLimit)
            state.shown = state.entries.count
            return (hits(from: start), !state.done)
        }
        // Sweep from the start in one go instead of continuing (`more`). Continuing means first walking to
        // the last element with a check at every step, and on screens whose rows change even while walking
        // (ad rows in a messenger's chat list, etc.) that check failed and stopped with "screen changed".
        // One full sweep only costs the 1–2 seconds of re-walking the first 20.
        if hits(from: 0).isEmpty, !state.done || state.anchoredAtEnd {
            _ = try observe(limit: Self.findLimit, fromEnd: false)
            state.shown = state.entries.count
        }
        return (hits(from: 0), !state.done)
    }

    // MARK: - Output

    /// An element with an empty name looks like a blank line and is easy to mistake for something else
    /// (during testing the header of a search-results list was taken for the search field).
    /// Multi-line descriptions (message previews etc.) get their newlines replaced with ` / ` so one list
    /// line doesn't break into several.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
    }

    static func caption(_ entry: UIState.Entry) -> String {
        let caption = entry.caption.isEmpty ? "(no name)" : oneLine(entry.caption)
        guard let actions = entry.actions else { return caption }
        return caption + "\t[actions: " + actions.joined(separator: ", ") + "]"
    }

    func printPage(_ slice: ArraySlice<UIState.Entry>) {
        for entry in slice { print("@e\(entry.ref)\t\(Self.caption(entry))") }
        if state.anchoredAtEnd, state.shown < state.entries.count || !state.done {
            print("(earlier elements — ui --more)")
        } else if state.shown < state.entries.count || !state.done {
            print("(more — ui --more)")
        } else {
            print("(end)")
        }
    }

    /// The first page shown: the start of the list, or its end for a list taken from the end.
    var firstPage: ArraySlice<UIState.Entry> {
        state.anchoredAtEnd ? state.entries.suffix(Self.page) : state.entries.prefix(Self.page)
    }

    var header: String {
        if state.isHome { return "Home screen (widgets are not in the list. Open apps with launch)" }
        return state.app.isEmpty ? "Screen" : state.app
    }

    func printReport(_ report: Report) {
        switch report {
        case .newScreen:
            print("New screen — \(header)")
            printPage(firstPage)
        case .sameScreen(let changed, let added, let removed, let unchanged):
            if changed.isEmpty, added.isEmpty, removed.isEmpty {
                print("Same screen — nothing changed (\(unchanged) unchanged). If nothing reacted, pick a different element.")
                return
            }
            print(
                "Same screen — changed \(changed.count), added \(added.count), removed \(removed.count), unchanged \(unchanged)"
            )
            for item in changed {
                print("changed\t@e\(item.ref)\t\(Self.oneLine(item.after))\t(was: \(Self.oneLine(item.before)))")
            }
            for entry in added { print("added\t@e\(entry.ref)\t\(Self.caption(entry))") }
            for entry in removed { print("removed\t@e\(entry.ref)\t\(Self.caption(entry))") }
        }
    }

    /// The list appended after action commands (`key`, `launch`, `open`). Even if the screen isn't
    /// accessible, the action itself succeeded, so don't fail the command — just say so in one line.
    static func report(afterActionOn udid: String?) {
        do {
            try with(udid: udid) { screen in
                try screen.settle()
                screen.printReport(try screen.observe(limit: page))
            }
        } catch {
            print("(could not get the accessibility list: \(error))")
        }
    }
}
