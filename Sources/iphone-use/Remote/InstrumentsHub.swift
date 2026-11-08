import CDTXBridge
import Foundation

/// Instruments' DTX service (`dtservicehub`). For now it's only used to revive a daemon on the
/// device (see `AppService`).
///
/// The name suggests a lockdown shim, but **there is no check-in.** DTX flows as soon as the port opens.
/// Send RSDCheckin and the device drops the connection immediately.
final class InstrumentsHub {
    static let serviceName = "com.apple.instruments.dtservicehub"

    private let connection: IUDTXConnection

    init(rsd: RemoteServiceDiscovery) throws {
        try IUDTXConnection.loadFramework(atPath: Self.dtxFrameworkPath())
        let socket = try rsd.openSocket(to: Self.serviceName)
        connection = try IUDTXConnection(socket: socket.detach())
    }

    func close() { connection.cancel() }

    /// Xcode's DTXConnectionServices. Follows `xcode-select -p`.
    static func dtxFrameworkPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developer.isEmpty else { throw Failure.xcodeNotFound }
        // /path/Xcode.app/Contents/Developer -> /path/Xcode.app/Contents/SharedFrameworks
        return (developer as NSString).deletingLastPathComponent
            + "/SharedFrameworks/DTXConnectionServices.framework"
    }

    enum Failure: Error, CustomStringConvertible {
        case xcodeNotFound

        var description: String {
            "Xcode not found (xcode-select -p is empty). Install Xcode and run `sudo xcode-select -s /Applications/Xcode.app`."
        }
    }

    /// pids of processes whose name matches exactly.
    func pids(named name: String) throws -> [Int] {
        try connection.openChannel(withIdentifier: "com.apple.instruments.server.services.deviceinfo")
        let reply = try connection.invokeSelector(
            "runningProcesses", arguments: [], expectsReply: true, timeout: 10)
        return (reply as? [[String: Any]] ?? [])
            .filter { $0["name"] as? String == name }
            .compactMap { ($0["pid"] as? NSNumber)?.intValue }
    }

    func kill(pid: Int) throws {
        try connection.openChannel(
            withIdentifier: "com.apple.instruments.server.services.processcontrol")
        try connection.invokeSelector("killPid:", arguments: [pid], expectsReply: false, timeout: 5)
    }
}
