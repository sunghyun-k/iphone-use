import Foundation

/// Keeps open tunnel/service connections for reuse.
///
/// Opening a fresh tunnel takes about 0.2 s per command (over 1 s when cold). That's unavoidable for a
/// run-once CLI, but as a daemon the cost is paid only once.
///
/// With `keepAlive` off (= a plain CLI run), whatever was borrowed is handed back and closed.
/// With it on (= daemon), nothing is closed; it's held and handed out again for the next request.
enum SessionPool {
    /// Only the daemon turns this on. From then on connections are never closed.
    nonisolated(unsafe) static var keepAlive = false

    private nonisolated(unsafe) static var cached: [String: RemoteServiceDiscovery] = [:]
    private nonisolated(unsafe) static var hidCache: [String: HIDService] = [:]
    private nonisolated(unsafe) static var screenCache: [String: ScreenSize] = [:]
    private nonisolated(unsafe) static var axCache: [String: AXSession] = [:]

    static func rsd(udid: String?) throws -> RemoteServiceDiscovery {
        guard keepAlive else { return try RemoteServiceDiscovery(udid: udid) }

        let key = udid ?? ""
        if let existing = cached[key] { return existing }
        let fresh = try RemoteServiceDiscovery(udid: udid)
        cached[key] = fresh
        return fresh
    }

    static func release(_ rsd: RemoteServiceDiscovery) {
        guard !keepAlive else { return }
        rsd.close()
    }

    static func hid(udid: String?, rsd: RemoteServiceDiscovery) throws -> HIDService {
        guard keepAlive else { return try HIDService(rsd: rsd) }

        let key = udid ?? ""
        if let existing = hidCache[key] { return existing }
        let fresh = try HIDService(rsd: rsd)
        hidCache[key] = fresh
        return fresh
    }

    /// Returns only after the input sent has fully reached the device (see `HIDService.sync()`).
    ///
    /// The daemon doesn't close the connection but still syncs. Otherwise the command finishes while the
    /// device hasn't read the input yet, and an immediate `screenshot` captures the screen from before
    /// the input. If the PING fails here, the held connection is dead, so let it go and the next request
    /// opens a new one.
    static func release(_ hid: HIDService) {
        guard keepAlive else {
            try? hid.sync()
            hid.close()
            return
        }
        do {
            try hid.sync()
        } catch {
            drop()
        }
    }

    /// Screen size doesn't change unless the device rotates, so it can be cached.
    static func screen(udid: String?, rsd: RemoteServiceDiscovery) throws -> ScreenSize {
        guard keepAlive else { return try ScreenSize.query(rsd: rsd) }

        let key = udid ?? ""
        if let existing = screenCache[key] { return existing }
        let fresh = try ScreenSize.query(rsd: rsd)
        screenCache[key] = fresh
        return fresh
    }

    /// Accessibility session the daemon holds on to (tunnel path). nil if it can't be opened — the caller takes the normal path.
    static func axSession(udid: String) -> AXSession? {
        guard keepAlive else { return nil }
        if let existing = axCache[udid] { return existing }
        guard let rsd = try? rsd(udid: udid), let fresh = try? AXSession(tunnel: rsd) else { return nil }
        axCache[udid] = fresh
        return fresh
    }

    static func dropAX(udid: String) {
        axCache.removeValue(forKey: udid)?.close()
    }

    /// Releases everything held, so the next request opens fresh when a connection has gone bad.
    static func drop() {
        for session in axCache.values { session.close() }
        axCache = [:]
        for hid in hidCache.values { hid.close() }
        for rsd in cached.values { rsd.close() }
        hidCache = [:]
        cached = [:]
        screenCache = [:]
    }
}
