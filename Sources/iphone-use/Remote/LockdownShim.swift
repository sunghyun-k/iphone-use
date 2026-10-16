import CMobileDevice
import Foundation

/// Connects to lockdown services (accessibility, installation_proxy).
///
/// Over USB they are opened with `AMDeviceSecureStartService`. MobileDevice can't see Wi-Fi devices
/// at all, and some devices fail lockdown pairing validation (PITFALLS #25), so otherwise we fall back
/// to the copy the device exports through the tunnel as `<name>.shim.remote` and check in there.
///
/// The check-in is two lockdown-style plists (4-byte big-endian length + XML plist).
/// Send `{Request: RSDCheckin}` and a reply comes back once under the same name, then once as
/// `StartService`. Only after the second reply do the following bytes become the service's own wire.
/// The tunnel is already encrypted, so there's no TLS.
enum LockdownShim {
    enum Failure: Error, CustomStringConvertible {
        case unexpectedReply(String)

        var description: String {
            switch self {
            case .unexpectedReply(let detail): return "unexpected shim check-in reply: \(detail)"
            }
        }
    }

    /// Returns a socket whose following bytes are the service's own wire.
    static func open(_ serviceName: String, rsd: RemoteServiceDiscovery) throws -> TCPSocket {
        let forceShim = ProcessInfo.processInfo.environment["IPHONE_USE_AX_TRANSPORT"] == "tunnel"
        if !forceShim, let socket = openOverUSB(serviceName, udid: rsd.udid) { return socket }

        let socket = try rsd.openSocket(to: serviceName + ".shim.remote")

        try send(
            ["Label": "iphone-use", "ProtocolVersion": "2", "Request": "RSDCheckin"], on: socket)
        try expect("RSDCheckin", from: socket)
        try expect("StartService", from: socket)
        return socket
    }

    /// nil when MobileDevice can't open it, so the caller takes the shim instead.
    ///
    /// The service's wire is plaintext even though it was started "securely" (see CMobileDevice.c).
    private static func openOverUSB(_ serviceName: String, udid: String) -> TCPSocket? {
        guard let device = try? DeviceDiscovery.device(matching: udid),
            let service = try? device.startService(serviceName)
        else { return nil }
        let descriptor = cmd_service_connection_duplicate_socket(service)
        guard descriptor >= 0 else {
            _ = cmd_service_connection_invalidate(service)
            return nil
        }
        let socket = TCPSocket(adopting: descriptor)
        socket.onClose = { _ = cmd_service_connection_invalidate(service) }
        return socket
    }

    /// Sends one lockdown-style plist. Services whose post-check-in wire uses the same framing
    /// (installation_proxy, etc.) use this directly.
    static func send(_ message: [String: Any], on socket: TCPSocket) throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: message, format: .xml, options: 0)
        var length = UInt32(body.count).bigEndian
        try socket.write(Data(bytes: &length, count: 4) + body)
    }

    /// Receives one lockdown-style plist.
    static func receive(from socket: TCPSocket) throws -> [String: Any] {
        let header = [UInt8](try socket.readExactly(4))
        let length =
            Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        let body = try socket.readExactly(length)
        let reply = try PropertyListSerialization.propertyList(from: body, format: nil)
        guard let dictionary = reply as? [String: Any] else {
            throw Failure.unexpectedReply("\(reply)")
        }
        return dictionary
    }

    private static func expect(_ request: String, from socket: TCPSocket) throws {
        let dictionary = try receive(from: socket)
        if let error = dictionary["Error"] {
            throw Failure.unexpectedReply("\(request): \(error)")
        }
        guard dictionary["Request"] as? String == request else {
            throw Failure.unexpectedReply("expected \(request), got \(dictionary["Request"] ?? "none")")
        }
    }
}
