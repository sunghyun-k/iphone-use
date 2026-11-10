import Foundation

/// Keeps devices the daemon has recently worked on from auto-locking (PITFALLS #67).
///
/// Nothing the host can call changes Auto-Lock, and a power assertion doesn't hold the screen on. What
/// works is input: an all-released keyboard report resets the device's idle timer, types nothing,
/// leaves the on-screen keyboard up and doesn't wake a screen that is already off. So while a device
/// was used within `window`, the daemon sends one every `interval`.
enum KeepAwake {
    /// Seconds after a device's last command during which it is kept awake. 0 turns this off.
    nonisolated(unsafe) static var window: TimeInterval = 300

    /// With the shortest Auto-Lock (30 s) the screen went dark 40–60 s after the last input, so 20 s
    /// leaves room for a slow request in between.
    static let interval: TimeInterval = 20

    private nonisolated(unsafe) static var lastUsed: [String: Date] = [:]
    private nonisolated(unsafe) static var lastSent = Date.distantPast

    /// Called whenever a command borrows a device's tunnel.
    static func touched(_ key: String) {
        lastUsed[key] = Date()
    }

    /// How long the daemon may wait for a request before `tick()` is due, or nil when nothing needs
    /// keeping awake.
    static var secondsUntilDue: TimeInterval? {
        guard window > 0, !activeKeys.isEmpty else { return nil }
        return max(0, lastSent.addingTimeInterval(interval).timeIntervalSinceNow)
    }

    /// Sends the report to every device still inside its window, if one is due.
    static func tick() {
        guard let due = secondsUntilDue, due <= 0 else { return }
        lastSent = Date()
        for key in activeKeys {
            do {
                let rsd = try SessionPool.rsd(udid: key.isEmpty ? nil : key, touch: false)
                let hid = try HIDService(rsd: rsd)
                // Waits until the report has reached the device before closing (`HIDService.sync()`).
                defer { SessionPool.release(hid) }
                try hid.sendReport(
                    surface: HIDService.keyboardSurface, report: HIDService.keyboardReport(usages: []))
            } catch {
                // A dead tunnel shouldn't hand the next real command a broken session (PITFALLS #62).
                SessionPool.drop()
                FileHandle.standardError.write(Data("Keep-awake failed for \(key): \(error)\n".utf8))
            }
        }
    }

    private static var activeKeys: [String] {
        let now = Date()
        lastUsed = lastUsed.filter { now.timeIntervalSince($0.value) < window }
        return Array(lastUsed.keys)
    }
}
