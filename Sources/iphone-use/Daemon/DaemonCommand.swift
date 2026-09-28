import ArgumentParser
import Foundation

/// A resident process that keeps the tunnel open and runs commands on the client's behalf.
///
/// Opening a fresh tunnel + RSD takes about 0.2 s per command (over 1 s when the tunnel is cold).
/// With the daemon running, that cost is paid once and later commands finish in tens of milliseconds —
/// measured, `clipboard` goes from 0.25 s to 0.03 s. The client (= a plain `iphone-use ...`) forwards
/// here on its own whenever the socket is alive.
///
/// The daemon holds a pairing assertion, so it isn't kept up forever — by default it exits after 10 idle minutes.
struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Keep the tunnel open and run commands through it (light commands go from 0.25 s to 0.03 s).",
        discussion: """
            Runs in the foreground; append `&` yourself to background it.
            One daemon serves every device — each command picks its device with its own --udid.
            Check it with `daemon --status`; stop it with `daemon --stop`.
            """
    )

    /// An agent following "--udid on every command" once added it here too; the option error kept the daemon
    /// from starting and nobody noticed for the whole session. Accept it but don't use it.
    @Option(name: .long, help: "Ignored. The daemon serves any device and follows each command's --udid.")
    var udid: String?

    @Flag(name: .long, help: "Report whether the daemon is running.")
    var status = false

    @Option(name: .long, help: "Socket path.")
    var socket: String = UnixSocket.defaultPath

    @Option(name: .long, help: "Exit after this many seconds with no requests. 0 keeps it running.")
    var idleTimeout: Double = 600

    @Flag(name: .long, help: "Stop the running daemon.")
    var stop = false

    func run() throws {
        if stop {
            try stopRunning()
            return
        }
        if status {
            let alive = DaemonClient.send(["__ping__"], socketPath: socket) != nil
            print(alive ? "Daemon is running: \(socket)" : "No daemon running.")
            return
        }
        try serve()
    }

    private func stopRunning() throws {
        guard let response = DaemonClient.send(["__shutdown__"], socketPath: socket) else {
            print("No daemon running.")
            return
        }
        _ = response
        print("Daemon stopped.")
    }

    private func serve() throws {
        let directory = (socket as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // A leftover dead socket file makes bind fail with EADDRINUSE.
        if DaemonClient.send(["__ping__"], socketPath: socket) != nil {
            throw ValidationError("A daemon is already running: \(socket)")
        }
        unlink(socket)

        let listener = Foundation.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw UnixSocket.Failure.failed("socket", errno: errno) }
        defer { close(listener) }

        var address = try UnixSocket.address(socket)
        let bound = UnixSocket.withAddress(&address) { pointer, length in
            bind(listener, pointer, length)
        }
        guard bound == 0 else { throw UnixSocket.Failure.failed("bind", errno: errno) }
        chmod(socket, 0o600)

        // The socket file outlives the process, so always remove it on exit.
        Self.socketToUnlink = socket
        atexit { if let path = DaemonCommand.socketToUnlink { unlink(path) } }
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber) { _ in
                if let path = DaemonCommand.socketToUnlink { unlink(path) }
                _exit(0)
            }
        }

        guard listen(listener, 8) == 0 else {
            throw UnixSocket.Failure.failed("listen", errno: errno)
        }

        _ = BuildStamp.current  // Stamp the binary as of startup. Stamped later, it would look like the new build.
        SessionPool.keepAlive = true
        FileHandle.standardError.write(Data("Daemon started: \(socket)\n".utf8))

        while true {
            if !waitForConnection(listener) {
                FileHandle.standardError.write(Data("Idle timeout, exiting.\n".utf8))
                return
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            let keepGoing = handle(client)
            close(client)
            if !keepGoing { return }
        }
    }

    /// To measure idle time, wait with poll instead of blocking in accept.
    private func waitForConnection(_ listener: Int32) -> Bool {
        guard idleTimeout > 0 else { return true }
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(idleTimeout * 1000))
        return ready > 0
    }

    /// Handles one request. Returns false to shut the daemon down.
    private func handle(_ client: Int32) -> Bool {
        guard let line = UnixSocket.readLine(client),
            let request = try? JSONDecoder().decode(DaemonRequest.self, from: line)
        else { return true }

        if request.args == ["__ping__"] {
            reply(client, DaemonResponse(exitCode: 0, stdout: "", stderr: ""))
            return true
        }
        if request.args == ["__shutdown__"] {
            reply(client, DaemonResponse(exitCode: 0, stdout: "", stderr: ""))
            return false
        }

        if let build = request.build, build != BuildStamp.current {
            reply(client, DaemonResponse(exitCode: DaemonClient.staleExitCode, stdout: "", stderr: ""))
            FileHandle.standardError.write(Data("A newer client build connected, exiting.\n".utf8))
            return false
        }

        let result = Self.execute(request.args)
        reply(client, result)
        return true
    }

    private func reply(_ client: Int32, _ response: DaemonResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        UnixSocket.writeAll(client, data)
    }

    /// Runs the command inside this process and collects its output.
    ///
    /// Commands write straight to stdout with `print`, so fds 1/2 are redirected to temp files while it runs.
    /// Files rather than pipes, because with output over 64 KB (like a screenshot) the pipe fills up
    /// and deadlocks.
    nonisolated(unsafe) private static var socketToUnlink: String?

    static func execute(_ args: [String]) -> DaemonResponse {
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appendingPathComponent("iphone-use-\(UUID().uuidString).out")
        let errURL = directory.appendingPathComponent("iphone-use-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let savedOut = dup(1)
        let savedErr = dup(2)
        let outFD = open(outURL.path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        let errFD = open(errURL.path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        dup2(outFD, 1)
        dup2(errFD, 2)

        var exitCode: Int32 = 0
        do {
            var command = try IPhoneUse.parseAsRoot(args)
            try command.run()
        } catch {
            let message = IPhoneUse.fullMessage(for: error)
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exitCode = IPhoneUse.exitCode(for: error).rawValue
            // If it failed because the connection went bad, let go so the next request opens a new tunnel.
            // Error messages are written to say "connection" or "tunnel" for exactly this check.
            let lower = message.lowercased()
            if lower.contains("connection") || lower.contains("tunnel") { SessionPool.drop() }
        }

        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, 1)
        dup2(savedErr, 2)
        close(savedOut)
        close(savedErr)
        close(outFD)
        close(errFD)

        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return DaemonResponse(
            exitCode: exitCode, stdout: out.base64EncodedString(),
            stderr: err.base64EncodedString())
    }
}
