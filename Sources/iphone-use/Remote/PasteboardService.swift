import Foundation

/// Device clipboard.
///
/// `com.apple.coredevice.pasteboardservice` **doesn't use the CoreDevice envelope** — it exchanges
/// raw `{command: "PULL"|"PUSH", ...}` messages. Wrap it in the envelope and it's rejected with
/// "Message missing command field".
///
/// This is what makes Hangul input possible. The HID keyboard sends ASCII usages, so characters
/// get transformed on their way through the device's IME.
///
/// A new connection is opened per request. The device closes the connection after handling a PUSH,
/// so one can't be held and reused.
struct PasteboardService {
    let rsd: RemoteServiceDiscovery

    /// Name of the system's general clipboard. iOS uses the same name as macOS.
    static let general = "general"

    private static let utf8Text = "public.utf8-plain-text"
    private static let serviceName = "com.apple.coredevice.pasteboardservice"

    enum Failure: Error, CustomStringConvertible {
        case unexpectedReply(String)
        case notText
        case pushIgnored

        var description: String {
            switch self {
            case .unexpectedReply(let detail): return "unexpected clipboard reply: \(detail)"
            case .notText: return "The device clipboard has no UTF-8 text."
            case .pushIgnored: return "What was written to the clipboard did not take effect on the device."
            }
        }
    }

    /// Overwrites the clipboard with a single text item and reads it back to confirm.
    ///
    /// PUSH gets no reply. If the socket disappears right after sending, it's lost before the device
    /// reads it, so only a confirming PULL lets us say it was "written".
    func writeText(_ text: String, pasteboard: String = general, attempts: Int = 4) throws {
        for attempt in 1...attempts {
            try push(text, pasteboard: pasteboard)
            if (try? readText(pasteboard: pasteboard)) == text { return }
            if attempt < attempts { Thread.sleep(forTimeInterval: 0.2) }
        }
        throw Failure.pushIgnored
    }

    /// Reads the clipboard's UTF-8 text.
    func readText(pasteboard: String = general) throws -> String {
        let connection = try rsd.connect(to: Self.serviceName)
        defer { connection.close() }

        let reply = try connection.sendReceive([
            "command": .string("PULL"),
            "pasteboardName": .string(pasteboard),
            // Policy: don't defer with promises, attach all the bytes.
            "dataPolicy": .dictionary(["allResolved": .dictionary([:])]),
        ])

        guard let snapshot = reply["pasteboard"]?.dictionaryValue,
            let items = snapshot["items"]?.arrayValue
        else {
            throw Failure.unexpectedReply("\(reply.mapValues { $0.jsonSummary })")
        }

        for item in items {
            guard let entry = item.dictionaryValue?["data"]?.dictionaryValue,
                let payload = entry[Self.utf8Text]?.dictionaryValue?["data"],
                case .data(let bytes) = payload
            else { continue }
            return String(decoding: bytes, as: UTF8.self)
        }
        throw Failure.notText
    }

    private func push(_ text: String, pasteboard: String) throws {
        let connection = try rsd.connect(to: Self.serviceName)
        defer { connection.close() }

        let item = XPCObject.dictionary([
            "types": .array([.string(Self.utf8Text)]),
            "data": .dictionary([Self.utf8Text: .dictionary(["data": .data(Data(text.utf8))])]),
        ])
        try connection.sendRequest([
            "command": .string("PUSH"),
            "pasteboardName": .string(pasteboard),
            "pasteboard": .dictionary([
                "items": .array([item]),
                "metadata": .dictionary([
                    "changeCount": .int64(0),
                    "nonce": .string(UUID().uuidString),
                    "pasteboardName": .string(pasteboard),
                ]),
            ]),
        ])
        // Closing the socket before the device reads the message silently loses it. Give it time to read.
        Thread.sleep(forTimeInterval: 0.15)
    }
}
