import Foundation
import XPC

/// Lists the devices macOS's pairing daemon (`com.apple.CoreDevice.remotepairingd`) can reach.
///
/// This only browses. It used to also take a tunnel assertion and hand out the tunnel IP so we could
/// talk to the device's RSD directly, but that displaced `remoted` (PITFALLS #44). Service connections
/// now come from CoreDeviceService (`CoreDeviceClient`).
enum RemotePairing {
    private static let machService = "com.apple.CoreDevice.remotepairingd"

    /// Collects `deviceInfo` for devices remotepairingd knows (both USB and Wi-Fi).
    ///
    /// There's no end-of-list signal, so no more events for `settle` counts as the end.
    /// With `currentDevicesOnly` on, only currently reachable devices come (off: every device ever paired).
    static func devices(settle: TimeInterval = 0.4, timeout: TimeInterval = 3) -> [[String: Any]] {
        let queue = DispatchQueue(label: "iphone-use.remotepairing.list")
        let browse = xpc_connection_create_mach_service(machService, queue, 0)
        defer { xpc_connection_cancel(browse) }

        let collector = DeviceCollector()
        xpc_connection_set_event_handler(browse) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
                let value = xpc_dictionary_get_value(event, "value"),
                let deviceFound = xpc_dictionary_get_value(value, "deviceFound"),
                let zero = xpc_dictionary_get_value(deviceFound, "_0"),
                let info = xpc_dictionary_get_value(zero, "deviceInfo")
            else { return }
            collector.add(XPCPlain.convert(info) as? [String: Any] ?? [:])
        }
        xpc_connection_activate(browse)

        let message = xpc_dictionary_create(nil, nil, 0)
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(body, "currentDevicesOnly", true)
        xpc_dictionary_set_string(message, "mangledTypeName", "RemotePairing.BrowseRequest")
        xpc_dictionary_set_value(message, "value", body)
        xpc_connection_send_message_with_reply(browse, message, queue) { _ in }

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            Thread.sleep(forTimeInterval: 0.1)
            let (count, quiet) = collector.status()
            if count > 0 && quiet >= settle { break }
        }
        return collector.snapshot()
    }
}

/// Collected in the event handler (another queue), read by the caller.
private final class DeviceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [[String: Any]] = []
    private var last = Date()

    func add(_ info: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        found.append(info)
        last = Date()
    }

    /// (count collected, time since the last arrival)
    func status() -> (Int, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (found.count, Date().timeIntervalSince(last))
    }

    func snapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}

/// libxpc object -> Foundation value. Things that can't be carried over, like endpoints, are dropped.
enum XPCPlain {
    static func convert(_ object: xpc_object_t) -> Any? {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_DICTIONARY:
            var result: [String: Any] = [:]
            xpc_dictionary_apply(object) { key, value in
                if let converted = convert(value) { result[String(cString: key)] = converted }
                return true
            }
            return result
        case XPC_TYPE_ARRAY:
            var result: [Any] = []
            xpc_array_apply(object) { _, value in
                if let converted = convert(value) { result.append(converted) }
                return true
            }
            return result
        case XPC_TYPE_STRING: return String(cString: xpc_string_get_string_ptr(object)!)
        case XPC_TYPE_BOOL: return xpc_bool_get_value(object)
        case XPC_TYPE_INT64: return xpc_int64_get_value(object)
        case XPC_TYPE_UINT64: return xpc_uint64_get_value(object)
        case XPC_TYPE_DOUBLE: return xpc_double_get_value(object)
        case XPC_TYPE_UUID:
            return NSUUID(uuidBytes: xpc_uuid_get_bytes(object)).uuidString
        default: return nil
        }
    }
}
