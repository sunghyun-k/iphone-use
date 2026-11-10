import CoreGraphics
import Foundation

/// The screen at point resolution, as plain RGB. `ScreenState` reads what isn't a control of its own:
/// whether a popup is up, which of a row's items is selected, where a slider stands.
struct PointBitmap {
    let w: Int, h: Int
    let scale: Int
    private let rgb: [UInt8]

    init?(_ image: CGImage, scale: Int) {
        w = image.width / scale
        h = image.height / scale
        self.scale = scale
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
    }

    func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
        return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
    }

    static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }
}

enum ScreenState {
    /// A popup over a dimmed screen: the card, then any small undimmed pieces beside it (a close button
    /// floating above its corner). Pixels. `nil` when nothing says a popup is up.
    ///
    /// An app dims the page behind a popup with a black layer of 40% or more. That turns the page's white
    /// into a mid gray, and caps every channel of everything under it at that gray's level: a pixel
    /// brighter than that isn't under the layer. So when a neutral gray between 70 and 190 is the most
    /// common color and everything brighter is gathered in one place, that place is the popup
    /// (PITFALLS #66). The lighter dimming behind a system sheet or alert leaves white above 190, as light
    /// as a keyboard's gray, and isn't looked for: their buttons are in the list anyway. A dark-mode
    /// page is black with or without the layer, so nothing is found there either.
    static func popup(in bitmap: PointBitmap) -> [CGRect]? {
        let w = bitmap.w, h = bitmap.h
        let top = h * 6 / 100
        guard let dim = dimming(in: bitmap) else { return nil }
        // Nothing brighter may be as common: on a page that simply has a gray area, white is. Not half
        // as common was too strict: a large coupon card made white 57% as common as the dimmed gray, and
        // its popup went unnoticed (PITFALLS #70). The checks below still need one card and few strays.
        guard dim.brighter < 1 else { return nil }
        let cap = dim.cap

        // Cells of 4 pt that are mostly brighter than the layer allows.
        let cell = 4
        let cw = w / cell, ch = h / cell
        var lit = [Bool](repeating: false, count: cw * ch)
        for cy in (top / cell)..<ch {
            for cx in 0..<cw {
                var n = 0
                for dy in 0..<cell {
                    for dx in 0..<cell {
                        let c = bitmap.color(cx * cell + dx, cy * cell + dy)
                        if max(c.0, c.1, c.2) > cap { n += 1 }
                    }
                }
                lit[cy * cw + cx] = n * 2 >= cell * cell
            }
        }
        // Connected groups of lit cells.
        var seen = [Bool](repeating: false, count: cw * ch)
        var groups: [(rect: CGRect, cells: Int)] = []
        var stack: [Int] = []
        for start in 0..<(cw * ch) where lit[start] && !seen[start] {
            var minX = cw, minY = ch, maxX = 0, maxY = 0, n = 0
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % cw, y = i / cw
                n += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
                        let j = ny * cw + nx
                        if lit[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            groups.append((CGRect(x: minX * cell, y: minY * cell, width: (maxX - minX + 1) * cell, height: (maxY - minY + 1) * cell), n))
        }
        // A navigation bar or a tab bar the layer doesn't cover (a popup drawn inside the content area)
        // is lit too: full width, at the top or the bottom. It's neither the card nor a stray.
        groups.removeAll { group in
            group.rect.minX <= CGFloat(cell) && group.rect.maxX >= CGFloat(w - 2 * cell)
                && (group.rect.maxY < CGFloat(h) * 0.25 || group.rect.minY > CGFloat(h) * 0.8)
        }
        guard let card = groups.max(by: { $0.cells < $1.cells }) else { return nil }
        let screen = cw * (ch - top / cell)
        // A card, not a speck and not the page: 3% to 75% of the screen, and at least 80 pt each way.
        guard card.cells * 100 >= screen * 3, card.cells * 100 <= screen * 75, card.rect.width >= 80, card.rect.height >= 80
        else { return nil }
        // Everything else that's lit is small and close by. More than that, and the "card" is one bright
        // area among several, which is an ordinary page.
        let near = card.rect.insetBy(dx: -72, dy: -72)
        var pieces: [CGRect] = []
        var stray = 0
        for group in groups where group.rect != card.rect {
            if card.rect.contains(group.rect) { continue }
            if near.intersects(group.rect), group.rect.width <= 64, group.rect.height <= 64 {
                if group.rect.width >= 20, group.rect.height >= 20 { pieces.append(group.rect) }
            } else {
                stray += group.cells
            }
        }
        guard stray * 100 <= screen * 3 else { return nil }
        let px = CGFloat(bitmap.scale)
        return ([card.rect] + pieces).map { CGRect(x: $0.minX * px, y: $0.minY * px, width: $0.width * px, height: $0.height * px) }
    }

    /// The dimmed white behind a popup or an overlay: the most common neutral gray between 70 and 190,
    /// its share of the screen, how common anything brighter is next to it, and the brightest a pixel
    /// under the layer can be (`cap`). Nil when no gray is common enough (10% of the screen).
    static func dimming(in bitmap: PointBitmap) -> (cap: Int, share: Double, brighter: Double)? {
        let w = bitmap.w, h = bitmap.h
        let top = h * 6 / 100
        var grays = [Int](repeating: 0, count: 256)
        var total = 0
        for y in stride(from: top, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let c = bitmap.color(x, y)
                total += 1
                if max(c.0, c.1, c.2) - min(c.0, c.1, c.2) <= 10 { grays[(c.0 + c.1 + c.2) / 3] += 1 }
            }
        }
        // A window of 9 levels: the dimmed page isn't exactly one value (cards, separators).
        var best = (level: 0, count: 0)
        for level in 70...190 {
            let count = grays[(level - 4)...(level + 4)].reduce(0, +)
            if count > best.count { best = (level, count) }
        }
        guard total > 0, best.count * 100 >= total * 10 else { return nil }
        let brighter = grays[min(255, best.level + 20)...].reduce(0, +)
        return (best.level + 22, Double(best.count) / Double(total), Double(brighter) / Double(best.count))
    }

    /// The lines drawn over a dimmed screen with no card under them: a tip or a tutorial's coach mark
    /// ("try the map", an OK button, the control it points at left bright). Trip planning results had
    /// one; `popup` found no card, and the list said nothing (PITFALLS #70). Indices into `lines`
    /// (pixel frames). Only when the dimmed gray covers half the screen and almost nothing else is
    /// bright, so a page that simply has a gray area isn't taken for one.
    static func overlay(_ lines: [TextRecognizer.Line], in bitmap: PointBitmap) -> [Int] {
        guard let dim = dimming(in: bitmap), dim.share >= 0.5, dim.brighter < 0.1 else { return [] }
        let px = CGFloat(bitmap.scale)
        let bright = lines.indices.filter { index in
            let f = lines[index].frame
            let frame = CGRect(x: f.minX / px, y: f.minY / px, width: f.width / px, height: f.height / px)
            guard let (ink, ground) = colors(of: frame, in: bitmap) else { return false }
            // Well above the cap: a dimmed blue badge with white text came just over it and was listed as
            // on the tip. What a tip draws is near white.
            return max(ink.0, ink.1, ink.2) > dim.cap + 40 || max(ground.0, ground.1, ground.2) > dim.cap + 40
        }
        // Most of the screen is behind the layer; if most lines are bright, it's not a layer.
        return bright.count * 2 <= lines.count ? bright : []
    }

    /// A line's text color and the color behind it, in points.
    static func colors(of frame: CGRect, in bitmap: PointBitmap) -> (ink: (Int, Int, Int), ground: (Int, Int, Int))? {
        let x0 = Int(frame.minX) - 2, x1 = Int(frame.maxX) + 2, y0 = Int(frame.minY) - 2, y1 = Int(frame.maxY) + 2
        guard x1 > x0, y1 > y0 else { return nil }
        // The ground is the most common color along the frame's edge (in steps of 16): inside, a filled
        // glyph's own body can be the most common one. The ink is what's far from the ground.
        var buckets: [Int: (n: Int, sum: (Int, Int, Int))] = [:]
        func count(_ x: Int, _ y: Int) {
            let c = bitmap.color(x, y)
            let key = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4)
            var b = buckets[key] ?? (0, (0, 0, 0))
            b.n += 1; b.sum.0 += c.0; b.sum.1 += c.1; b.sum.2 += c.2
            buckets[key] = b
        }
        for x in x0...x1 { count(x, y0); count(x, y1) }
        for y in y0...y1 { count(x0, y); count(x1, y) }
        guard let top = buckets.values.max(by: { $0.n < $1.n }) else { return nil }
        let ground = (top.sum.0 / top.n, top.sum.1 / top.n, top.sum.2 / top.n)
        var far: [(d: Int, c: (Int, Int, Int))] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let c = bitmap.color(x, y)
                let d = PointBitmap.distance(c, ground)
                if d > 90 { far.append((d, c)) }
            }
        }
        guard far.count >= 6 else { return nil }
        // The strokes' cores: edges are blends with the ground.
        far.sort { $0.d > $1.d }
        let core = far.prefix(max(3, far.count / 3))
        let ink = core.reduce((0, 0, 0)) { ($0.0 + $1.c.0, $0.1 + $1.c.1, $0.2 + $1.c.2) }
        return ((ink.0 / core.count, ink.1 / core.count, ink.2 / core.count), ground)
    }

    /// Which lines are the selected one of their row: a tab bar's current tab, a segmented control's
    /// segment, a filter chip, a picked day (PITFALLS #66). Indices into `lines`.
    ///
    /// The selected item is the odd one among items that otherwise look alike: three or more short lines
    /// in a row, evenly spaced, where one differs from all the others in text color or in what's behind
    /// it, and the others match each other. A neutral line among tinted ones is the reverse, a title
    /// between two links, and isn't marked.
    static func selected(_ lines: [TextRecognizer.Line], in bitmap: PointBitmap) -> Set<Int> {
        let px = CGFloat(bitmap.scale)
        var items: [(index: Int, frame: CGRect, ink: (Int, Int, Int), ground: (Int, Int, Int), icon: Bool)] = []
        for (index, line) in lines.enumerated() {
            let text = line.text
            // Icons count among icons (a tab bar without captions), words among words.
            let icon = text.hasPrefix("[") && !["[toggle", "[checkbox", "[slider", "[page dots", "[button", "[circle button", "[selected"].contains(where: text.hasPrefix)
            guard icon || (!text.hasPrefix("[") && text.count <= 16 && text.contains(where: { $0.isLetter || $0.isNumber })) else { continue }
            let frame = CGRect(x: line.frame.minX / px, y: line.frame.minY / px, width: line.frame.width / px, height: line.frame.height / px)
            // Not in the navigation bar: its title between Cancel and Done is the odd one too.
            guard frame.height <= (icon ? 44 : 30), frame.midY > 96, let c = colors(of: frame, in: bitmap) else { continue }
            items.append((index, frame, c.ink, c.ground, icon))
        }
        func saturation(_ c: (Int, Int, Int)) -> Int { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
        var result = Set<Int>()
        var used = Set<Int>()
        for seed in items.indices where !used.contains(seed) {
            let row = items.indices.filter { i in
                !used.contains(i) && items[i].icon == items[seed].icon
                    && abs(items[i].frame.midY - items[seed].frame.midY) < items[seed].frame.height * 0.35
                    && (items[i].icon || abs(items[i].frame.height - items[seed].frame.height) < items[seed].frame.height * 0.3)
            }.sorted { items[$0].frame.midX < items[$1].frame.midX }
            used.formUnion(row)
            guard row.count >= 3 else { continue }
            let centers = row.map { items[$0].frame.midX }
            let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }
            let pitch = gaps.reduce(0, +) / CGFloat(gaps.count)
            guard gaps.allSatisfy({ abs($0 - pitch) < pitch * 0.35 }) else { continue }
            // The odd one out by one measure: it differs from every other, and the others agree.
            func oddOne(_ value: (Int) -> (Int, Int, Int), apart: Int, together: Int, _ allowed: (Int) -> Bool) -> Int? {
                let odd = row.filter { i in allowed(i) && row.allSatisfy { $0 == i || PointBitmap.distance(value(i), value($0)) > apart } }
                guard odd.count == 1 else { return nil }
                let others = row.filter { $0 != odd[0] }
                return others.allSatisfy { PointBitmap.distance(value($0), value(others[0])) <= together } ? odd[0] : nil
            }
            // A number that only has another color is today's date in red or the current hour in bold,
            // not a choice; a picked day has a filled disc behind it.
            let byGround = oddOne({ items[$0].ground }, apart: 36, together: 30) { _ in true }
            let byInk = oddOne({ items[$0].ink }, apart: 80, together: 60) { i in
                items[i].icon || lines[items[i].index].text.contains(where: \.isLetter)
            }
            guard let chosen = byGround ?? byInk else { continue }
            let pick = items[chosen]
            let other = items[row.first { $0 != chosen }!]
            let filled = byGround != nil
            // Links around a plain title: the tinted ones are the controls.
            if !filled, saturation(pick.ink) < 40, saturation(other.ink) > 90 { continue }
            // Another text color alone isn't enough among words: in a row of store names one is bold, in a
            // row of prices one is red. A tab says more: something behind it, a bar under it, or the row
            // is the tab bar at the bottom of the screen.
            let tabBar = pick.frame.midY > CGFloat(bitmap.h) * 0.88
            var underlined = false
            let xs = stride(from: Int(pick.frame.midX - pick.frame.width / 4), through: Int(pick.frame.midX + pick.frame.width / 4), by: 2)
            var rows = 0
            for y in (Int(pick.frame.maxY) + 2)...(Int(pick.frame.maxY) + 16) {
                let bar = xs.allSatisfy { PointBitmap.distance(bitmap.color($0, y), pick.ground) > 90 }
                rows = bar ? rows + 1 : 0
                if rows >= 2 { underlined = true; break }
            }
            guard filled || tabBar || underlined else { continue }
            result.insert(pick.index)
        }
        return result
    }

    /// Sliders: where the knob is (pixels) and how far along the track, 0 to 1 (PITFALLS #66).
    ///
    /// A slider is two thin bars on one line with a gap between them where the knob sits: the filled part
    /// of the track and the rest. A progress bar has no gap, a separator is thinner, and the strokes of
    /// big letters are inside `text`. With the knob at either end there is only one bar, which can't be
    /// told from an underline, so a slider at 0% or 100% isn't found.
    static func sliders(in bitmap: PointBitmap, text: [CGRect]) -> [(knob: CGRect, value: Double)] {
        let w = bitmap.w, h = bitmap.h
        let px = CGFloat(bitmap.scale)
        struct Bar { var x0: Int, x1: Int, y: Int, thick: Int, color: (Int, Int, Int) }
        var bars: [Bar] = []
        for y in (h * 6 / 100)..<(h - 4) {
            var x = 0
            while x < w {
                let c = bitmap.color(x, y)
                var end = x
                // Pixel to pixel, so a tinted track's slight gradient stays one bar.
                while end + 1 < w, PointBitmap.distance(bitmap.color(end + 1, y), bitmap.color(end, y)) <= 16,
                    PointBitmap.distance(bitmap.color(end + 1, y), c) <= 90
                { end += 1 }
                defer { x = end + 1 }
                guard end - x >= 6, end - x < w - 8 else { continue }
                let probes = [x + (end - x) / 4, (x + end) / 2, end - (end - x) / 4]
                // The middle row of a band 3 to 8 pt thick. Measured from the middle, because a rounded
                // bar's first row is a blend with the page: a light gray track's top row matched neither.
                func reach(_ step: Int) -> Int {
                    var n = 0
                    while n < 10, probes.allSatisfy({ PointBitmap.distance(bitmap.color($0, y + step * (n + 1)), bitmap.color($0, y)) <= 40 }) { n += 1 }
                    return n
                }
                let up = reach(-1), down = reach(1)
                let thick = up + down + 1
                guard (3...8).contains(thick), up == (thick - 1) / 2 else { continue }
                bars.append(Bar(x0: x, x1: end, y: y - up, thick: thick, color: c))
            }
        }
        // Longest first, and a bar belongs to one slider: a speaker glyph's stroke before the track made a
        // second, short "slider" with the filled part.
        var pairs: [(a: Int, b: Int, span: Int)] = []
        for (i, a) in bars.enumerated() {
            for (j, b) in bars.enumerated() where b.x0 > a.x1 {
                let gap = b.x0 - a.x1
                guard abs(a.y - b.y) <= 2, abs(a.thick - b.thick) <= 2, (12...64).contains(gap), b.x1 - a.x0 >= 80 else { continue }
                // The filled part is tinted and the rest isn't: two bars of one color are a dashed line,
                // a road on a map, or a piece of artwork.
                guard PointBitmap.distance(a.color, b.color) > 60 else { continue }
                pairs.append((i, j, b.x1 - a.x0))
            }
        }
        var result: [(knob: CGRect, value: Double)] = []
        var usedBars = Set<Int>()
        for pair in pairs.sorted(by: { $0.span > $1.span }) where !usedBars.contains(pair.a) && !usedBars.contains(pair.b) {
            let a = bars[pair.a], b = bars[pair.b]
            let gap = b.x0 - a.x1
            let midY = a.y + a.thick / 2
            let span = CGRect(x: a.x0, y: a.y - 2, width: b.x1 - a.x0, height: a.thick + 4)
            if text.contains(where: { $0.intersects(span) }) { continue }
            // Nothing of either bar in the gap: that's where the knob is.
            let inGap = (a.x1 + 3)..<(b.x0 - 2)
            guard inGap.allSatisfy({ x in
                let c = bitmap.color(x, midY)
                return PointBitmap.distance(c, a.color) > 24 && PointBitmap.distance(c, b.color) > 24
            }) else { continue }
            // A track lies on flat ground: one color right above and below it, all the way along. Inside an
            // app icon's artwork (a lens, a map) two bars with a gap always turned up, on changing ground.
            var around: [(Int, Int, Int)] = []
            // Not next to the gap: the knob is taller than the track and casts a shadow.
            for (x0, x1) in [(a.x0 + 2, a.x1 - 8), (b.x0 + 8, b.x1 - 2)] where x1 > x0 {
                let bar = x0 < b.x0 ? a : b
                for step in 0...6 {
                    let x = x0 + (x1 - x0) * step / 6
                    around.append(bitmap.color(x, bar.y - 3))
                    around.append(bitmap.color(x, bar.y + bar.thick + 2))
                }
            }
            guard !around.isEmpty, around.allSatisfy({ PointBitmap.distance($0, around[0]) <= 30 }) else { continue }
            usedBars.formUnion([pair.a, pair.b])
            let center = Double(a.x1 + b.x0) / 2
            let value = (center - Double(a.x0)) / Double(b.x1 - a.x0)
            let knob = CGRect(x: CGFloat(a.x1) * px, y: CGFloat(midY - 14) * px, width: CGFloat(gap) * px, height: 28 * px)
            if !result.contains(where: { $0.knob.intersects(knob) }) { result.append((knob, value)) }
        }
        return result
    }
}
