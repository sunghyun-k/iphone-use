import CDTXBridge
import CMobileDevice
import Foundation

/// A session to the device's accessibility audit daemon.
///
/// There are two transports; from raw socket -> DTXSocketTransport -> DTXConnection onward they are the same.
/// - USB: the socket of a lockdown service (`AMDeviceSecureStartService`).
/// - Wi-Fi: a socket checked in to `<service>.shim.remote` inside the tunnel (`LockdownShim`).
///   MobileDevice cannot see Wi-Fi devices, so this is the only way there.
/// Either way the wire is plaintext (see CMobileDevice.c for why).
/// Every call goes out on the control channel (code 0).
final class AXSession {
    /// Service name used on iOS 14 and later.
    static let serviceName = "com.apple.accessibility.axAuditDaemon.remoteserver"

    private let connection: IUDTXConnection
    /// While the DTX socket lives, whoever handed out the socket (service connection or tunnel) must be kept alive too.
    private enum Owner {
        case lockdown(AMDServiceConnectionRef)
        case tunnel(RemoteServiceDiscovery)
    }
    private let owner: Owner

    /// Xcode's SharedFrameworks path. Follows `xcode-select -p`.
    static func dtxFrameworkPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let developer = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !developer.isEmpty else {
            throw AXSessionError.xcodeNotFound
        }

        // /path/Xcode.app/Contents/Developer -> /path/Xcode.app/Contents/SharedFrameworks
        return (developer as NSString).deletingLastPathComponent
            + "/SharedFrameworks/DTXConnectionServices.framework"
    }

    init(device: Device) throws {
        try IUDTXConnection.loadFramework(atPath: Self.dtxFrameworkPath())

        var service: AMDServiceConnectionRef?
        let code = cmd_device_secure_start_service(
            device.handle, Self.serviceName as CFString, nil, &service)
        guard code == 0, let service else {
            throw AXSessionError.serviceStartFailed(code: code)
        }

        owner = .lockdown(service)

        let socket = ProcessInfo.processInfo.environment["IU_DTX_TEE"] != nil
            ? cmd_service_connection_tee_socket(service)
            : cmd_service_connection_duplicate_socket(service)
        guard socket >= 0 else {
            throw AXSessionError.pumpFailed
        }

        // IUDTXConnection connects the control channel and installs handlers before resume.
        connection = try IUDTXConnection(socket: socket)
    }

    /// Tunnel transport. `rsd` is handed back with `SessionPool.release` when the session closes.
    init(tunnel rsd: RemoteServiceDiscovery) throws {
        try IUDTXConnection.loadFramework(atPath: Self.dtxFrameworkPath())

        let socket = try LockdownShim.open(Self.serviceName, rsd: rsd)
        owner = .tunnel(rsd)
        connection = try IUDTXConnection(socket: socket.detach())
    }

    /// Picks the device, opens a session, and closes it when the block ends.
    ///
    /// If MobileDevice sees the device (USB) it takes the lockdown path, otherwise (Wi-Fi) the tunnel path.
    /// With `IPHONE_USE_AX_TRANSPORT=tunnel` it uses the tunnel even over USB (for testing the tunnel path).
    static func with<T>(udid wanted: String?, _ body: (AXSession) throws -> T) throws -> T {
        let udid = try DeviceResolver.udid(for: wanted)

        // In the daemon the session is not closed but reused for the next request. Opening alone takes
        // about 1.3 s, which made every `ui`/`press` that much slower. It opens over the tunnel — the
        // daemon already holds the tunnel, while the lockdown path only lives inside a MobileDevice
        // session block and can't be held. Devices without a tunnel (iOS 16 and earlier) take the
        // normal path below.
        if SessionPool.keepAlive, let session = SessionPool.axSession(udid: udid) {
            session.drainEvents()
            session.resetAuditTarget()
            do {
                let value = try body(session)
                session.resetAuditTarget()
                return value
            } catch {
                // Unless we stopped on purpose (`KeepsSession`), the connection may be broken. Let it go.
                if !(error is KeepsSession) { SessionPool.dropAX(udid: udid) }
                throw error
            }
        }

        let forceTunnel = ProcessInfo.processInfo.environment["IPHONE_USE_AX_TRANSPORT"] == "tunnel"

        var usb: Device?
        if !forceTunnel {
            do {
                usb = try DeviceDiscovery.device(matching: udid)
            } catch MobileDeviceError.noDeviceFound, MobileDeviceError.deviceNotFound {
                usb = nil
            }
        }

        if let usb {
            do {
                return try usb.withSession { connected in
                    let session = try AXSession(device: connected)
                    defer { session.close() }
                    return try body(session)
                }
            } catch MobileDeviceError.callFailed {
                // If the lockdown session can't be opened, fall back to the tunnel. On an iPad (iOS 26.6)
                // `AMDeviceValidatePairing` failed with 0xE8000025 even when unlocked — the device has only
                // a CoreDevice pairing and its lockdown record doesn't match. The tunnel path works there.
            }
        }

        let rsd = try SessionPool.rsd(udid: udid)
        let session: AXSession
        do {
            session = try AXSession(tunnel: rsd)
        } catch {
            SessionPool.release(rsd)
            throw error
        }
        defer { session.close() }
        return try body(session)
    }

    /// Receives messages the device pushes.
    func onEvent(_ handler: @escaping (String, [Any]) -> Void) {
        connection.eventHandler = { selector, arguments in
            handler(selector, arguments)
        }
    }

    @discardableResult
    func invoke(
        _ selector: String,
        _ arguments: [Any] = [],
        expectsReply: Bool = true,
        timeout: TimeInterval = 10
    ) throws -> Any? {
        let value = try connection.invokeSelector(
            selector,
            arguments: arguments,
            expectsReply: expectsReply,
            timeout: timeout)
        return value is NSNull ? nil : value
    }

    /// Clears any audit-target pid the daemon still has pinned.
    ///
    /// If a dead pid is left pinned, focus events stop for **every connection** afterwards.
    /// Always call this at session start and end.
    func resetAuditTarget() {
        for selector in ["deviceSetAuditTargetPid:", "deviceSetAuditUIPid:"] {
            _ = try? invoke(selector, [0], expectsReply: false)
        }
    }

    func close() {
        resetAuditTarget()
        connection.cancel()
        if case .tunnel(let rsd) = owner {
            SessionPool.release(rsd)
        }
    }

    // MARK: - Inspector focus walk

    /// Queue that holds focus events. Callbacks arrive on the DTX queue; consumption happens on the calling thread.
    private final class EventQueue {
        private let condition = NSCondition()
        private var pending: [(String, [Any])] = []

        func push(_ event: (String, [Any])) {
            condition.lock()
            pending.append(event)
            condition.signal()
            condition.unlock()
        }

        /// Takes one from the queue. nil if nothing arrives in time.
        ///
        /// Don't just block. DTX schedules incoming messages on the **main queue**, so the run loop
        /// must be spun while waiting or the callbacks never run.
        func pop(timeout: TimeInterval) -> (String, [Any])? {
            let deadline = Date().addingTimeInterval(timeout)

            while true {
                condition.lock()
                let event = pending.isEmpty ? nil : pending.removeFirst()
                condition.unlock()

                if let event {
                    return event
                }
                if Date() >= deadline {
                    return nil
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
    }

    private let events = EventQueue()

    /// Discards queued events. When the daemon reuses a session, this keeps focus events that arrived
    /// after the previous request from being mistaken for the answer to this move.
    func drainEvents() {
        while events.pop(timeout: 0.05) != nil {}
    }

    /// Prepares to sweep the foreground app's elements with focus.
    func beginFocusWalk() throws {
        let debug = ProcessInfo.processInfo.environment["IU_DTX_DEBUG"] != nil
        connection.eventHandler = { [events] selector, arguments in
            if debug {
                FileHandle.standardError.write(
                    Data("[event] \(selector) \(arguments.count) args\n".utf8))
            }
            events.push((selector, arguments))
        }

        try invoke("deviceSetAppMonitoringEnabled:", [true], expectsReply: false)
        try invoke("deviceInspectorSetMonitoredEventType:", [0], expectsReply: false)
    }

    func moveFocus(_ direction: AXWire.Direction = .next) throws {
        try invoke(
            "deviceInspectorMoveWithOptions:", [AXWire.moveOptions(direction)],
            expectsReply: false)
    }

    /// Waits for the focus object of the next `hostInspectorCurrentElementChanged:` event.
    ///
    /// Other events (`hostInspectorMonitoredEventTypeChanged:` etc.) are dropped and it **keeps waiting**.
    /// Returning nil here would make the caller conclude "the move didn't take" and send another move;
    /// if a second `deviceInspectorMoveWithOptions:` lands before the first finishes, the daemon's element
    /// resolution breaks entirely and every later `deviceElement:valueForAttribute:` returns nil (it
    /// does not recover for the rest of the session). Only if no focus arrives in time does it return nil.
    func nextFocus(timeout: TimeInterval = 1.0) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let (selector, arguments) = events.pop(timeout: remaining) else {
                return nil
            }
            guard selector == "hostInspectorCurrentElementChanged:" else {
                continue
            }

            var payload = AXWire.unwrap(arguments.first)
            if let list = payload as? [Any] {
                payload = list.first
            }
            return payload as? [String: Any]
        }
    }

    // MARK: - Actions

    /// Moves the inspector focus to a specific element.
    func focus(on token: Data) throws {
        try invoke(
            "deviceInspectorFocusOnElement:", [AXWire.element(token)], expectsReply: false)
    }

    /// Performs an action on an element.
    ///
    /// Note: the daemon accepts the request and replies with errorStatus 0, but if the target process
    /// isn't debuggable (`task_for_pid-allow`) **nothing happens**. It is silently ignored in App Store
    /// apps and SpringBoard. A real tap needs the HID path.
    func perform(action: [String: Any], on token: Data) throws {
        try invoke(
            "deviceElement:performAction:withValue:",
            [AXWire.element(token), action, 0],
            expectsReply: false)
    }

    /// Writes a value to an element attribute. Used to type into text fields.
    func setValue(_ value: Any, of token: Data, attribute name: String = "Value") throws {
        try invoke(
            "deviceElement:setValue:attribute:",
            [
                AXWire.element(token), AXWire.passthrough(value),
                AXWire.attribute(named: name, settable: 1),
            ],
            expectsReply: false)
    }

    /// Hit-tests the screen at normalized coordinates (0-1) and returns the element there.
    func element(atNormalized x: Double, _ y: Double) throws -> Any? {
        AXWire.unwrap(
            try invoke(
                "deviceFetchElementAtNormalizedDeviceCoordinate:",
                [AXWire.point(x: x, y: y)]))
    }

    /// Captures the whole screen.
    func captureScreenshot() throws -> Any? {
        AXWire.unwrap(try invoke("deviceCaptureScreenshot", timeout: 30))
    }

    /// One attribute value of one element.
    func value(of token: Data, attribute name: String, timeout: TimeInterval = 8) throws -> Any? {
        let reply = try invoke(
            "deviceElement:valueForAttribute:",
            [AXWire.element(token), AXWire.attribute(named: name)],
            timeout: timeout)
        return AXWire.unwrap(reply)
    }
}

/// Ending with this error leaves the accessibility session intact (usage or judgment errors). The daemon keeps the session.
protocol KeepsSession: Error {}

extension AXSession {
    /// Pulls the platform token out of a focus object.
    static func token(of focus: [String: Any]) -> Data? {
        guard let element = focus["ElementValue_v1"] as? [String: Any] else { return nil }
        return element["PlatformElementValue_v1"] as? Data
    }
}

enum AXSessionError: Error, CustomStringConvertible {
    case xcodeNotFound
    case serviceStartFailed(code: Int32)
    case pumpFailed

    var description: String {
        switch self {
        case .xcodeNotFound:
            return "Xcode not found. Check xcode-select -p."
        case .serviceStartFailed(let code):
            return """
                Cannot open the accessibility service (0x\(String(code, radix: 16))). \
                Make sure the device is unlocked and Developer Mode is on.
                """
        case .pumpFailed:
            return "Cannot set up the TLS pump."
        }
    }
}
