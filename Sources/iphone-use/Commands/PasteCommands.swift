import ArgumentParser
import Foundation

/// Pastes arbitrary text.
///
/// Puts it on the clipboard and sends ⌘V. `text` can only type characters the device keyboard layout
/// accepts (PITFALLS #11), so other characters and emoji need this command. But the device shows a
/// permission prompt on every paste (PITFALLS #30) — without a human nearby it gets stuck, so try `text` first.
struct PasteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Put text on the clipboard and paste it (for characters not on the keyboard; the device shows a permission prompt).",
        discussion: """
            Overwrites the device clipboard. If you need the original contents, save them with `clipboard` first.
            Pasting needs a cursor in a field — tap it with `touch` first.
            """
    )

    @OptionGroup var device: DeviceOptions

    @OptionGroup var shot: ShotOptions

    @Argument(help: "Text to paste.")
    var text: String?

    @Option(
        name: .long,
        help: "Use this file's contents (UTF-8) instead of text. For restoring a clipboard backup.")
    var file: String?

    @Flag(name: .long, help: "Only set the clipboard; don't send ⌘V.")
    var clipboardOnly = false

    func validate() throws {
        guard (text == nil) != (file == nil) else {
            throw ValidationError("Give exactly one of: text, or --file.")
        }
    }

    func run() throws {
        // Take it from a file so a restored backup doesn't show up on the command line (ps, shell history).
        let text = try file.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? self.text ?? ""

        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        try PasteboardService(rsd: rsd).writeText(text)

        if clipboardOnly {
            print("Clipboard set, \(text.count) chars")
            return
        }

        let hid = try SessionPool.hid(udid: device.udid, rsd: rsd)
        // ⌘V. Give the device a moment to pick up the clipboard.
        Thread.sleep(forTimeInterval: 0.2)
        do {
            try hid.typeKey(0x19, modifiers: [0xE3])
        } catch {
            SessionPool.release(hid)
            throw error
        }
        SessionPool.release(hid)
        print("Pasted \(text.count) chars — the device may have shown a paste permission prompt. Don't allow it on the user's behalf.")
        try shot.capture(after: nil, udid: device.udid)
    }
}

/// Reads the device clipboard.
struct ClipboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read text from the device clipboard."
    )

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .shortAndLong,
        help: "Write to this file instead of stdout (no trailing newline). For backups.")
    var output: String?

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        let text = try PasteboardService(rsd: rsd).readText()
        guard let output else {
            print(text)
            return
        }
        // print appends a newline, so restoring from it would differ from the original. The file gets it verbatim.
        try Data(text.utf8).write(to: URL(fileURLWithPath: output))
        print("\(output) (\(text.count) chars)")
    }
}
