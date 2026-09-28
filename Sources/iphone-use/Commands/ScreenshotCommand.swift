import ArgumentParser
import Foundation
import UniformTypeIdentifiers

/// Captures one frame of the screen (`ScreenCapture`).
///
/// The device's original is a **16-bit PNG over 10 MB**. Too big for an agent to read as-is, so by
/// default it's re-encoded to 8-bit.
struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture the screen and save it to a file."
    )

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case png, jpeg

        var contentType: UTType { self == .png ? .png : .jpeg }
    }

    @OptionGroup var device: DeviceOptions

    @Option(name: .shortAndLong, help: "Output path. If omitted, bytes go to stdout.")
    var output: String?

    @Option(name: .long, help: "Format: png, jpeg.")
    var format: Format = .png

    @Option(name: .long, help: "JPEG quality (0-1).")
    var quality: Double = 0.8

    @Option(
        name: .long,
        help: "Downscale if wider than this. Note that coordinates shrink by the same ratio.")
    var maxWidth: Int?

    @Flag(name: .long, help: "Write the device's original bytes as-is (16-bit PNG, 10 MB+).")
    var raw = false

    @Flag(name: .long, help: "Draw a grid with each cell named (A1, C12, ...). To tap one: touch --cell C12.")
    var grid = false

    @Option(name: .long, help: "Grid: how many cells along the screen's short side. Pass the same value to touch --cell.")
    var gridSize = ScreenGrid.defaultDensity

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        let original = try ScreenCapture.png(rsd: rsd)
        let decoded = try ScreenCapture.decode(original)
        if grid {
            // Draw after downscaling — drawing on the original and then shrinking smears the cell labels.
            var base = decoded
            if let maxWidth, decoded.width > maxWidth {
                let height = Int((Double(decoded.height) * Double(maxWidth) / Double(decoded.width)).rounded())
                base = try ScreenCapture.resize(decoded, width: maxWidth, height: height)
            }
            let layout = ScreenGrid(
                width: Double(decoded.width), height: Double(decoded.height), density: gridSize)
            let (image, _) = try ScreenCapture.encode(
                try layout.draw(on: base), as: format.contentType, quality: quality)
            let size = gridSize == ScreenGrid.defaultDensity ? "" : " --grid-size \(gridSize)"
            try emit(image, note: "\(layout.summary) — to tap a cell's center: touch --cell C12\(size)")
        } else {
            let (image, note) =
                raw
                ? (original, nil)
                : try ScreenCapture.encode(
                    decoded, as: format.contentType, quality: quality, maxWidth: maxWidth)
            try emit(image, note: note)
        }
        if ScreenCapture.isDark(decoded) {
            FileHandle.standardError.write(Data((ScreenCapture.darkNotice + "\n").utf8))
        }
    }

    private func emit(_ image: Data, note: String?) throws {
        guard let output else {
            FileHandle.standardOutput.write(image)
            return
        }
        try image.write(to: URL(fileURLWithPath: output))
        print("\(output) (\(image.count) bytes)")
        if let note { print(note) }
    }
}

enum ScreenshotError: Error, CustomStringConvertible {
    case noImage(String)
    case decodeFailed

    var description: String {
        switch self {
        case .noImage(let reply):
            return "No image found in the response: \(reply)"
        case .decodeFailed:
            return "Could not re-encode the received PNG. Try `--raw` to get the original."
        }
    }
}
