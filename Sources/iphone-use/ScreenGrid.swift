import CoreGraphics
import CoreText
import Foundation

/// A named grid drawn over a screenshot (`screenshot --grid`), and pressing by cell name (`touch --cell`).
///
/// Guessing pixel numbers from an image is off by tens of pixels, and reading from a downscaled image
/// multiplies that by the scale factor (3.2× when shrunk to 400px). On a 240px list row that's enough to hit
/// the neighboring row. Picking a cell name ("C12") means no number guessing, and a mistake stays within one
/// cell.
///
/// Cells are defined in **device pixels** — squares that divide the short side into `density` cells. However
/// far the screenshot is shrunk, a cell name points at the same place, and `touch --cell` recomputes the same
/// cell from the device screen size alone.
struct ScreenGrid {
    let width: Double
    let height: Double
    let cell: Double
    let columns: Int
    let rows: Int

    /// 10 cells by default. On an iPhone (1290px) a cell is 129px ≈ 43pt, about a fingertip.
    static let defaultDensity = 10

    init(width: Double, height: Double, density: Int = Self.defaultDensity) {
        self.width = width
        self.height = height
        cell = min(width, height) / Double(max(density, 2))
        columns = Int((width / cell).rounded(.up))
        rows = Int((height / cell).rounded(.up))
    }

    /// 0 -> A, 25 -> Z, 26 -> AA.
    static func columnName(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    func name(column: Int, row: Int) -> String { Self.columnName(column) + String(row + 1) }

    /// "C12" -> that cell (device pixels). Case-insensitive.
    func rect(named text: String) throws -> CGRect {
        let upper = text.uppercased()
        let letters = upper.prefix { $0.isLetter }
        guard !letters.isEmpty, let row = Int(upper.dropFirst(letters.count)), row >= 1 else {
            throw GridError.badCell(text)
        }
        let column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        guard column < columns, row <= rows else {
            throw GridError.outside(text, last: name(column: columns - 1, row: rows - 1))
        }
        return CGRect(
            x: Double(column) * cell, y: Double(row - 1) * cell,
            width: min(cell, width - Double(column) * cell), height: min(cell, height - Double(row - 1) * cell))
    }

    /// Draws the grid over `image` (the device screen at whatever downscale) and writes cell names in the
    /// outer margin, chessboard style.
    ///
    /// Names go on **all four sides** (letters top and bottom, numbers left and right), and only lines are
    /// drawn over the screen. Labeling every cell would cover what's underneath (small text, icons). Counting
    /// past twenty rows it's easy to slip by one, so every 5th line is bold, like graph paper, to count in
    /// chunks. With names in the margin, nothing on the screen itself is covered.
    func draw(on image: CGImage) throws -> CGImage {
        let scale = Double(image.width) / width
        let step = cell * scale
        let fontSize = max(10, step * 0.32)
        let margin = (fontSize * 2.2).rounded(.up)
        let outWidth = Int(Double(image.width) + margin * 2)
        let outHeight = Int(Double(image.height) + margin * 2)
        guard
            let context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ScreenshotError.decodeFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.draw(
            image, in: CGRect(x: margin, y: margin, width: Double(image.width), height: Double(image.height)))
        // Flip so we draw top-down (CoreGraphics' origin is bottom-left).
        context.translateBy(x: 0, y: CGFloat(outHeight))
        context.scaleBy(x: 1, y: -1)

        let left = margin, top = margin
        let right = margin + Double(image.width), bottom = margin + Double(image.height)
        func line(_ from: CGPoint, _ to: CGPoint, bold: Bool) {
            context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.6, alpha: bold ? 0.9 : 0.45))
            context.setLineWidth(max(1, step / (bold ? 25 : 60)))
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        }
        for column in 0...columns {
            let x = min(left + Double(column) * step, right)
            line(CGPoint(x: x, y: top), CGPoint(x: x, y: bottom), bold: column % 5 == 0)
        }
        for row in 0...rows {
            let y = min(top + Double(row) * step, bottom)
            line(CGPoint(x: left, y: y), CGPoint(x: right, y: y), bold: row % 5 == 0)
        }

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.7, green: 0, blue: 0.35, alpha: 1),
        ]
        /// Writes text centered on `center`.
        func label(_ text: String, at center: CGPoint) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetImageBounds(line, context)
            context.saveGState()
            // Text renders upside down in the flipped coordinate system, so flip back just for it.
            context.translateBy(x: center.x - bounds.width / 2, y: center.y + fontSize * 0.35)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        // The last cell may be narrower, clipped at the screen edge. Put its name at the clipped cell's center.
        for column in 0..<columns {
            let start = left + Double(column) * step
            let x = (start + min(start + step, right)) / 2
            label(Self.columnName(column), at: CGPoint(x: x, y: margin / 2))
            label(Self.columnName(column), at: CGPoint(x: x, y: bottom + margin / 2))
        }
        for row in 0..<rows {
            let start = top + Double(row) * step
            let y = (start + min(start + step, bottom)) / 2
            label(String(row + 1), at: CGPoint(x: margin / 2, y: y))
            label(String(row + 1), at: CGPoint(x: right + margin / 2, y: y))
        }
        guard let result = context.makeImage() else { throw ScreenshotError.decodeFailed }
        return result
    }

    var summary: String {
        "Grid \(columns)x\(rows) cells (A1 ~ \(name(column: columns - 1, row: rows - 1)), one cell \(Int(cell))px)"
    }
}

enum GridError: Error, CustomStringConvertible {
    case badCell(String)
    case outside(String, last: String)

    var description: String {
        switch self {
        case .badCell(let text):
            return "\(text) is not a cell name. Pass a name like C12 as written on the screenshot --grid image."
        case .outside(let text, let last):
            return "\(text) is outside the grid (last cell is \(last)). Check that --grid-size matches the one used for screenshot."
        }
    }
}
