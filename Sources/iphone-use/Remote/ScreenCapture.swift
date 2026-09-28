import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screen capture. `com.apple.coredevice.screencaptureservice` — the same path Device Hub uses.
///
/// It doesn't open an accessibility session, so it doesn't collide with Accessibility Inspector, and
/// unlike `scan` it doesn't touch the screen. The device's original is a 16-bit PNG over 10MB (PITFALLS #13).
enum ScreenCapture {
    /// The PNG bytes exactly as the device sent them.
    static func png(rsd: RemoteServiceDiscovery) throws -> Data {
        let connection = try rsd.connect(to: "com.apple.coredevice.screencaptureservice")
        defer { connection.close() }

        let output = try CoreDeviceService(connection: connection)
            .invoke(
                "com.apple.coredevice.feature.capturescreenshot",
                input: ["requestedFormat": .string("png")], timeout: 30)

        guard let original = XPCObject.dictionary(output).largestData else {
            throw ScreenshotError.noImage(String(describing: output.mapValues { $0.jsonSummary }))
        }
        return original
    }

    /// Decoded image. Pixel coordinates are `touch` coordinates.
    static func image(rsd: RemoteServiceDiscovery) throws -> CGImage {
        try decode(png(rsd: rsd))
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ScreenshotError.decodeFailed
        }
        return image
    }

    /// Re-encodes at 8 bits and shrinks if needed. The returned note is one line to show the user.
    static func encode(
        _ decoded: CGImage, as type: UTType = .png, quality: Double = 0.8, maxWidth: Int? = nil
    ) throws -> (Data, String?) {
        var image = decoded
        var note: String?
        if let maxWidth, decoded.width > maxWidth {
            let scale = Double(maxWidth) / Double(decoded.width)
            let height = Int((Double(decoded.height) * scale).rounded())
            image = try resize(decoded, width: maxWidth, height: height)
            // The docs say "don't multiply, use --image-width", but this used to say multiply, and agents got confused about which.
            note = "\(decoded.width)x\(decoded.height) -> \(maxWidth)x\(height) — pass coordinates read from this image as `touch X Y --image-width \(maxWidth)`"
        }

        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer, type.identifier as CFString, 1, nil)
        else {
            throw ScreenshotError.decodeFailed
        }
        // Squeeze the 16-bit input into 8 bits. Screen captures have precision to spare.
        let options: [CFString: Any] = [
            kCGImagePropertyDepth: 8,
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.decodeFailed }
        return (buffer as Data, note)
    }

    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ScreenshotError.decodeFailed }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw ScreenshotError.decodeFailed }
        return resized
    }

    // MARK: - Screen state

    /// Notice for when the screen is off. The capture succeeds with a pitch-black image, so it must be called out.
    static let darkNotice =
        "The screen is off (black image). Wake it with `button home`; if it's the lock screen, ask the user to unlock it."

    /// Is it nearly black? With the screen off the device returns a black image with no error — filter
    /// that out first so nobody taps coordinates or wonders why OCR came back empty.
    static func isDark(_ image: CGImage) -> Bool {
        guard let pixels = try? signature(of: image, skipStatusBar: false) else { return false }
        return pixels.allSatisfy { $0 < 12 }
    }

    /// A rect for output, as "(left,top widthxheight)".
    static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    /// What `settled` saw.
    struct Settle {
        let image: CGImage
        /// True if it settled. A screen where only one area keeps moving (`moving`) is also true if the rest settled.
        let stable: Bool
        /// Pixel rect of the area that kept changing after settling (video background, spinner, etc.). nil if none.
        let moving: CGRect?
    }

    /// Repeats captures until the screen settles. Returns that screen, or the last one if it never settles in time.
    ///
    /// Two consecutive identical captures count as settled. One capture takes over 0.3 s, so movement
    /// in between is nearly always caught.
    ///
    /// A screen where only one area keeps changing also counts as settled — if three consecutive changes
    /// are all confined to the same rect within a third of the screen. The Music app's artist page loops a
    /// video at the top (about a quarter of the screen), so `--shot` waited the full 6 s every time and tagged
    /// "still moving", and `wait --stable` failed outright with a timeout. Screen transitions change almost everything, so they don't match this.
    static func settled(rsd: RemoteServiceDiscovery, timeout: TimeInterval) throws -> Settle {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [UInt8]?
        var recent: [[Bool]] = []
        while true {
            let image = try self.image(rsd: rsd)
            let current = try signature(of: image)
            if let previous {
                let diff = changedCells(previous, current)
                if diff.filter({ $0 }).count <= diff.count / 400 {
                    return Settle(image: image, stable: true, moving: nil)
                }
                recent = Array((recent + [diff]).suffix(3))
                if recent.count == 3,
                    let box = cellBox(recent.reduce([Bool](repeating: false, count: diff.count)) {
                        zip($0, $1).map { $0 || $1 }
                    }),
                    box.width * box.height * 3 <= CGFloat(signatureWidth * signatureHeight)
                {
                    return Settle(image: image, stable: true, moving: pixelRect(box, in: image))
                }
            }
            if Date() >= deadline { return Settle(image: image, stable: false, moving: nil) }
            previous = current
        }
    }

    /// Are the before and after screens effectively the same? `ignoring` (area that kept moving, pixels) is excluded.
    ///
    /// Tapping somewhere that **doesn't respond**, like a list's title text, leaves the screen unchanged. The
    /// album titles in the Music app's "New Releases" were like that (only the cover responds). From the `--shot`
    /// screen alone the agent barely noticed, tapped twice, then fell back to guessing coordinates. Video changes
    /// different cells every frame, so the whole rect is excluded, not cells.
    /// With `within` (pixels), only that area is examined.
    static func unchanged(
        _ before: CGImage, _ after: CGImage, ignoring: CGRect?, within: CGRect? = nil
    ) throws -> Bool {
        let diff = changedCells(try signature(of: before), try signature(of: after))
        let statusBar = CGFloat(after.height * 6 / 100)
        let cellWidth = CGFloat(after.width) / CGFloat(signatureWidth)
        let cellHeight = (CGFloat(after.height) - statusBar) / CGFloat(signatureHeight)
        let count = diff.indices.filter { index in
            guard diff[index] else { return false }
            let x = CGFloat(index % signatureWidth) + 0.5
            let y = CGFloat(index / signatureWidth) + 0.5
            let point = CGPoint(x: x * cellWidth, y: statusBar + y * cellHeight)
            if let within, !within.contains(point) { return false }
            return !(ignoring?.contains(point) ?? false)
        }.count
        return count <= 2
    }

    /// Does `rect` (pixels) look the same in both frames? Compared at 1/8 size in grayscale; up to 4% of
    /// it may differ (a blinking cursor, a badge), while a list that moved by a row changed about 17%. `unchanged` works on a coarse
    /// grid and only around the element, and a chat list scrolled by a row and a half still passed it:
    /// neighboring rows look alike at that resolution (PITFALLS #42).
    static func sameArea(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Bool {
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height)).integral
        guard !bounds.isEmpty, a.width == b.width, a.height == b.height,
            let pixelsA = gray(a, bounds), let pixelsB = gray(b, bounds)
        else { return false }
        let changed = zip(pixelsA, pixelsB).filter { abs(Int($0) - Int($1)) > 32 }.count
        return changed * 25 <= pixelsA.count
    }

    private static func gray(_ image: CGImage, _ rect: CGRect) -> [UInt8]? {
        let width = max(1, Int(rect.width) / 8)
        let height = max(1, Int(rect.height) / 8)
        guard let cropped = image.cropping(to: rect),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    /// `signature` grid size. Fitted to the iPhone's portrait ratio (still enough for comparing on iPad landscape).
    private static let signatureWidth = 48
    private static let signatureHeight = 104

    /// Cells whose brightness changed by more than a cursor blink.
    private static func changedCells(_ a: [UInt8], _ b: [UInt8]) -> [Bool] {
        zip(a, b).map { abs(Int($0) - Int($1)) > 24 }
    }

    /// Grid rect enclosing the changed cells.
    private static func cellBox(_ cells: [Bool]) -> CGRect? {
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for (index, on) in cells.enumerated() where on {
            let (x, y) = (index % signatureWidth, index / signatureWidth)
            (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Grid rect -> screenshot pixel rect (relative to the area below the status bar).
    private static func pixelRect(_ box: CGRect, in image: CGImage) -> CGRect {
        let statusBar = CGFloat(image.height * 6 / 100)
        let cellWidth = CGFloat(image.width) / CGFloat(signatureWidth)
        let cellHeight = (CGFloat(image.height) - statusBar) / CGFloat(signatureHeight)
        return CGRect(
            x: box.minX * cellWidth, y: statusBar + box.minY * cellHeight,
            width: box.width * cellWidth, height: box.height * cellHeight
        ).integral
    }

    /// Small grayscale pixels for comparison.
    ///
    /// The status bar is excluded — the clock, signal strength and recording indicator change constantly, so with it the screen would never settle.
    static func signature(of image: CGImage, skipStatusBar: Bool = true) throws -> [UInt8] {
        let width = signatureWidth
        let height = signatureHeight
        let statusBar = skipStatusBar ? image.height * 6 / 100 : 0
        guard
            let cropped = image.cropping(
                to: CGRect(x: 0, y: statusBar, width: image.width, height: image.height - statusBar)),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw ScreenshotError.decodeFailed }

        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ScreenshotError.decodeFailed }
        return Array(
            UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    /// Differences on the order of a cursor blink count as the same screen.
    static func similar(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
        return changed <= a.count / 400
    }
}
