import ArgumentParser
import Foundation

/// Reads one attribute value of an element.
///
/// The token (the `platform_id` that `tree` prints) is an object address inside the app process plus the
/// pid, so it dies when the screen changes. This command is also used to check that lifetime.
struct AttrCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attr",
        abstract: "Read one attribute value by element token."
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "Element token (hex).")
    var element: String

    @Option(name: .long, help: "Attribute name.")
    var name: String = "Label"

    func run() throws {
        guard let token = Data(hex: element) else {
            throw ValidationError("Token is not hex: \(element)")
        }
        try AXSession.with(udid: device.udid) { session in
            session.resetAuditTarget()
            let value = try session.value(of: token, attribute: name)
            let payload: [String: Any] = ["ref": element, "name": name,
                                          "value": AXWire.jsonReady(value)]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

extension Data {
    init?(hex: String) {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
