import ArgumentParser
import Foundation

/// Diagnostic command for poking CoreDevice features directly.
///
/// The services a device advertises come from `hid-info`; feature names are embedded as strings in the
/// host's `CoreDeviceUtilities.framework` binary:
/// `strings -a .../CoreDeviceUtilities | grep coredevice.feature.`
struct InvokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invoke",
        abstract: "Invoke a CoreDevice feature directly (for reverse engineering).",
        discussion: """
            Input is JSON. Strings, integers, doubles, booleans, arrays and objects map directly;
            `{"$data": "<hex>"}` becomes bytes and `{"$uint": 3}` becomes uint64.
            """
    )

    @OptionGroup var device: DeviceOptions

    @Argument(help: "Service name (e.g. com.apple.coredevice.screencaptureservice).")
    var service: String

    @Argument(help: "Feature name (e.g. com.apple.coredevice.feature.capturescreenshot).")
    var feature: String = ""

    @Flag(
        name: .long,
        help: "Send the input JSON as the message as-is, without the CoreDevice envelope.")
    var noEnvelope = false

    @Option(name: .long, help: "Action name (e.g. com.apple.coredevice.action.getuserinterfacestyle).")
    var action: String?

    @Option(name: .long, help: "Input JSON.")
    var input: String = "{}"

    @Option(name: .long, help: "Write the largest byte blob in the response to this path.")
    var dumpData: String?

    @Option(name: .long, help: "Response timeout (seconds).")
    var timeout: Double = 20

    func run() throws {
        let json = try JSONSerialization.jsonObject(
            with: Data(input.utf8), options: [.fragmentsAllowed])
        guard let payload = XPCObject(json: json)?.dictionaryValue else {
            throw ValidationError("Input JSON is not an object.")
        }

        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        let connection = try rsd.connect(to: service)
        defer { connection.close() }

        let output: XPCObject
        if noEnvelope {
            output = .dictionary(try connection.sendReceive(payload, timeout: timeout))
        } else {
            guard !feature.isEmpty else { throw ValidationError("A feature name is required.") }
            output = try CoreDeviceService(connection: connection)
                .invokeRaw(feature, action: action, input: payload, timeout: timeout)
        }

        if let dumpData {
            guard let blob = output.largestData else {
                throw ValidationError("The response has no byte blob.")
            }
            try blob.write(to: URL(fileURLWithPath: dumpData))
            FileHandle.standardError.write(Data("\(dumpData) (\(blob.count) bytes)\n".utf8))
        }

        let summary = output.jsonSummary
        let data = try JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

extension XPCObject {
    /// JSON value -> XPC. Large byte blobs such as images are given as `{"$data": "<hex>"}`.
    init?(json: Any) {
        switch json {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // NSNumber wraps booleans and integers in the same class, so tell them apart by the type encoding.
            switch String(cString: number.objCType) {
            case "c", "B": self = .bool(number.boolValue)
            case "d", "f": self = .double(number.doubleValue)
            default: self = .int64(number.int64Value)
            }
        case let items as [Any]:
            self = .array(items.compactMap { XPCObject(json: $0) })
        case let entries as [String: Any]:
            if let hex = entries["$data"] as? String, entries.count == 1 {
                guard let bytes = Data(hex: hex) else { return nil }
                self = .data(bytes)
            } else if let value = entries["$uint"] as? NSNumber, entries.count == 1 {
                self = .uint64(value.uint64Value)
            } else if let value = entries["$uuid"] as? String, entries.count == 1 {
                guard let uuid = UUID(uuidString: value) else { return nil }
                self = .uuid(uuid)
            } else {
                self = .dictionary(entries.compactMapValues { XPCObject(json: $0) })
            }
        case is NSNull:
            self = .null
        default:
            return nil
        }
    }

    /// The largest byte blob in the tree. For pulling out values like images whose location is unknown.
    var largestData: Data? {
        switch self {
        case .data(let value): return value
        case .array(let items): return items.compactMap { $0.largestData }.max { $0.count < $1.count }
        case .dictionary(let entries):
            return entries.values.compactMap { $0.largestData }.max { $0.count < $1.count }
        default: return nil
        }
    }

    /// Like `jsonReady`, but long byte blobs keep only their size instead of hex.
    var jsonSummary: Any {
        switch self {
        case .data(let value):
            return value.count > 64
                ? "<\(value.count) bytes>"
                : value.map { String(format: "%02X", $0) }.joined()
        case .array(let items): return items.map { $0.jsonSummary }
        case .dictionary(let entries): return entries.mapValues { $0.jsonSummary }
        default: return jsonReady
        }
    }
}
