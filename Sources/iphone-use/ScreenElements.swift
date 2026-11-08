import AppKit
import CoreGraphics
import Foundation

/// Controls without text, found by their shape on the screenshot: switches with their state, and small
/// one-color icons, named when they match a common SF Symbol. `ui` lists them as `[bracketed]` lines next
/// to the OCR text, so an agent can tell whether a switch is on, or press a back chevron, without looking
/// at the image (PITFALLS #52).
///
/// Works at about point resolution. The screen is cut into flat-color regions; large ones are
/// backgrounds, and what's left groups into blobs: text, glyphs, controls. Vision's contour detection was
/// tried first and missed light-mode switches entirely (a light gray track on white has too little
/// contrast).
enum ScreenElements {
    /// Pixels per point when the device didn't say (`getdisplayinfo`'s `pointScale` is the real answer):
    /// iPhones are 3x and iPads 2x, but the foldable's inner panel (2007px wide) is as wide as an iPad's,
    /// so size alone can't tell.
    static func guessScale(width: Int, height: Int) -> Int {
        let short = min(width, height)
        return short < 1000 || short >= 1450 ? 2 : 3
    }

    /// Bracketed lines for the controls on `image`, and the button shape around each text line that sits
    /// on one (keyed by its index in `text`). `text` is the OCR result: icons overlapping text are skipped
    /// (OCR already has them, like "›" or "✓"), and a switch takes the label to its left.
    static func find(in image: CGImage, text: [TextRecognizer.Line], scale s: Int)
        -> (controls: [TextRecognizer.Line], buttons: [Int: CGRect])
    {
        guard let map = RegionMap(image, scale: s) else { return ([], [:]) }
        let px = CGFloat(s)
        var found: [TextRecognizer.Line] = []
        var taken: [CGRect] = []

        for blob in map.blobs {
            guard let state = map.switchState(blob) else { continue }
            let frame = blob.rect.scaled(px)
            let label = text.filter { $0.frame.maxX < frame.minX && abs($0.frame.midY - frame.midY) < frame.height * 0.6 }
                .max { $0.frame.maxX < $1.frame.maxX }
            found.append(.init(text: "[toggle \(state)]" + (label.map { " " + $0.text } ?? ""), frame: frame))
            taken.append(frame)
        }

        let textInPoints = text.map { CGRect(x: $0.frame.minX / px, y: $0.frame.minY / px, width: $0.frame.width / px, height: $0.frame.height / px) }
        let shapes = map.buttonShapes(text: textInPoints).filter { shape in
            !taken.contains { $0.intersects(shape.frame.scaled(px)) }
        }
        var buttons: [Int: CGRect] = [:]
        for shape in shapes {
            let frame = shape.frame.scaled(px)
            if let index = shape.text {
                // The label is already a line; the shape only says where the button is.
                if buttons[index].map({ $0.width * $0.height < frame.width * frame.height }) ?? true {
                    buttons[index] = frame
                }
                continue
            }
            guard let glyph = shape.glyph else { continue }
            if leadingIcon(frame, text: text, px: px) { continue }
            let name = Ink(image, glyph.scaled(px).insetBy(dx: -px, dy: -px)).flatMap { $0.oneColor ? Symbols.name(for: $0) : nil }
            found.append(.init(text: "[\(name ?? (shape.round ? "circle button" : "button"))]", frame: frame))
            taken.append(frame)
        }

        for group in map.iconGroups(skipping: textInPoints) {
            let frame = group.scaled(px)
            if taken.contains(where: { $0.insetBy(dx: -px * 3, dy: -px * 3).contains(frame) }) { continue }
            // A glyph on a button (listed above, or a text button's icon) is the button.
            if shapes.contains(where: { $0.frame.scaled(px).insetBy(dx: -px * 2, dy: -px * 2).contains(frame) }) { continue }
            let overlapsText = text.contains { line in
                let i = line.frame.intersection(frame)
                return !i.isNull && i.width * i.height > 0.3 * frame.width * frame.height
            }
            if overlapsText { continue }
            if leadingIcon(frame, text: text, px: px) { continue }
            guard let ink = Ink(image, frame.insetBy(dx: -px, dy: -px)), ink.oneColor else { continue }
            found.append(.init(text: "[\(Symbols.name(for: ink) ?? "icon")]", frame: frame))
        }
        return (found, buttons)
    }

    /// A big icon right before a row's text (Settings' colored squares, a profile picture next to a name)
    /// adds nothing: pressing the text does the same. Small ones stay, like a heart before its like count.
    private static func leadingIcon(_ frame: CGRect, text: [TextRecognizer.Line], px: CGFloat) -> Bool {
        frame.width >= 24 * px && frame.height >= 24 * px && text.contains { line in
            line.frame.minX > frame.maxX && line.frame.minX - frame.maxX < 16 * px
                && abs(line.frame.midY - frame.midY) < frame.height * 0.7
        }
    }
}

extension CGRect {
    fileprivate func scaled(_ s: CGFloat) -> CGRect {
        CGRect(x: minX * s, y: minY * s, width: width * s, height: height * s)
    }
}

// MARK: - Regions and blobs

/// The screen at point resolution, cut into flat-color regions, with the non-background pixels grouped
/// into blobs.
private struct RegionMap {
    struct Blob {
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        var pixels: [Int] = []
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
    }

    let w: Int, h: Int
    private var rgb: [UInt8]
    private var region: [Int32]
    private var regionSize: [Int]
    private(set) var blobs: [Blob] = []

    /// Regions larger than this (in points²) are backgrounds: cards, bars, the page. A switch track is
    /// about 1,200.
    static let backgroundArea = 1500

    init?(_ image: CGImage, scale: Int) {
        w = image.width / scale
        h = image.height / scale
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        rgb = data
        region = [Int32](repeating: -1, count: w * h)
        regionSize = []
        segment()
        blobs = Self.group(w: w, h: h, all: Array(0..<(w * h))) { [regionSize, region] in
            regionSize[Int(region[$0])] > Self.backgroundArea
        }
    }

    func color(_ i: Int) -> (Int, Int, Int) { (Int(rgb[i * 4]), Int(rgb[i * 4 + 1]), Int(rgb[i * 4 + 2])) }

    static func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int) -> Bool {
        abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
    }

    /// Flood fill into regions of about one color. A pixel joins when it's close both to its neighbor
    /// (soft gradients) and to the region's first pixel (so a gradient doesn't swallow everything).
    private mutating func segment() {
        var stack: [Int] = []
        for start in 0..<(w * h) where region[start] < 0 {
            let id = Int32(regionSize.count)
            let seed = color(start)
            var n = 0
            region[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                let c = color(i)
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                where j >= 0 && region[j] < 0 {
                    let cj = color(j)
                    if Self.near(cj, seed, 10) && Self.near(cj, c, 6) {
                        region[j] = id
                        stack.append(j)
                    }
                }
            }
            regionSize.append(n)
        }
    }

    /// 8-connected groups of the pixels in `all` that aren't background.
    static func group(w: Int, h: Int, all: [Int], isBackground: (Int) -> Bool) -> [Blob] {
        // Whole-screen flags for the first pass; a set for a single blob's pixels, which would otherwise
        // allocate two screen-sized arrays per blob looked into.
        let small = all.count * 4 < w * h
        var memberFlags = small ? [] : [Bool](repeating: false, count: w * h)
        var memberSet = Set<Int>()
        for i in all where !isBackground(i) {
            if small { memberSet.insert(i) } else { memberFlags[i] = true }
        }
        func member(_ i: Int) -> Bool { small ? memberSet.contains(i) : memberFlags[i] }
        var seenFlags = small ? [] : [Bool](repeating: false, count: w * h)
        var seenSet = Set<Int>()
        func seen(_ i: Int) -> Bool { small ? seenSet.contains(i) : seenFlags[i] }
        func see(_ i: Int) { if small { seenSet.insert(i) } else { seenFlags[i] = true } }

        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in all where member(start) && !seen(start) {
            var blob = Blob()
            see(start)
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                blob.pixels.append(i)
                blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if member(j) && !seen(j) {
                            see(j)
                            stack.append(j)
                        }
                    }
                }
            }
            blobs.append(blob)
        }
        return blobs
    }

    /// "on" / "off" if the blob is a switch: a filled capsule about 28–34 pt high with a white knob at one
    /// end. Its state is where the knob is, not the track color: apps tint the track, and the off track is
    /// light gray in light mode but dark gray in dark mode.
    func switchState(_ blob: Blob) -> String? {
        guard blob.height >= 22, blob.height <= 40 else { return nil }
        let aspect = Double(blob.width) / Double(blob.height)
        guard aspect > 1.7, aspect < 2.8 else { return nil }
        // A capsule fills about 0.8 of its box; the Wi-Fi glyph and other outlines fill much less.
        guard Double(blob.pixels.count) / Double(blob.width * blob.height) > 0.6 else { return nil }
        var knobX = 0, knobN = 0
        for i in blob.pixels {
            let c = color(i)
            if lum(c) > 0.96 && saturation(c) < 0.08 {
                knobX += i % w
                knobN += 1
            }
        }
        guard knobN > 30 else { return nil }
        let at = (Double(knobX) / Double(knobN) - Double(blob.minX)) / Double(blob.width)
        // A capsule button with a white label has its "knob" in the middle.
        if at > 0.55 { return "on" }
        if at < 0.45 { return "off" }
        return nil
    }

    /// Icon-sized groups of blobs. Pieces close together become one (a repost icon's two arrows, ⓘ's
    /// dot and stem). A bigger blob with a flat fill inside (a round button with a glyph on it) is looked
    /// into: the fill is its background, and the glyph comes out on its own.
    /// Pieces mostly inside a `text` rect (points) are letters, left out before merging: there are hundreds
    /// of them, and merging is quadratic.
    func iconGroups(skipping text: [CGRect]) -> [CGRect] {
        var pieces: [CGRect] = []
        for blob in blobs {
            // A thin outline around something bigger (a round button's rim) would be merged with the
            // glyph inside it.
            let outline = max(blob.width, blob.height) > 30 && blob.pixels.count * 5 < blob.width * blob.height
            if outline { continue }
            if blob.width <= 44 && blob.height <= 44 {
                pieces.append(blob.rect)
            } else if blob.width <= 64 && blob.height <= 64 {
                // The fill: the blob's largest region.
                var count: [Int32: Int] = [:]
                for i in blob.pixels { count[region[i], default: 0] += 1 }
                guard let fill = count.max(by: { $0.value < $1.value }), fill.value * 10 > blob.pixels.count * 4 else {
                    continue
                }
                let inner = Self.group(w: w, h: h, all: blob.pixels) { region[$0] == fill.key }
                pieces += inner.filter {
                    $0.pixels.count > 8 && !(max($0.width, $0.height) > 30 && $0.pixels.count * 5 < $0.width * $0.height)
                }.map(\.rect)
            }
        }
        pieces = pieces.filter { piece in
            guard piece.width >= 6 || piece.height >= 6 else { return false }
            return !text.contains { t in
                let i = t.intersection(piece)
                return !i.isNull && i.width * i.height > 0.5 * piece.width * piece.height
            }
        }
        // Merge pieces whose boxes come within 2 pt of each other, while the result stays icon-sized.
        var merged = true
        while merged {
            merged = false
            outer: for a in 0..<pieces.count {
                for b in (a + 1)..<pieces.count where pieces[a].insetBy(dx: -2, dy: -2).intersects(pieces[b]) {
                    let u = pieces[a].union(pieces[b])
                    guard u.width <= 44, u.height <= 44 else { continue }
                    pieces[a] = u
                    pieces.remove(at: b)
                    merged = true
                    break outer
                }
            }
        }
        return pieces.filter { r in
            let aspect = r.width / r.height
            return r.width >= 8 && r.height >= 8 && aspect > 0.3 && aspect < 3.5
        }
    }

    struct Shape {
        /// Points.
        var frame: CGRect
        /// A disc, rather than a capsule or a rounded rectangle.
        var round: Bool
        /// The glyph on it (points), when it has no text.
        var glyph: CGRect?
        /// The index of the text line on it.
        var text: Int?
    }

    /// Buttons by their shape: a filled disc, capsule or rounded rectangle 20–96 pt high with a glyph or one
    /// line of text on it. Found from the flat-color regions rather than the blobs (PITFALLS #59, #60).
    ///
    /// Blobs missed round buttons two ways. A small disc is one blob of two colors, which the one-color
    /// check throws out. And a disc touching a bigger shape (the input bar it sits in) joins that shape's
    /// blob, which is too big to look into; whether it touched changed between two captures of the same
    /// screen. The fill region itself doesn't depend on either.
    ///
    /// What is left out, and why:
    /// - Square corners (list rows, cards, banners): a button's corners are rounded, so a point 2 pt in
    ///   from each corner of its box lies outside the fill.
    /// - Anything wider than 70% of the screen (a grouped list's one-row card, a search bar): the text on
    ///   it is already a line, and boxing it would cover the screen.
    /// - A rounded square with a glyph (a Settings row's colored icon, an app icon): it would put its
    ///   glyph next to every row label. Only discs and shapes wider than high take a glyph.
    /// - A shape with more than one line of text, or text spilling over its edge (a chat bubble, a card).
    /// - An empty shape (a switch's knob, a color swatch).
    func buttonShapes(text: [CGRect]) -> [Shape] {
        let n = regionSize.count
        var minX = [Int](repeating: Int.max, count: n), minY = minX
        var maxX = [Int](repeating: -1, count: n), maxY = maxX
        for y in 0..<h {
            for x in 0..<w {
                let id = Int(region[y * w + x])
                if x < minX[id] { minX[id] = x }
                if x > maxX[id] { maxX[id] = x }
                if y < minY[id] { minY[id] = y }
                if y > maxY[id] { maxY[id] = y }
            }
        }
        var found: [Shape] = []
        for id in 0..<n where regionSize[id] >= 120 {
            let bw = maxX[id] - minX[id] + 1, bh = maxY[id] - minY[id] + 1
            guard (20...96).contains(bh), bw >= 20, Double(bw) <= Double(w) * 0.7 else { continue }
            let aspect = Double(bw) / Double(bh)
            guard aspect > 0.85 else { continue }
            let round = aspect < 1.18
            let box = CGRect(x: minX[id], y: minY[id], width: bw, height: bh)
            // By color, not region id: a slight gradient splits one fill into a few regions.
            let fill = color(minY[id] * w + (0..<w).first(where: { Int(region[minY[id] * w + $0]) == id })!)
            // How near counts as fill depends on the surroundings: a light gray chip on white is only about 15
            // apart from the page, and a fixed tolerance took the page for the chip, so its corners looked filled.
            let midX = (minX[id] + maxX[id]) / 2, midY = (minY[id] + maxY[id]) / 2
            // 4 pt out: a glass key's darker rim ring sits right outside its fill.
            let outside = [(midX, minY[id] - 4), (midX, maxY[id] + 4), (minX[id] - 4, midY), (maxX[id] + 4, midY)]
                .filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 < w && $0.1 < h }
                .map { color($0.1 * w + $0.0) }
            let contrast = outside.map { max(abs($0.0 - fill.0), abs($0.1 - fill.1), abs($0.2 - fill.2)) }.min() ?? 48
            guard contrast >= 6 else { continue }
            let tolerance = min(24, contrast / 2)
            func isFill(_ x: Int, _ y: Int) -> Bool { Self.near(color(y * w + x), fill, tolerance) }
            var filled = 0
            for y in minY[id]...maxY[id] { for x in minX[id]...maxX[id] where isFill(x, y) { filled += 1 } }
            guard Double(filled) > 0.45 * Double(bw * bh) else { continue }
            // Corners: a disc's edge passes 0.15 of its size from its box's corner, so 0.1 in is outside it;
            // a rounded square's (radius about 0.22) passes 0.06 from it, so 0.1 in is inside. Wider shapes
            // just need rounded corners: 2 pt in is outside any corner radius over 7 pt.
            let inset = round ? Double(bw) * 0.1 : 2
            let corners = [
                (Double(minX[id]) + inset, Double(minY[id]) + inset), (Double(maxX[id]) - inset, Double(minY[id]) + inset),
                (Double(minX[id]) + inset, Double(maxY[id]) - inset), (Double(maxX[id]) - inset, Double(maxY[id]) - inset),
            ]
            guard !corners.contains(where: { isFill(Int($0.0.rounded()), Int($0.1.rounded())) }) else { continue }
            let rim = max(1, Int(Double(min(bw, bh)) * 0.06))
            let rims = [(midX, minY[id] + rim), (midX, maxY[id] - rim), (minX[id] + rim, midY), (maxX[id] - rim, midY)]
            guard rims.allSatisfy({ isFill($0.0, $0.1) }) else { continue }

            let touching = text.indices.filter { text[$0].intersects(box) }
            if !touching.isEmpty {
                // One line, wholly on it, and tall enough to be its label rather than small print on a card.
                guard touching.count == 1, let index = touching.first,
                    box.insetBy(dx: -1, dy: -1).contains(text[index]), text[index].height >= Double(bh) * 0.25
                else { continue }
                found.append(Shape(frame: box, round: round, glyph: nil, text: index))
                continue
            }
            // A rounded square with a glyph is an app's or a Settings row's icon, not a button.
            guard round || aspect >= 1.4 else { continue }
            // The glyph: what isn't fill well inside the rim.
            let cx = Double(minX[id] + maxX[id]) / 2, cy = Double(minY[id] + maxY[id]) / 2
            let rx = Double(bw) / 2 - Double(bh) * 0.1, ry = Double(bh) / 2 * 0.8
            var gx0 = Int.max, gy0 = Int.max, gx1 = -1, gy1 = -1, count = 0
            for y in minY[id]...maxY[id] {
                for x in minX[id]...maxX[id] where !isFill(x, y) {
                    let dx = (Double(x) - cx) / rx, dy = (Double(y) - cy) / ry
                    guard round ? hypot(Double(x) - cx, Double(y) - cy) < Double(min(bw, bh)) / 2 * 0.8 : (abs(dx) < 1 && abs(dy) < 1) else { continue }
                    count += 1
                    gx0 = min(gx0, x); gx1 = max(gx1, x); gy0 = min(gy0, y); gy1 = max(gy1, y)
                }
            }
            guard count >= 8 else { continue }
            let glyph = CGRect(x: gx0, y: gy0, width: gx1 - gx0 + 1, height: gy1 - gy0 + 1)
            guard glyph.width <= Double(bw) * 0.8, glyph.height <= Double(bh) * 0.8 else { continue }
            found.append(Shape(frame: box, round: round, glyph: glyph, text: nil))
        }
        // A shape inside another (a disc on a capsule) is the smaller button; the outer one is its track.
        return found.filter { shape in
            !found.contains { other in
                other.frame != shape.frame && shape.frame.insetBy(dx: -1, dy: -1).contains(other.frame)
            }
        }
    }
}

private func lum(_ c: (Int, Int, Int)) -> Double {
    (0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)) / 255
}

private func saturation(_ c: (Int, Int, Int)) -> Double {
    let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2)
    return mx == 0 ? 0 : Double(mx - mn) / Double(mx)
}

// MARK: - Icon shapes

/// The pixels of a glyph that differ from the background around it, at full resolution.
private struct Ink {
    var mask: [Bool]
    var w: Int, h: Int
    /// True when the ink is one color, as icons are. Photos, avatars and emoji aren't.
    var oneColor: Bool

    init?(_ image: CGImage, _ rect: CGRect) {
        guard let crop = image.cropping(to: rect.integral) else { return nil }
        self.init(crop)
    }

    init?(_ crop: CGImage) {
        let cw = crop.width, ch = crop.height
        guard cw > 2, ch > 2 else { return nil }
        var p = [UInt8](repeating: 0, count: cw * ch * 4)
        guard
            let ctx = CGContext(
                data: &p, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        // The background is the border's average color.
        var bg = (0, 0, 0), n = 0
        func add(_ x: Int, _ y: Int) {
            let i = (y * cw + x) * 4
            bg.0 += Int(p[i]); bg.1 += Int(p[i + 1]); bg.2 += Int(p[i + 2]); n += 1
        }
        for x in 0..<cw { add(x, 0); add(x, ch - 1) }
        for y in 1..<(ch - 1) { add(0, y); add(cw - 1, y) }
        bg = (bg.0 / n, bg.1 / n, bg.2 / n)

        var full = [Bool](repeating: false, count: cw * ch)
        var minX = cw, minY = ch, maxX = -1, maxY = -1
        var inks: [(diff: Int, color: (Int, Int, Int))] = []
        for y in 0..<ch {
            for x in 0..<cw {
                let i = (y * cw + x) * 4
                let c = (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
                let diff = abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2)
                guard diff > 150 else { continue }
                full[y * cw + x] = true
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                inks.append((diff, c))
            }
        }
        guard maxX >= 0, inks.count >= 8 else { return nil }
        // Judge the color by the solid core only: anti-aliased edges are blends with the background and
        // would make every glyph look multicolored.
        let strongest = inks.map(\.diff).max()!
        let core = inks.filter { $0.diff * 10 >= strongest * 8 }
        func sd(_ value: ((Int, Int, Int)) -> Int) -> Double {
            let v = core.map { Double(value($0.color)) }
            let mean = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        // A photo's colors spread out, so few of its pixels are as far from the background as the farthest.
        oneColor = core.count * 20 >= inks.count * 9 && max(sd { $0.0 }, sd { $0.1 }, sd { $0.2 }) < 40
        w = maxX - minX + 1
        h = maxY - minY + 1
        mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { mask[y * w + x] = full[(y + minY) * cw + x + minX] } }
    }
}

/// Matching a glyph against rendered SF Symbols. Only common navigation symbols: with all ~9,500, look-
/// alikes win as often as the right one. Filled discs (`xmark.circle.fill`) are left out: every round
/// profile picture matched them (PITFALLS #52).
private enum Symbols {
    static let names = [
        "chevron.left", "chevron.right", "chevron.down", "chevron.up", "plus", "xmark", "checkmark",
        "info.circle", "magnifyingglass", "square.and.arrow.up", "trash", "ellipsis", "ellipsis.circle",
        "gearshape", "heart", "heart.fill", "star", "star.fill", "bell", "square.and.pencil",
        "line.3.horizontal", "line.3.horizontal.decrease", "slider.horizontal.3", "arrow.up", "arrow.left",
        "arrow.clockwise", "mic", "camera", "photo", "play.fill", "pause.fill", "bookmark", "list.bullet",
        "calendar", "clock", "folder", "paperplane", "house", "house.fill", "person.crop.circle", "globe",
        "alarm.fill", "stopwatch.fill", "timer", "square.grid.2x2", "minus", "arrow.down.circle",
        "lock.fill", "wifi", "square.and.arrow.down", "doc.text.image", "sparkles",
    ]

    static let side = 32

    /// Normalized masks, rendered once per process (the daemon keeps them).
    /// Three weights: apps draw the same symbol light (a list's check mark) or semibold (a back chevron).
    static let templates: [(name: String, shape: [Float], aspect: Double)] = names.flatMap { name in
        [NSFont.Weight.light, .regular, .semibold].compactMap { render(name, weight: $0) }
    }

    static func render(_ name: String, weight: NSFont.Weight) -> (name: String, shape: [Float], aspect: Double)? {
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 40, weight: weight))
        else { return nil }
        let size = symbol.size
        let w = Int(size.width) + 8, h = Int(size.height) + 8
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: NSRect(x: 4, y: 4, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage(), let ink = Ink(image) else { return nil }
        return (name.replacingOccurrences(of: ".", with: " "), shape(ink), Double(ink.w) / Double(ink.h))
    }

    /// The best match if it's close enough. Below this score custom icons start getting confident wrong
    /// names (a profile picture as "xmark circle fill").
    static func name(for ink: Ink) -> String? {
        let v = shape(ink), aspect = Double(ink.w) / Double(ink.h)
        var best: (String, Float)?
        for t in templates {
            let penalty = Float(min(1, abs(log(aspect / t.aspect)) / 1.2))
            let s = cosine(v, t.shape) * (1 - 0.5 * penalty)
            if s > (best?.1 ?? 0) { best = (t.name, s) }
        }
        guard let best, best.1 >= 0.94 else { return nil }
        return best.0
    }

    /// Fits the mask into a `side`² square keeping its aspect, and blurs it a little so a line one pixel
    /// off still overlaps.
    static func shape(_ ink: Ink) -> [Float] {
        let n = side
        var out = [Float](repeating: 0, count: n * n)
        let s = Double(n - 4) / Double(max(ink.w, ink.h))
        let ox = (Double(n) - Double(ink.w) * s) / 2, oy = (Double(n) - Double(ink.h) * s) / 2
        for y in 0..<n {
            for x in 0..<n {
                let sx = (Double(x) + 0.5 - ox) / s, sy = (Double(y) + 0.5 - oy) / s
                let ix = Int(sx), iy = Int(sy)
                if sx >= 0, sy >= 0, ix < ink.w, iy < ink.h, ink.mask[iy * ink.w + ix] { out[y * n + x] = 1 }
            }
        }
        var blurred = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var acc: Float = 0, count: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < n, ny < n { acc += out[ny * n + nx]; count += 1 }
                    }
                }
                blurred[y * n + x] = acc / count
            }
        }
        return blurred
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for i in 0..<a.count {
            ab += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        return ab / ((aa * bb).squareRoot() + 1e-6)
    }
}
