import Foundation

/// Opens connections to the device's services by name.
///
/// The sockets come from CoreDeviceService (`CoreDeviceClient`), which reaches the device through
/// macOS's own `remoted` connection. We never talk to the device's RSD ourselves: a second RSD peer
/// displaces `remoted`, and Xcode loses the device until it is replugged (PITFALLS #44).
final class RemoteServiceDiscovery {
    private let client: CoreDeviceClient
    let udid: String

    init(udid: String?) throws {
        let resolved = try DeviceResolver.udid(for: udid)
        self.udid = resolved
        client = try CoreDeviceClient(udid: resolved)
    }

    func close() {
        client.close()
    }

    /// Opens a new RemoteXPC (HTTP/2) connection to one service.
    func connect(to serviceName: String) throws -> RemoteXPCConnection {
        try RemoteXPCConnection(socket: openSocket(to: serviceName))
    }

    /// Opens a raw connection to a service. No HTTP/2, no RemoteXPC on top.
    ///
    /// Services ending in `.shim.remote` are lockdown services exported through the tunnel, so they
    /// speak lockdown-style plists, not RemoteXPC (`LockdownShim`).
    func openSocket(to serviceName: String) throws -> TCPSocket {
        TCPSocket(adopting: try client.serviceSocket(serviceName))
    }

    /// Service names the device advertises, for diagnostics. CoreDeviceService doesn't list them, but
    /// `remotectl dumpstate` prints them per remoted device (names only, no privilege needed).
    var serviceNames: [String] {
        guard let dump = Self.shell("/usr/libexec/remotectl", ["dumpstate"]) else { return [] }
        let blocks = dump.components(separatedBy: "\nFound ")
        guard let block = blocks.first(where: {
            $0.contains("(coredevice-device)") && $0.range(of: udid, options: .caseInsensitive) != nil
        }) else { return [] }

        var names: [String] = []
        var inServices = false
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "\tServices:" {
                inServices = true
            } else if inServices, line.hasPrefix("\t\t") {
                // Two tabs is a service name; deeper lines are its version and properties.
                if !line.hasPrefix("\t\t\t") { names.append(line.trimmingCharacters(in: .whitespaces)) }
            } else if inServices {
                break
            }
        }
        return names.sorted()
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
