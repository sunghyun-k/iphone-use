import ArgumentParser
import CoreGraphics
import Foundation

/// Shared helpers built on screen capture.
///
/// Commands that located targets by text (`find`, `tap "text"`, `wait "text"`) were removed. OCR accuracy
/// varies by language and they often tapped the wrong place. Targets are pointed at by ref in the
/// accessibility list (`ui`). OCR is now used only to see whether the on-screen keyboard is up
/// (`TextRecognizer.keyboardVisible`) — it never picks targets.
enum ScreenText {
    enum Failure: Error, CustomStringConvertible {
        case timeout(String)
        case screenOff

        var description: String {
            switch self {
            case .screenOff: return ScreenCapture.darkNotice
            case .timeout(let what): return "Timed out: \(what)"
            }
        }
    }

    /// A lit screen. If it's off, the keyboard check wrongly says "none", so report the real reason right away.
    static func litImage(rsd: RemoteServiceDiscovery) throws -> CGImage {
        let image = try ScreenCapture.image(rsd: rsd)
        guard !ScreenCapture.isDark(image) else { throw Failure.screenOff }
        return image
    }
}

/// Waits for the screen to settle.
struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for the screen to settle (animations, loading done).",
        discussion: """
            iphone-use wait --stable -o s.png   # until the screen settles, saving the last frame
            """
    )

    @OptionGroup var device: DeviceOptions

    @Flag(name: .long, help: "Wait until the screen stops changing. Currently the only mode.")
    var stable = false

    @Option(name: .long, help: "Max wait (seconds). Fails when exceeded.")
    var timeout: Double = 10

    @Option(name: .shortAndLong, help: "Save the settled screen as PNG to this path.")
    var output: String?

    @Option(name: .long, help: "When saving, downscale if wider than this.")
    var maxWidth: Int?

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        let start = Date()
        let settle = try ScreenCapture.settled(rsd: rsd, timeout: timeout)
        let frame = settle.image
        // Keep the last frame even on timeout, so on a constantly moving screen the agent doesn't come
        // away empty-handed and call `screenshot` again.
        if !settle.stable {
            let saved = try output.map { try save(frame, to: $0) } ?? ""
            throw ScreenText.Failure.timeout("the screen did not settle\(saved)")
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        let note = settle.moving.map { ", \(ScreenCapture.describe($0)) keeps moving (video etc.)" } ?? ""
        print("Screen settled (\(elapsed)s\(note))")

        if let output {
            let (data, note) = try ScreenCapture.encode(frame, maxWidth: maxWidth)
            try data.write(to: URL(fileURLWithPath: output))
            print("\(output) (\(data.count) bytes)")
            if let note { print(note) }
        }
    }

    /// On timeout, saves the last frame and returns the hint to append to the error message.
    private func save(_ frame: CGImage, to path: String) throws -> String {
        let (data, _) = try ScreenCapture.encode(frame, maxWidth: maxWidth)
        try data.write(to: URL(fileURLWithPath: path))
        return ". Saved the last frame to \(path) — judge from that"
    }
}
