import Foundation

/// The RemoteXPC services the device advertises inside the tunnel.
///
/// Connecting takes three steps: get the tunnel IP (`RemotePairingTunnel`) → find the RSD port inside
/// it → handshake with RSD to get each service's port.
final class RemoteServiceDiscovery {
    private let tunnel: RemotePairingTunnel
    private let control: RemoteXPCConnection
    private let services: [String: [String: XPCObject]]

    var tunnelIP: String { tunnel.tunnelIP }

    enum Failure: Error, CustomStringConvertible {
        case noRSDPort(String)
        case handshakeFailed
        case unknownService(String)

        var description: String {
            switch self {
            case .noRSDPort(let ip):
                return """
                    could not find the RSD port inside the tunnel (\(ip)). remoted may not have \
                    reached the device yet — try again shortly.
                    """
            case .handshakeFailed:
                return "RSD handshake has no service list."
            case .unknownService(let name):
                return "service not advertised by the device: \(name)"
            }
        }
    }

    init(udid: String?) throws {
        tunnel = try RemotePairingTunnel(udid: udid)

        // If the tunnel was just created, `remoted` is still greeting the device's RSD, and the device
        // drops our connection if it cuts in (Broken pipe). It settles within a few seconds, so retry,
        // re-finding the port each time (PITFALLS #27).
        let deadline = Date().addingTimeInterval(8)
        var connection: RemoteXPCConnection?
        var peerInfo: [String: XPCObject]?
        var lastError: Error?
        while connection == nil {
            let ports = Self.rsdPorts(tunnelIP: tunnel.tunnelIP)
            for port in ports {
                do {
                    let candidate = try RemoteXPCConnection(host: tunnel.tunnelIP, port: port)
                    try candidate.sendDeviceHandshake(peerUUID: Self.peerUUID())
                    let info = try candidate.receiveResponse()
                    connection = candidate
                    peerInfo = info
                    break
                } catch {
                    lastError = error
                }
            }
            if connection != nil || Date() > deadline { break }
            if !ports.isEmpty, let lastError, !(lastError is RemoteXPCError) { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let connection, let peerInfo else {
            throw lastError ?? Failure.noRSDPort(tunnel.tunnelIP)
        }
        control = connection

        guard let advertised = peerInfo["Services"]?.dictionaryValue else {
            throw Failure.handshakeFailed
        }
        services = advertised.compactMapValues { $0.dictionaryValue }
    }

    func close() {
        control.close()
        tunnel.release()
    }

    /// Opens a new RemoteXPC connection to one service.
    ///
    /// Service connections don't send the device handshake — that belongs only to the RSD control connection.
    func connect(to serviceName: String) throws -> RemoteXPCConnection {
        guard let entry = services[serviceName], let port = entry["Port"]?.portNumber else {
            throw Failure.unknownService(serviceName)
        }
        return try RemoteXPCConnection(host: tunnel.tunnelIP, port: port)
    }

    /// Opens a raw TCP connection to a service port. No HTTP/2, no RemoteXPC on top.
    ///
    /// Services ending in `.shim.remote` are lockdown services exported through the tunnel, so they
    /// speak lockdown-style plists, not RemoteXPC (`LockdownShim`).
    func openSocket(to serviceName: String) throws -> TCPSocket {
        guard let entry = services[serviceName], let port = entry["Port"]?.portNumber else {
            throw Failure.unknownService(serviceName)
        }
        return try TCPSocket(host: tunnel.tunnelIP, port: port)
    }

    var serviceNames: [String] { services.keys.sorted() }

    // MARK: - Finding the port/identity

    /// The remote port of `remoted`'s TCP connection to the tunnel IP is the RSD port.
    ///
    /// Why `nettop` rather than `netstat`: since macOS 27 the kernel's `net.inet.tcp.pcblist*` only
    /// returns the caller's own sockets, so sockets of `remoted` (running as root) aren't visible.
    /// `/usr/bin/nettop` is Apple-signed with `com.apple.private.network.statistics` and shows
    /// every process's sockets — so we call it as a subprocess.
    static func rsdPorts(tunnelIP: String) -> [Int] {
        guard let output = shell("/usr/bin/nettop", ["-n", "-x", "-L", "1", "-m", "tcp", "-J", "interface,state"]) else {
            return []
        }

        var ports: [Int] = []
        var currentPID: Int32?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let first = fields.first else { continue }

            // Socket rows: "tcp6 <local><-><foreign>". Anything else is a "<process name>.<pid>" row.
            guard first.hasPrefix("tcp4 ") || first.hasPrefix("tcp6 ") else {
                let parts = first.split(separator: ".")
                currentPID = parts.count >= 2 ? Int32(parts[parts.count - 1]) : nil
                continue
            }
            guard let pid = currentPID, fields.count >= 3, fields[2] == "Established",
                let range = first.range(of: "<->")
            else { continue }

            let foreign = String(first[range.upperBound...])
            guard let (address, port) = splitEndpoint(foreign), address == tunnelIP,
                processPath(pid) == "/usr/libexec/remoted"
            else { continue }
            ports.append(port)
        }
        return ports
    }

    /// `fd75:b8ef:e176::1.55137` / `fe80::1%utun4.55137` / `10.0.0.1:443` -> (address, port)
    static func splitEndpoint(_ endpoint: String) -> (String, Int)? {
        let separator: Character = endpoint.filter { $0 == ":" }.count == 1 ? ":" : "."
        guard let index = endpoint.lastIndex(of: separator) else { return nil }
        guard let port = Int(endpoint[endpoint.index(after: index)...]) else { return nil }
        let address = String(endpoint[..<index]).split(separator: "%").first.map(String.init) ?? ""
        return (address, port)
    }

    /// UUID for the RSD handshake. **Must match the host `remoted`'s.**
    ///
    /// The device keeps only one RSD connection per tunnel, and if a new peer's UUID differs from the
    /// previous one it closes every advertised service listener (which drops Xcode too).
    /// On macOS `remoted` keeps reconnecting with its own UUID, so with a different identity we get pushed out.
    static func peerUUID() -> UUID {
        guard let dump = shell("/usr/libexec/remotectl", ["dumpstate"]),
            let range = dump.range(of: "Local device"),
            let uuidRange = dump.range(of: "UUID: ", range: range.upperBound..<dump.endIndex)
        else {
            return UUID()
        }
        let tail = dump[uuidRange.upperBound...].prefix(36)
        return UUID(uuidString: String(tail)) ?? UUID()
    }

    private static func processPath(_ pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension XPCObject {
    /// Depending on the device, the port comes as a string or an integer.
    var portNumber: Int? {
        if let value = intValue { return value }
        if let text = stringValue { return Int(text) }
        return nil
    }
}
