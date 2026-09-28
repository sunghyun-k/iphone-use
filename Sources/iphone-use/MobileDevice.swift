import CMobileDevice
import CoreFoundation
import Foundation

/// Loading MobileDevice.framework and discovering devices.
///
/// The framework is opened with dlopen, so where it's missing or its symbols changed you get
/// `MobileDeviceError.frameworkUnavailable` instead of a crash.
enum MobileDevice {
    private static let loaded: Result<Void, MobileDeviceError> = {
        guard cmd_load_mobile_device() == 0 else {
            let reason = String(cString: cmd_load_error())
            return .failure(.frameworkUnavailable(reason))
        }
        return .success(())
    }()

    static func ensureLoaded() throws {
        try loaded.get()
    }
}

enum MobileDeviceError: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case noDeviceFound
    case deviceNotFound(udid: String)
    case callFailed(String, code: Int32)
    case ambiguousDevice(candidates: String)

    var description: String {
        switch self {
        case .frameworkUnavailable(let reason):
            return "Cannot open MobileDevice.framework: \(reason)"
        case .noDeviceFound:
            return "No device found. Check the USB connection and that the device trusts this Mac."
        case .deviceNotFound(let udid):
            return "Device not found: \(udid)"
        case .callFailed(let name, let code):
            let hex = String(UInt32(bitPattern: code), radix: 16)
            return "\(name) failed (0x\(hex))"
        case .ambiguousDevice(let candidates):
            return "Multiple devices connected. Pick one with --udid: \(candidates)"
        }
    }
}

/// One device connected by cable.
///
/// The `AMDeviceRef` is retained when the callback hands it over and released in `deinit`.
final class Device {
    let handle: AMDeviceRef

    init(retaining handle: AMDeviceRef) {
        self.handle = cmd_device_retain(handle)
    }

    deinit {
        cmd_device_release(handle)
    }

    var udid: String? {
        guard let raw = cmd_device_copy_identifier(handle) else { return nil }
        return (raw.takeRetainedValue() as String)
    }

    /// Reads one lockdown value. Some keys need an open session.
    func value(for key: String, domain: String? = nil) -> Any? {
        let cfDomain = domain.map { $0 as CFString }
        guard let raw = cmd_device_copy_value(handle, cfDomain, key as CFString) else { return nil }
        return raw.takeRetainedValue()
    }

    /// Runs connect → validate pairing → start session together,
    /// and tears them down in reverse order when the block ends.
    func withSession<T>(_ body: (Device) throws -> T) throws -> T {
        try check(cmd_device_connect(handle), "AMDeviceConnect")
        defer { _ = cmd_device_disconnect(handle) }

        try check(cmd_device_validate_pairing(handle), "AMDeviceValidatePairing")

        try check(cmd_device_start_session(handle), "AMDeviceStartSession")
        defer { _ = cmd_device_stop_session(handle) }

        return try body(self)
    }

    private func check(_ code: Int32, _ name: String) throws {
        guard code == 0 else { throw MobileDeviceError.callFailed(name, code: code) }
    }
}

/// Where the notification callback collects devices.
///
/// The `AMDeviceNotificationSubscribe` callback is a C function pointer and can't capture context.
/// So the collector is a file-level global, filled only during discovery.
private final class DeviceCollector {
    var devices: [Device] = []
}

nonisolated(unsafe) private var activeCollector: DeviceCollector?

private func deviceNotificationCallback(
    _ info: UnsafeMutablePointer<AMDeviceNotificationInfo>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let info, info.pointee.msg == 1, let handle = info.pointee.device else { return }
    activeCollector?.devices.append(Device(retaining: handle))
}

/// Collects connected devices.
///
/// The callback fires on the current run loop, so spinning it briefly picks up every device already connected.
enum DeviceDiscovery {
    /// Devices connected right now. Spins the run loop for `settle` to receive notifications.
    static func connectedDevices(settle: TimeInterval = 0.6) throws -> [Device] {
        try MobileDevice.ensureLoaded()

        let collector = DeviceCollector()
        activeCollector = collector
        defer { activeCollector = nil }

        var notification: AMDeviceNotificationRef?
        let code = cmd_notification_subscribe(deviceNotificationCallback, nil, &notification)
        guard code == 0 else {
            throw MobileDeviceError.callFailed("AMDeviceNotificationSubscribe", code: code)
        }
        defer {
            if let notification { _ = cmd_notification_unsubscribe(notification) }
        }

        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        return collector.devices
    }

    /// Picks one by UDID. With nil it picks the only device, and fails if there are several.
    static func device(matching udid: String?) throws -> Device {
        let devices = try connectedDevices()
        guard !devices.isEmpty else { throw MobileDeviceError.noDeviceFound }

        guard let udid else {
            if devices.count > 1 {
                let list = devices.compactMap(\.udid).joined(separator: ", ")
                throw MobileDeviceError.ambiguousDevice(candidates: list)
            }
            return devices[0]
        }

        guard let match = devices.first(where: { $0.udid == udid }) else {
            throw MobileDeviceError.deviceNotFound(udid: udid)
        }
        return match
    }
}
