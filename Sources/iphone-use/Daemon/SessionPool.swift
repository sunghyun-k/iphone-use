import Foundation

/// Keeps open CoreDevice/service connections for reuse.
///
/// Checking in with CoreDeviceService and taking a usage assertion takes about 0.2 s per command
/// (seconds when the tunnel is cold). That's unavoidable for a
/// run-once CLI, but as a daemon the cost is paid only once.
///
/// With `keepAlive` off (= a plain CLI run), whatever was borrowed is handed back and closed.
/// With it on (= daemon), the tunnel is held and handed out again for the next request. HID
/// connections (PITFALLS #50) and the screen size (PITFALLS #51) are fetched fresh per command.
enum SessionPool {
    /// Only the daemon turns this on. From then on the tunnel is never closed.
    nonisolated(unsafe) static var keepAlive = false

    private nonisolated(unsafe) static var cached: [String: RemoteServiceDiscovery] = [:]

    /// `touch` marks the device as in use, so the daemon keeps it from auto-locking for a while
    /// (`KeepAwake`). Only keep-awake itself passes false, or it would extend its own window forever.
    static func rsd(udid: String?, touch: Bool = true) throws -> RemoteServiceDiscovery {
        guard keepAlive else { return try RemoteServiceDiscovery(udid: udid) }

        let key = udid ?? ""
        if touch { KeepAwake.touched(key) }
        if let existing = cached[key] { return existing }
        let fresh = try RemoteServiceDiscovery(udid: udid)
        cached[key] = fresh
        return fresh
    }

    static func release(_ rsd: RemoteServiceDiscovery) {
        guard !keepAlive else { return }
        rsd.close()
    }

    /// Opens a new HID connection for every command, even in the daemon.
    ///
    /// The daemon used to keep one HID connection for its whole life. After a while that connection kept
    /// answering PINGs while the device silently stopped acting on the reports sent over it: taps printed
    /// success and nothing happened, while `--no-daemon` worked at once (PITFALLS #50). The tunnel stays
    /// cached, so a fresh connection costs one RemoteXPC handshake (about 0.06 s over Wi-Fi; buttons
    /// open a second, slower one only when needed), plus the wait before its first report that a new
    /// connection needs (`HIDService.surfaceSettle`, PITFALLS #54).
    static func hid(udid: String?, rsd: RemoteServiceDiscovery) throws -> HIDService {
        try HIDService(rsd: rsd)
    }

    /// Returns only after the input sent has fully reached the device (see `HIDService.sync()`), then
    /// closes the connection.
    ///
    /// If the PING fails in the daemon, the tunnel the connection came from may be bad too, so let
    /// everything go and the next request opens fresh.
    static func release(_ hid: HIDService) {
        do {
            try hid.sync()
        } catch {
            if keepAlive { drop() }
        }
        hid.close()
    }

    /// Releases everything held, so the next request opens fresh when a connection has gone bad.
    static func drop() {
        for rsd in cached.values { rsd.close() }
        cached = [:]
    }
}
