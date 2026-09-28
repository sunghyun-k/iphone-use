import Foundation

/// Minimal Unix domain socket implementation.
///
/// Foundation has no API for UDS, so this uses POSIX directly.
enum UnixSocket {
    /// Daemon socket path. Not split per device — the daemon picks the device from each request's UDID.
    static var defaultPath: String {
        let base = ProcessInfo.processInfo.environment["IPHONE_USE_DIR"]
            ?? NSHomeDirectory() + "/.iphone-use"
        return base + "/daemon.sock"
    }

    enum Failure: Error, CustomStringConvertible {
        case failed(String, errno: Int32)

        var description: String {
            switch self {
            case .failed(let what, let code):
                return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Fills a `sockaddr_un`. A path over 104 bytes would be truncated, so reject it up front.
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= limit else {
            throw Failure.failed("socket path too long (\(bytes.count) > \(limit))", errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: raw.count)
            raw.copyBytes(from: bytes)
        }
        return address
    }

    static func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Reads one full line. nil if the peer closed.
    static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count <= 0 { return buffer.isEmpty ? nil : buffer }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

/// Messages exchanged with the daemon.
struct DaemonRequest: Codable {
    var args: [String]
    /// The sender binary's `BuildStamp`. If it differs from the daemon's, the daemon steps down rather than run old code.
    var build: String?
}

/// A stamp identifying this binary (path + modification time).
///
/// While running, the daemon runs the code it started with. After a fix and `swift build`, commands
/// still went to the daemon and showed the old behavior, and new options didn't even appear in `--help`,
/// which cost a long time to figure out. The daemon records it once at startup.
enum BuildStamp {
    static let current: String = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return "\(path)@\(modified?.timeIntervalSince1970 ?? 0)"
    }()
}

struct DaemonResponse: Codable {
    var exitCode: Int32
    /// Carried as base64 so binary output (screenshots etc.) passes through intact.
    var stdout: String
    var stderr: String
}
