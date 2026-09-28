import CoreGraphics
import Foundation

/// Moves the inspector focus to read elements, and measures element rects. The base of `ui` / `press` / `type`.
///
/// Accessibility has no way to ask for an element's coordinates (PITFALLS #35). Instead, when focus moves,
/// the inspector draws a **green focus box** around that element on the device screen. Comparing a frame
/// with the box shown against one with it hidden gives the box's rect, which is the element's rect
/// (PITFALLS #37). Captures are used only inside the CLI; the caller (an LLM) never sees the images.
///
/// Focus stays on the device even after the session closes. So `UIState` remembers "which position we're
/// at" between commands, and the next command walks from there.
final class AXWalker {
    struct Item {
        let token: Data
        let caption: String
        /// Accessibility identifier set by the developer. Language independent — UIKit's back button is
        /// `BackButton`.
        var identifier: String? = nil
        /// Custom actions (the ones VoiceOver picks with an up/down swipe): name, and the attribute name to
        /// pass when performing it. The ⓘ on Bluetooth / Wi-Fi rows shows up here as "More Info" — the ⓘ
        /// itself is often missing from the focus order (PITFALLS #38).
        var actions: [(name: String, attribute: String)] = []

        var hex: String { token.map { String(format: "%02X", $0) }.joined() }

        /// pid of the app that owns the element: the first 4 bytes of the token (little endian) — Settings'
        /// tokens (pid 36934 = 0x9046) started with `46900000…`, SpringBoard's (pid 39) with `27000000…`.
        var pid: Int { Self.pid(of: token) }

        static func pid(of token: Data) -> Int {
            guard token.count >= 4 else { return 0 }
            return token.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
    }

    let session: AXSession

    init(session: AXSession) throws {
        self.session = session
        try session.beginFocusWalk()
        // The previous command hid the box. Turn it back on so this command's moves draw it.
        try session.invoke("deviceInspectorShowVisuals:", [true], expectsReply: false)
    }

    /// The box stays on the device screen even after the session closes. Hide it at the end so the user
    /// isn't left with a green box on their screen.
    func finish() {
        _ = try? session.invoke("deviceInspectorShowVisuals:", [false], expectsReply: false)
    }

    /// Moves one step and receives the resulting focus. nil if it doesn't arrive in time.
    ///
    /// Even if the event is late, don't resend the move — a second move arriving before the first finishes
    /// breaks the daemon for the rest of the session (PITFALLS #4). Wait several times instead. Moving to an
    /// off-screen element only sends the event after scrolling finishes, which can take over a second.
    func move(_ direction: AXWire.Direction) throws -> Item? {
        try session.moveFocus(direction)
        for _ in 0..<3 {
            if let focus = session.nextFocus(timeout: 1), let token = AXSession.token(of: focus) {
                let element = focus["ElementValue_v1"] as? [String: Any]
                return Item(
                    token: token, caption: focus["CaptionTextValue_v1"] as? String ?? "",
                    identifier: element?["AccessibilityIdentifier_v1"] as? String,
                    actions: Self.customActions(in: focus))
            }
        }
        return nil
    }

    /// Picks only custom actions from the inspector's "Actions" section of a focus event. Default actions like
    /// activate and scroll are left out since `press` / `scroll` handle them. The attribute name looks like
    /// `AXCustomAction-Name:More Info\nTarget:0x…\nSelector:…`, so the selector tells which button it is (the
    /// name is localized). It contains an address that changes when the row is redrawn — don't store it; take
    /// it from the event right before pressing.
    static func customActions(in focus: [String: Any]) -> [(name: String, attribute: String)] {
        let sections = focus["InspectorSectionsValue_v1"] as? [[String: Any]] ?? []
        return sections.filter { $0["IdentifierValue_v1"] as? String == "Actions_v1" }
            .flatMap { $0["ElementAttributesValue_v1"] as? [[String: Any]] ?? [] }
            .compactMap { attribute in
                guard let name = attribute["AttributeNameValue_v1"] as? String,
                    name.hasPrefix("AXCustomAction-")
                else { return nil }
                return (attribute["HumanReadableNameValue_v1"] as? String ?? name, name)
            }
    }

    /// Goes to the first element.
    ///
    /// If already at the first, focus doesn't change and no event arrives (PITFALLS #36). Step one away and
    /// back — not via the last element: on some screens "last" goes to the first element (PITFALLS #37).
    func first() throws -> Item? {
        if let item = try move(.first) { return item }
        _ = try move(.next)
        return try move(.first)
    }

    /// Sweeps `limit` elements from the first. Stops on returning to a seen element (wrapped around), with
    /// `wrapped` true.
    func walkFromFirst(limit: Int) throws -> (items: [Item], wrapped: Bool) {
        guard let head = try first() else { throw ScanError.noFocusEvents }
        var items = [head]
        var seen: Set<Data> = [head.token]
        while items.count < limit {
            guard let item = try move(.next) else { return (items, false) }
            // Wrapped around. The first element can come back with a new token after being scrolled off
            // screen, so check the description too.
            if seen.contains(item.token) || (items.count > 2 && item.caption == head.caption) {
                if items.count > 1 { try returnToStartPage() }
                return (items, true)
            }
            seen.insert(item.token)
            items.append(item)
        }
        return (items, false)
    }

    /// Goes to the last element. Same trick as `first` when focus is already there.
    func last() throws -> Item? {
        if let item = try move(.last) { return item }
        _ = try move(.previous)
        return try move(.last)
    }

    /// Sweeps `limit` elements **backward** from the last one, for screens that sit scrolled to the end
    /// (a chat). Walking from the first element scrolled the chat up to its oldest loaded message
    /// (PITFALLS #41). `items` is in focus order (earliest first); `complete` is true when it reached the
    /// first element; `focus` is the index in `items` where focus was left (nil: on a keyboard key).
    ///
    /// nil when "move to last" doesn't work on this screen: in Settings it lands on the first element
    /// (PITFALLS #37), and `previous` from the first element sends no event, so a first step without an
    /// event means we're not at the end.
    func walkFromLast(limit: Int) throws -> (items: [Item], complete: Bool, focus: Int?)? {
        guard let tail = try last() else { return nil }
        var met = [tail]
        var seen: Set<Data> = [tail.token]
        var trait = Self.keyTrait(of: tail)
        // How many of `met` (counted from the end) are the on-screen keyboard. Those aren't listed.
        func keys() -> Int {
            guard let trait else { return 0 }
            return met.firstIndex { !Self.inKeyboard($0, trait: trait) } ?? met.count
        }
        var complete = false
        var wrapped = false
        while met.count - keys() < limit {
            guard let item = try move(.previous) else {
                if met.count == 1 { return nil }
                complete = true
                break
            }
            if seen.contains(item.token) || (met.count > 2 && item.caption == tail.caption) {
                (complete, wrapped) = (true, true)
                break
            }
            seen.insert(item.token)
            met.append(item)
            if trait == nil, met.count <= 10 { trait = Self.keyTrait(of: item) }
        }
        let skipped = keys()
        let items = Array(met[skipped...].reversed())
        guard !items.isEmpty else { return nil }
        // Wrapping around puts focus back on the last element, a key when the keyboard is up.
        if wrapped { return (items, complete, skipped > 0 ? nil : items.count - 1) }
        // Focus on the earliest swept element scrolled the chat up by the whole window — with the keyboard
        // up, a just-sent message ended up off screen. Walk back down so the view is at the end again.
        var focus = 0
        while focus < items.count - 1, try move(.next) != nil { focus += 1 }
        return (items, complete, focus)
    }

    /// Goes to the last element that isn't an on-screen keyboard key.
    func end() throws -> Item? {
        guard let tail = try last() else { return nil }
        var item = tail
        var trait = Self.keyTrait(of: tail)
        var steps = 0
        while trait == nil, steps < 10 {
            guard let previous = try move(.previous) else { break }
            item = previous
            steps += 1
            trait = Self.keyTrait(of: item)
        }
        // No keyboard: back to the last element in one step.
        guard let trait else { return steps == 0 ? tail : try last() }
        while Self.inKeyboard(item, trait: trait) {
            guard let previous = try move(.previous) else { return nil }
            item = previous
        }
        return item
    }

    /// Identifiers UIKit gives some keyboard keys in every language (the letter keys have none).
    static let keyIdentifiers: Set<String> = ["Return", "space", "delete"]

    /// The localized trait text keyboard keys carry ("…, Keyboard Key"), read off a key UIKit identifies.
    /// The keys come last in focus order (PITFALLS #38), so with the keyboard up a sweep from the end found
    /// nothing but keys; there is no language-independent trait value to filter them by (PITFALLS #41).
    static func keyTrait(of item: Item) -> String? {
        guard let identifier = item.identifier, keyIdentifiers.contains(identifier) else { return nil }
        return item.caption.components(separatedBy: ", ").last
    }

    /// A key, or an unnamed element between keys (the keyboard has one before Return).
    static func inKeyboard(_ item: Item, trait: String) -> Bool {
        item.caption.isEmpty || item.caption.components(separatedBy: ", ").contains(trait)
    }

    /// After a sweep wraps around, steps onto the second element and back so the view shows the page the
    /// sweep started on. Focus ends on the first element.
    ///
    /// In a horizontally paged app (Weather's cities), `next` past the last element of a page moves on to
    /// the next page's first element and the pager scrolls there. Wrapping back to the first element doesn't
    /// scroll it back — that element is the page indicator in the bottom bar, outside the pager — so each
    /// `ui --find` left the app one page further along (PITFALLS #39).
    func returnToStartPage() throws {
        guard try move(.next) != nil else { return }
        _ = try move(.previous)
    }

    // MARK: - Measuring

    /// Clears the boxes, so a frame shows the screen as it is. `measure` leaves the yellow preview box up.
    /// Focus moves draw the green box again only while visuals are on, so they are turned back on.
    func captureWithoutBoxes(rsd: RemoteServiceDiscovery) throws -> CGImage {
        try session.invoke("deviceInspectorShowVisuals:", [false], expectsReply: false)
        Thread.sleep(forTimeInterval: 0.15)
        defer { _ = try? session.invoke("deviceInspectorShowVisuals:", [true], expectsReply: false) }
        return try ScreenCapture.image(rsd: rsd)
    }

    /// Rect of the currently focused element (`token`), in screenshot pixels, and a frame of the screen
    /// without the box at the time of measuring (to check before tapping that nothing moved since).
    ///
    /// Measure with the green focus box first. If that fails, measure again with the yellow preview box —
    /// on green-heavy backgrounds (green icons/buttons) the green box makes little difference. The green box
    /// is drawn **only when focus changes**, so the preview is the only way to get something redrawn
    /// (PITFALLS #37).
    func measure(_ token: Data, rsd: RemoteServiceDiscovery) throws -> (rect: CGRect, frame: CGImage)? {
        // Fast path: one frame with the box shown, one with it hidden. A capture is 0.5 s, so waiting for the
        // screen to settle first would add a second. Instead we check that the area around the box is the
        // same in both frames — if the screen was still scrolling to follow focus, content near the element
        // moves too and differs, and then we take the slow path.
        //
        // Don't look at the whole screen. On an app whose home screen plays a looping video, a person moving
        // in the middle of the screen always looked like "scrolling" and forced the slow path, and the face
        // (skin tones are high in yellow) got mixed into the yellow preview comparison, so a tab bar item was
        // measured in the middle of the video. Motion far from the box has nothing to do with the rect.
        Thread.sleep(forTimeInterval: 0.1)
        let shown = try ScreenCapture.image(rsd: rsd)
        try session.invoke("deviceInspectorShowVisuals:", [false], expectsReply: false)
        Thread.sleep(forTimeInterval: 0.15)
        var hidden = try ScreenCapture.image(rsd: rsd)
        if let rect = Self.greenBox(shown: shown, hidden: hidden),
            (try? ScreenCapture.unchanged(
                shown, hidden, ignoring: rect.insetBy(dx: -24, dy: -24),
                within: rect.insetBy(dx: -160, dy: -160))) == true
        {
            return (rect, hidden)
        }

        // Slow path: the box can't be redrawn on a settled screen (it's only drawn when focus changes), so use
        // the yellow preview box. The "before" frame is the settled screen with the box hidden.
        hidden = try ScreenCapture.settled(rsd: rsd, timeout: 3).image
        try session.invoke("deviceInspectorShowVisuals:", [true], expectsReply: false)
        try session.invoke(
            "deviceInspectorPreviewOnElement:", [AXWire.element(token)], expectsReply: false)
        for attempt in 0..<8 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.15 : 0.3)
            if let rect = Self.yellowBox(before: hidden, after: try ScreenCapture.image(rsd: rsd)) {
                return (rect, hidden)
            }
        }
        return nil
    }

    /// Rect of the green focus box: the largest blob among pixels that are **greener** in the shown frame.
    ///
    /// Don't use all changed pixels. Things that change on their own in the meantime — clock, video,
    /// waveforms — get mixed in. The box has a green border, so on any background (green - average of red
    /// and blue) goes up.
    ///
    /// Over a translucent bar the box is faint and its border only 1–2 px thick, so if the half-size pass
    /// finds nothing, look again at full size with a lower threshold (PITFALLS #40).
    static func greenBox(shown: CGImage, hidden: CGImage) -> CGRect? {
        let green = { (a: [UInt8], i: Int) in Int(a[i + 1]) - (Int(a[i]) + Int(a[i + 2])) / 2 }
        return region(shown, hidden, minimum: 100, score: green)
            ?? region(shown, hidden, minimum: 100, scale: 1, threshold: 25, score: green)
    }

    /// Rect of the yellow preview box: the largest blob among pixels that got **more yellow** in the after frame.
    ///
    /// The green box drawn while moving focus disappearing also counts as a change. So count only yellowness,
    /// not all changed pixels. It's translucent yellow, so on any background (red - blue) goes up.
    static func yellowBox(before: CGImage, after: CGImage) -> CGRect? {
        region(after, before, minimum: 200) { a, i in
            Int(a[i]) - Int(a[i + 2]) + Int(a[i + 1]) / 2 - Int(a[i + 2]) / 2
        }
    }

    /// Bounding rect of the largest blob among pixels where `score(with)` - `score(without)` exceeds
    /// `threshold`.
    private static func region(
        _ with: CGImage, _ without: CGImage, minimum: Int, scale: Int = 2, threshold: Int = 40,
        score: ([UInt8], Int) -> Int
    ) -> CGRect? {
        guard with.width == without.width, with.height == without.height else { return nil }
        // Work at half size by default. At full size it's 3.6M pixels and took over 0.5 s per pass in a
        // debug build. The box border is usually a few pixels thick so it stays connected at half size. The
        // rect comes back within 2 pixels.
        let a = rgba(with, scale: scale)
        let b = rgba(without, scale: scale)
        let width = with.width / scale
        let height = with.height / scale
        var mask = [Bool](repeating: false, count: width * height)
        // Skip the status bar, whose clock changes.
        for y in Int(Double(height) * 0.04)..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if score(a, i) - score(b, i) > threshold { mask[y * width + x] = true }
            }
        }
        guard let rect = largestRegion(mask, width: width, height: height, minimum: minimum / (scale * scale))
        else { return nil }
        let s = CGFloat(scale)
        return CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
    }

    /// Bounding rect of the **single largest blob** of set pixels.
    ///
    /// Don't use the bounds of all set pixels. A Live Activity in the Dynamic Island (a music waveform) reached
    /// just below the status bar and kept moving, so Settings' "General" was measured from the top of the
    /// screen down to that row (1172x1329). The box, outline or filled, is one connected blob, while such
    /// noise is separate. Diagonals count as neighbors (thin borders look broken in places due to
    /// antialiasing).
    ///
    /// For rows spanning the full screen width (a messenger's chat list), the box's left/right edges are
    /// clipped at the screen edge and the fill is faint, so it's picked up as **two separate blobs: the top
    /// line and the bottom line**. Taking only the largest made the top line (16px tall) the row rect, and
    /// swiping there opened the neighboring chat row. So if the largest blob is a thin horizontal line, find
    /// a partner line with the same horizontal extent and merge the two.
    static func largestRegion(_ mask: [Bool], width: Int, height: Int, minimum: Int) -> CGRect? {
        let all = regions(mask, width: width, height: height).sorted { $0.count > $1.count }
        guard let best = all.first, best.count > minimum else { return nil }
        let rect = best.rect
        let line = { (r: CGRect) in r.height * 8 < r.width && r.height <= 12 }
        guard line(rect) else { return rect }
        let partner = all.dropFirst().first { other in
            line(other.rect) && other.count * 3 > best.count
                && abs(other.rect.minX - rect.minX) <= rect.width * 0.05
                && abs(other.rect.maxX - rect.maxX) <= rect.width * 0.05
                && abs(other.rect.midY - rect.midY) > 12
        }
        return partner.map { rect.union($0.rect) } ?? rect
    }

    /// Blobs of set pixels (diagonals count as neighbors): pixel count and bounds.
    private static func regions(_ mask: [Bool], width: Int, height: Int) -> [(count: Int, rect: CGRect)] {
        var visited = [Bool](repeating: false, count: mask.count)
        var found: [(count: Int, rect: CGRect)] = []
        var stack: [Int] = []

        for start in mask.indices where mask[start] && !visited[start] {
            visited[start] = true
            stack.append(start)
            var count = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            while let index = stack.popLast() {
                count += 1
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let neighbor = ny * width + nx
                        if mask[neighbor] && !visited[neighbor] {
                            visited[neighbor] = true
                            stack.append(neighbor)
                        }
                    }
                }
            }
            found.append((count, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)))
        }
        return found
    }

    /// RGBA drawn at 1/`scale` size.
    private static func rgba(_ image: CGImage, scale: Int) -> [UInt8] {
        let width = image.width / scale
        let height = image.height / scale
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .low
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
