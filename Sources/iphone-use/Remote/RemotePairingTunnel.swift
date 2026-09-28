import Foundation
import XPC

/// Reaches the device's RSD by piggybacking on macOS's own `remoted` tunnel.
///
/// Building a tunnel ourselves (kernel utun) needs root. Instead, placing an assertion with the pairing
/// daemon in the base OS, `com.apple.CoreDevice.remotepairingd`, saying "I'll use the already-open
/// tunnel" just hands us the tunnel IP. No root, entitlements, or Xcode needed, and since `remoted`
/// keeps running, it coexists with Xcode/devicectl.
///
/// The assertion is valid only while this object lives — releasing it may close the tunnel, so hold
/// it until the work is done.
final class RemotePairingTunnel {
    private static let machService = "com.apple.CoreDevice.remotepairingd"
    /// "Already paired" — the normal path.
    private static let alreadyPairedCode: Int64 = 1002
    private static let replyTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "iphone-use.remotepairing")
    private var browseConnection: xpc_connection_t?
    private var deviceConnection: xpc_connection_t?
    private var assertionID: xpc_object_t?

    /// The device's IP address inside the tunnel.
    let tunnelIP: String

    enum Failure: Error, CustomStringConvertible {
        case deviceNotFound(String?)
        case pairingFailed(Int64, String)
        case noTunnelAddress
        case timedOut(String)

        var description: String {
            switch self {
            case .deviceNotFound(let udid):
                let hint = udid.map { " (udid \($0))" } ?? ""
                return "remotepairingd could not find the device\(hint). Check the USB connection and trust pairing."
            case .pairingFailed(let code, let message):
                return "pairing failed (\(code)): \(message)"
            case .noTunnelAddress:
                return "CreateAssertion did not return a tunnelIPAddress."
            case .timedOut(let what):
                return "no reply from remotepairingd: \(what)"
            }
        }
    }

    init(udid: String?) throws {
        let udid = try DeviceResolver.udid(for: udid)
        let endpoint = try Self.browse(udid: udid, queue: queue, keeping: &browseConnection)

        let device = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_event_handler(device) { _ in }
        xpc_connection_activate(device)
        deviceConnection = device

        try Self.ensurePaired(device, queue: queue)
        (tunnelIP, assertionID) = try Self.createAssertion(device, queue: queue)
    }

    deinit { release() }

    /// Releases the assertion and closes the connections.
    func release() {
        if let device = deviceConnection, let assertion = assertionID {
            _ = try? Self.request(
                device, queue: queue, type: "RemotePairing.ReleaseAssertionRequest"
            ) { body in
                xpc_dictionary_set_value(body, "assertionIdentifier", assertion)
            }
            assertionID = nil
        }
        for connection in [deviceConnection, browseConnection] {
            if let connection { xpc_connection_cancel(connection) }
        }
        deviceConnection = nil
        browseConnection = nil
    }

    // MARK: - Steps

    /// Sends `RemotePairing.BrowseRequest` and receives per-device XPC endpoints.
    ///
    /// The device list flows in **through the connection's event handler, not the reply**. Without a
    /// reply channel attached the daemon just drops the request, so send it reply-style even if the reply is unused.
    private static func browse(
        udid: String?, queue: DispatchQueue, keeping connection: inout xpc_connection_t?
    ) throws -> xpc_object_t {
        let browse = xpc_connection_create_mach_service(machService, queue, 0)
        connection = browse

        let found = DispatchSemaphore(value: 0)
        let box = EndpointBox()

        xpc_connection_set_event_handler(browse) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
                let value = xpc_dictionary_get_value(event, "value"),
                let deviceFound = xpc_dictionary_get_value(value, "deviceFound"),
                let zero = xpc_dictionary_get_value(deviceFound, "_0"),
                let info = xpc_dictionary_get_value(zero, "deviceInfo")
            else { return }

            if let want = udid {
                guard let raw = xpc_dictionary_get_string(info, "udid"),
                    String(cString: raw).caseInsensitiveCompare(want) == .orderedSame
                else { return }
            }
            guard let endpoint = xpc_dictionary_get_value(info, "endpoint") else { return }
            if box.store(endpoint) { found.signal() }
        }
        xpc_connection_activate(browse)

        let message = xpc_dictionary_create(nil, nil, 0)
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(body, "currentDevicesOnly", false)
        xpc_dictionary_set_string(message, "mangledTypeName", "RemotePairing.BrowseRequest")
        xpc_dictionary_set_value(message, "value", body)
        xpc_connection_send_message_with_reply(browse, message, queue) { _ in }

        guard found.wait(timeout: .now() + replyTimeout) == .success, let endpoint = box.value else {
            throw Failure.deviceNotFound(udid)
        }
        return endpoint
    }

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

    /// Already paired comes back as code 1002 — that's normal.
    private static func ensurePaired(_ device: xpc_connection_t, queue: DispatchQueue) throws {
        let reply = try request(device, queue: queue, type: "RemotePairing.InitiatePairingCommand") {
            body in
            xpc_dictionary_set_bool(body, "requireNonInteractive", false)
        }
        guard let error = xpc_dictionary_get_value(reply, "error") else { return }

        // Messages are localized, so judge by the numeric code only.
        let code = xpc_dictionary_get_int64(error, "code")
        guard code != alreadyPairedCode else { return }

        var message = "unknown error"
        if let userInfo = xpc_dictionary_get_value(error, "userInfo"),
            let raw = xpc_dictionary_get_string(userInfo, "NSLocalizedDescription")
        {
            message = String(cString: raw)
        }
        throw Failure.pairingFailed(code, message)
    }

    private static func createAssertion(_ device: xpc_connection_t, queue: DispatchQueue) throws -> (
        String, xpc_object_t?
    ) {
        let reply = try request(device, queue: queue, type: "RemotePairing.CreateAssertionCommand") {
            body in
            xpc_dictionary_set_int64(body, "flags", 0)
        }
        guard let response = xpc_dictionary_get_value(reply, "response"),
            let info = xpc_dictionary_get_value(response, "info"),
            let raw = xpc_dictionary_get_string(info, "tunnelIPAddress")
        else {
            throw Failure.noTunnelAddress
        }
        return (String(cString: raw), xpc_dictionary_get_value(response, "assertionIdentifier"))
    }

    /// Sends `{mangledTypeName, value}` and waits for the reply.
    private static func request(
        _ connection: xpc_connection_t,
        queue: DispatchQueue,
        type: String,
        body configure: (xpc_object_t) -> Void
    ) throws -> xpc_object_t {
        let body = xpc_dictionary_create(nil, nil, 0)
        configure(body)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "mangledTypeName", type)
        xpc_dictionary_set_value(message, "value", body)

        let done = DispatchSemaphore(value: 0)
        let box = EndpointBox()
        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            _ = box.store(reply)
            done.signal()
        }
        guard done.wait(timeout: .now() + replyTimeout) == .success, let reply = box.value else {
            throw Failure.timedOut(type)
        }
        return reply
    }
}

/// A box for passing one object between an XPC callback (from another queue) and the calling thread.
private final class EndpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: xpc_object_t?

    /// Fills only the first time. Returns true if it filled.
    func store(_ object: xpc_object_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return false }
        stored = object
        return true
    }

    var value: xpc_object_t? {
        lock.lock()
        defer { lock.unlock() }
        return stored
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
