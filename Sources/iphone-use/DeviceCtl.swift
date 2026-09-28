import Foundation

/// `xcrun devicectl` wrapper.
///
/// Launching apps, deep links and the installed-app list need no reverse engineering: CoreDevice's
/// public CLI already does them. We only broke into the accessibility tree and screenshots ourselves;
/// everything else is delegated here.
///
/// Note: when a path through the CoreDevice media daemon (screenshots etc.) wedges on the device side,
/// `devicectl` hangs without replying. So every call gets a timeout.
enum DeviceCtl {
    struct Failure: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let output: String

        var description: String {
            status == -1
                ? "devicectl is not responding (\(arguments.joined(separator: " "))). "
                    + "The device's CoreDevice daemon may be wedged — a reboot clears it."
                : "devicectl failed (\(status)): \(output)"
        }
    }

    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl"] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // If the device is unresponsive, devicectl hangs forever. Kill it once the time is up.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw Failure(arguments: arguments, status: -1, output: "")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(arguments: arguments, status: process.terminationStatus, output: output)
        }
        return output
    }

    /// Takes `--json-output` into a temp file and parses it. devicectl doesn't write the JSON to stdout.
    static func json(_ arguments: [String], timeout: TimeInterval = 30) throws -> Any {
        let path = NSTemporaryDirectory() + "iphone-use-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try run(arguments + ["--json-output", path], timeout: timeout)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data)
    }
}
