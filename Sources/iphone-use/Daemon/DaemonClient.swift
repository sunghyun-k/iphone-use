import Foundation

/// If the daemon is running, hand the command to it; otherwise just run it here.
enum DaemonClient {
    /// Commands that must not go to the daemon: the daemon itself, and diagnostics better run without it.
    private static let localOnly: Set<String> = ["daemon", "help", "--help", "-h", "--version"]

    /// Exit code the daemon returns when it steps down as a stale build. No user command ever produces it.
    static let staleExitCode: Int32 = 211

    static func shouldForward(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if localOnly.contains(first) { return false }
        // Sometimes you want to bypass it explicitly (e.g. when the connection the daemon holds has gone bad).
        if args.contains("--no-daemon") { return false }
        if ProcessInfo.processInfo.environment["IPHONE_USE_NO_DAEMON"] != nil { return false }
        return true
    }

    /// Sends a request and gets the reply. nil if there's no daemon.
    static func send(_ args: [String], socketPath: String = UnixSocket.defaultPath)
        -> DaemonResponse?
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard var address = try? UnixSocket.address(socketPath) else { return nil }
        let connected = UnixSocket.withAddress(&address) { pointer, length in
            connect(fd, pointer, length)
        }
        guard connected == 0 else {
            // The process died and only the socket file is left. Clean it up or the next daemon can't start.
            if errno == ECONNREFUSED { unlink(socketPath) }
            return nil
        }

        guard var payload = try? JSONEncoder().encode(DaemonRequest(args: args, build: BuildStamp.current))
        else { return nil }
        payload.append(UInt8(ascii: "\n"))
        UnixSocket.writeAll(fd, payload)

        guard let line = UnixSocket.readLine(fd),
            let response = try? JSONDecoder().decode(DaemonResponse.self, from: line)
        else { return nil }
        if response.exitCode == staleExitCode {
            FileHandle.standardError.write(
                Data("(The daemon was a stale build, so it was stopped. This command runs without it. To restart: `iphone-use daemon &`)\n".utf8))
            return nil
        }
        return response
    }

    /// Passes the daemon's output through unchanged and returns its exit code.
    static func relay(_ response: DaemonResponse) -> Int32 {
        if let out = Data(base64Encoded: response.stdout), !out.isEmpty {
            FileHandle.standardOutput.write(out)
        }
        if let err = Data(base64Encoded: response.stderr), !err.isEmpty {
            FileHandle.standardError.write(err)
        }
        return response.exitCode
    }
}
