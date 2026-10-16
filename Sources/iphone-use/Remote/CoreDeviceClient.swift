import Foundation
import XPC

/// Gets device service sockets from the host's `CoreDeviceService`, the same way Xcode and devicectl do.
///
/// We used to handshake with the device's RSD ourselves. The device keeps one RSD peer per tunnel, so that
/// handshake took the connection away from macOS's `remoted`, which then never reconnected. From then on
/// Xcode and xcodebuild hung at "Connecting to <device>" until the cable was replugged (PITFALLS #44).
/// CoreDeviceService already holds the connection through `remoted` and hands out a connected socket per
/// service (`createservicesocket`), so nothing on the host gets displaced.
///
/// No entitlement is needed: devicectl is a plain client of the same XPC service.
/// The usage assertion keeps the tunnel up for as long as this object lives.
final class CoreDeviceClient {
    private static let frameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice"
    private static let serviceName = "com.apple.CoreDevice.CoreDeviceService"
    private static let checkInTimeout: TimeInterval = 10
    private static let actionTimeout: TimeInterval = 20

    enum Failure: Error, CustomStringConvertible {
        case frameworkMissing(String)
        case serviceUnavailable
        case deviceNotFound(String)
        case actionFailed(action: String, message: String)
        case timedOut(String)
        case noSocket(String)

        var description: String {
            switch self {
            case .frameworkMissing(let reason):
                return """
                    could not load CoreDevice.framework (\(reason)). Install Xcode and run \
                    `xcodebuild -runFirstLaunch`.
                    """
            case .serviceUnavailable:
                return "connection to CoreDeviceService was interrupted. Run the command again."
            case .deviceNotFound(let udid):
                return """
                    CoreDevice does not list the device \(udid). Check the USB/Wi-Fi connection and \
                    trust pairing (`xcrun devicectl list devices`).
                    """
            case .actionFailed(let action, let message):
                return "CoreDevice \(action) failed: \(message)"
            case .timedOut(let what):
                return "no reply from CoreDeviceService (\(what)). Check the device connection."
            case .noSocket(let service):
                return "CoreDevice returned no socket for \(service). Check the device connection."
            }
        }
    }

    private let queue = DispatchQueue(label: "iphone-use.coredevice")
    private let connection: xpc_connection_t
    /// CoreDevice's own identifier for the device (not the UDID).
    private let deviceIdentifier: String
    /// The assertion lasts while this listener lives. Cancelling it hands the tunnel back.
    private var assertionListener: xpc_connection_t?

    init(udid: String) throws {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil else {
            throw Failure.frameworkMissing(String(cString: dlerror()))
        }
        // An XPC service embedded in a framework is only found once that framework is loaded (above).
        connection = xpc_connection_create(Self.serviceName, queue)
        deviceIdentifier = try Self.checkIn(connection, udid: udid, queue: queue)
        try acquireUsageAssertion()
    }

    deinit { close() }

    func close() {
        if let listener = assertionListener { xpc_connection_cancel(listener) }
        assertionListener = nil
        xpc_connection_cancel(connection)
    }

    /// A connected socket to one device service. The caller owns (and closes) the descriptor.
    ///
    /// RemoteXPC services still need their HTTP/2 handshake on top (`RemoteXPCConnection`).
    func serviceSocket(_ service: String) throws -> Int32 {
        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "serviceName", service)
        let output = try invoke("com.apple.coredevice.action.createservicesocket", input: input)
        guard let descriptor = xpc_dictionary_get_value(output, "fileDescriptor"),
            xpc_get_type(descriptor) == XPC_TYPE_FD
        else { throw Failure.noSocket(service) }
        let fd = xpc_fd_dup(descriptor)
        guard fd >= 0 else { throw Failure.noSocket(service) }
        return fd
    }

    // MARK: - Steps

    /// Checks in and picks the device whose snapshot carries `udid`.
    ///
    /// The snapshots arrive as an event (wrapped in `CoreDevice.ServiceEvent`), not as the reply.
    private static func checkIn(_ connection: xpc_connection_t, udid: String, queue: DispatchQueue)
        throws -> String
    {
        let found = DispatchSemaphore(value: 0)
        let box = Box<String?>(nil)
        let interrupted = Box(false)

        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
                interrupted.value = true
                found.signal()
                return
            }
            var message = event
            if let value = xpc_dictionary_get_value(event, "value"),
                let request = xpc_dictionary_get_value(value, "request")
            {
                message = request
            }
            guard let type = xpc_dictionary_get_string(message, "mangledTypeName"),
                String(cString: type) == "CoreDevice.DeviceManagerCheckInCompleteEvent",
                let value = xpc_dictionary_get_value(message, "value"),
                let snapshots = xpc_dictionary_get_value(value, "initialDeviceSnapshots")
            else { return }

            xpc_array_apply(snapshots) { _, snapshot in
                guard Self.contains(udid: udid, in: snapshot),
                    let info = xpc_dictionary_get_value(snapshot, "deviceInfo"),
                    let identifier = xpc_dictionary_get_value(info, "identifier"),
                    xpc_get_type(identifier) == XPC_TYPE_UUID,
                    let bytes = xpc_uuid_get_bytes(identifier)
                else { return true }
                box.value = NSUUID(uuidBytes: bytes).uuidString
                return false
            }
            found.signal()
        }
        xpc_connection_activate(connection)

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "mangledTypeName", "CoreDevice.DeviceManagerCheckInRequest")
        let body = xpc_dictionary_create(nil, nil, 0)
        var requestID = UUID().uuid
        withUnsafeBytes(of: &requestID) { raw in
            xpc_dictionary_set_uuid(body, "identifier", raw.bindMemory(to: UInt8.self).baseAddress!)
        }
        xpc_dictionary_set_value(message, "value", body)
        xpc_connection_send_message_with_reply(connection, message, queue) { _ in }

        guard found.wait(timeout: .now() + checkInTimeout) == .success else {
            throw Failure.timedOut("check-in")
        }
        if interrupted.value { throw Failure.serviceUnavailable }
        guard let identifier = box.value else { throw Failure.deviceNotFound(udid) }
        return identifier
    }

    /// Device properties come as `{descriptorIdentifier: {key}, value}` pairs nested in the snapshot.
    private static func contains(udid: String, in object: xpc_object_t) -> Bool {
        switch xpc_get_type(object) {
        case XPC_TYPE_DICTIONARY:
            if let descriptor = xpc_dictionary_get_value(object, "descriptorIdentifier"),
                let key = xpc_dictionary_get_string(descriptor, "key"), String(cString: key) == "udid",
                let value = xpc_dictionary_get_string(object, "value"),
                String(cString: value).caseInsensitiveCompare(udid) == .orderedSame
            {
                return true
            }
            var hit = false
            xpc_dictionary_apply(object) { _, child in
                hit = contains(udid: udid, in: child)
                return !hit
            }
            return hit
        case XPC_TYPE_ARRAY:
            var hit = false
            xpc_array_apply(object) { _, child in
                hit = contains(udid: udid, in: child)
                return !hit
            }
            return hit
        default:
            return false
        }
    }

    /// Same request devicectl sends before any action: trusted RSD connectivity plus a power assertion.
    /// Without it `createservicesocket` fails with "RemoteServiceDiscovery connectivity is not available".
    ///
    /// The action's reply only comes when the assertion ends. That it took hold arrives as
    /// `CoreDevice.AssertionFulfilledMessage` on the listener we pass as `endpoint`.
    private func acquireUsageAssertion() throws {
        let fulfilled = DispatchSemaphore(value: 0)
        let listener = xpc_connection_create(nil, queue)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                    let type = xpc_dictionary_get_string(message, "mangledTypeName"),
                    String(cString: type) == "CoreDevice.AssertionFulfilledMessage"
                else { return }
                fulfilled.signal()
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        assertionListener = listener

        let requirements = xpc_dictionary_create(nil, nil, 0)
        let states = xpc_array_create(nil, 0)
        for state in [
            "com.apple.coredevice.remoteServiceDiscoveryTrustedConnectivityAvailable",
            "com.apple.coredevice.powerAssertionTaken",
        ] {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(entry, "identifier", state)
            xpc_array_append_value(states, entry)
        }
        xpc_dictionary_set_value(requirements, "deviceStates", states)
        xpc_dictionary_set_value(requirements, "capabilities", xpc_array_create(nil, 0))

        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "reason", "iphone-use")
        xpc_dictionary_set_value(input, "requirements", requirements)
        xpc_dictionary_set_value(input, "endpoint", xpc_endpoint_create(listener))

        let failure = Box<Error?>(nil)
        send("com.apple.coredevice.action.acquireusageassertion", input: input) { result in
            // A reply before fulfilment means it was refused (or CoreDeviceService went away).
            if case .failure(let error) = result { failure.value = error }
            fulfilled.signal()
        }
        guard fulfilled.wait(timeout: .now() + Self.actionTimeout) == .success else {
            throw Failure.timedOut("usage assertion")
        }
        if let error = failure.value { throw error }
    }

    private func invoke(_ action: String, input: xpc_object_t) throws -> xpc_object_t {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Result<xpc_object_t, Error>?>(nil)
        send(action, input: input) { result in
            box.value = result
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.actionTimeout) == .success, let result = box.value else {
            throw Failure.timedOut(action)
        }
        return try result.get()
    }

    private func send(
        _ action: String, input: xpc_object_t,
        completion: @escaping @Sendable (Result<xpc_object_t, Error>) -> Void
    ) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", Self.coreDeviceVersion())
        xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", deviceIdentifier)
        xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 2)
        xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", UUID().uuidString)
        xpc_dictionary_set_value(message, "CoreDevice.input", input)
        xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", action)

        xpc_connection_send_message_with_reply(connection, message, queue) { reply in
            guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                completion(.failure(Failure.serviceUnavailable))
                return
            }
            if let error = xpc_dictionary_get_value(reply, "CoreDevice.error") {
                var text = "unknown error"
                if let info = xpc_dictionary_get_value(error, "userInfo"),
                    let raw = xpc_dictionary_get_string(info, "NSLocalizedDescription")
                {
                    text = String(cString: raw)
                }
                completion(.failure(Failure.actionFailed(action: action, message: text)))
                return
            }
            completion(.success(
                xpc_dictionary_get_value(reply, "CoreDevice.output") ?? xpc_dictionary_create(nil, nil, 0)))
        }
    }

    /// CoreDeviceService checks the client's version, so send the installed framework's own.
    private static func coreDeviceVersion() -> xpc_object_t {
        let plist = (frameworkPath as NSString).deletingLastPathComponent + "/Resources/Info.plist"
        let text = (NSDictionary(contentsOfFile: plist)?["CFBundleVersion"] as? String) ?? "0"
        let parts = text.split(separator: ".").compactMap { UInt64($0) }

        let version = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(version, "originalComponentsCount", Int64(parts.count))
        let components = xpc_array_create(nil, 0)
        for index in 0..<5 {
            xpc_array_append_value(components, xpc_uint64_create(index < parts.count ? parts[index] : 0))
        }
        xpc_dictionary_set_value(version, "components", components)
        xpc_dictionary_set_string(version, "stringValue", text)
        return version
    }
}

/// Carries one value out of an XPC callback (another queue) to the waiting thread.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
