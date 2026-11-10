import Foundation

/// Installed app list. Uses lockdown's `com.apple.mobile.installation_proxy` (`LockdownShim`) where it
/// opens, and `devicectl device info apps` where it doesn't.
///
/// installation_proxy gives display names in the device's language ("설정" for Settings), which is what
/// `launch <name>` matches against. Over USB it's started with MobileDevice. Over Wi-Fi its
/// `.shim.remote` copy can't be opened anymore: CoreDeviceService refuses lockdown shims, so the
/// fallback to devicectl gives the bundle names instead (English "Settings"). CoreDevice
/// `appservice`'s `listapps` never answers once an app matches (PITFALLS #20).
enum InstallationProxy {
    struct App {
        let bundleId: String
        let name: String
        let type: String
        /// System services not shown on the home screen (`hidden` in `SBAppTags`). There were six
        /// named "Settings" alone — if these aren't excluded when matching by name, nothing can be picked.
        let hidden: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case service(String)
        case noSuchApp(String)
        case ambiguous(String, [App])

        var description: String {
            switch self {
            case .service(let detail): return "installation_proxy error: \(detail)"
            case .noSuchApp(let name):
                return "No app named \"\(name)\". Look it up with `apps --filter` (over Wi-Fi the names are the apps' own names, often English, e.g. Settings) and launch it by bundle ID."
            case .ambiguous(let name, let apps):
                let list = apps.prefix(10).map { "  \($0.name)  \($0.bundleId)" }
                return "More than one app matches \"\(name)\" exactly. Give the full name or the bundle ID:\n"
                    + list.joined(separator: "\n")
            }
        }
    }

    /// A bundle ID passes through; otherwise look up the bundle ID from the app name shown on screen.
    ///
    /// Agents often know a name like "Settings" or a messenger app's name but not the bundle ID. The
    /// name is the display name in the device's language, and only home-screen apps are considered.
    /// It launches **only on a full-name match** — accepting partial matches once opened Print Center
    /// from a single character. Partial matches only show the candidates.
    static func bundleId(for nameOrBundle: String, rsd: RemoteServiceDiscovery) throws -> String {
        // If it looks like a dotted identifier, treat it as a bundle ID and skip the list (saves 0.7 s).
        if nameOrBundle.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression)
            != nil
        {
            // With a single dot it can be an app's name too ("Name.com"): launched as a
            // bundle ID it only said "The application failed to launch" (PITFALLS #65). Bundle IDs
            // nearly always have three parts or more, so only these pay for the list.
            guard nameOrBundle.filter({ $0 == "." }).count == 1 else { return nameOrBundle }
            let named = try browse(rsd: rsd, includeSystem: true).filter {
                !$0.hidden && $0.name.caseInsensitiveCompare(nameOrBundle) == .orderedSame
            }
            return named.count == 1 ? named[0].bundleId : nameOrBundle
        }

        let apps = try browse(rsd: rsd, includeSystem: true).filter { !$0.hidden }
        let needle = nameOrBundle.lowercased().filter { !$0.isWhitespace }
        let key = { (app: App) in app.name.lowercased().filter { !$0.isWhitespace } }

        let exact = apps.filter { key($0) == needle }
        if exact.count == 1 { return exact[0].bundleId }
        if exact.count > 1 { throw Failure.ambiguous(nameOrBundle, exact) }

        let partial = apps.filter { key($0).contains(needle) }
        guard !partial.isEmpty else { throw Failure.noSuchApp(nameOrBundle) }
        throw Failure.ambiguous(nameOrBundle, partial)
    }

    /// With `includeSystem` false, only user-installed apps.
    static func browse(rsd: RemoteServiceDiscovery, includeSystem: Bool) throws -> [App] {
        do {
            return try browseLockdown(rsd: rsd, includeSystem: includeSystem)
        } catch {
            // Caught rather than passed on: the shim error says "connection", and the daemon would drop
            // its healthy session over it (`DaemonCommand`).
            do {
                return try browseDeviceCtl(udid: rsd.udid, includeSystem: includeSystem)
            } catch let fallback {
                throw Failure.service("\(error); devicectl: \(fallback)")
            }
        }
    }

    /// `devicectl device info apps`. Names are bundle names, not the device's display names, and
    /// services hidden from the home screen are already left out.
    static func browseDeviceCtl(udid: String, includeSystem: Bool) throws -> [App] {
        // Without --include-all-apps only apps built by a developer come back, not ones from the App Store.
        let json = try DeviceCtl.json(["device", "info", "apps", "--device", udid, "--include-all-apps"])
        let apps = ((json as? [String: Any])?["result"] as? [String: Any])?["apps"] as? [[String: Any]] ?? []
        return apps.compactMap { entry in
            guard let bundle = entry["bundleIdentifier"] as? String else { return nil }
            // `defaultApp` is Apple's own apps (App Store included); third-party apps are false.
            let system = entry["defaultApp"] as? Bool ?? false
            if !includeSystem, system { return nil }
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return App(
                bundleId: bundle, name: name.isEmpty ? bundle : name, type: system ? "System" : "User",
                hidden: entry["hidden"] as? Bool ?? false)
        }
    }

    private static func browseLockdown(rsd: RemoteServiceDiscovery, includeSystem: Bool) throws -> [App] {
        let socket = try LockdownShim.open("com.apple.mobile.installation_proxy", rsd: rsd)
        defer { socket.shutdownAndClose() }
        socket.setReceiveTimeout(20)

        var options: [String: Any] = [
            "ReturnAttributes": [
                "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "ApplicationType",
                "SBAppTags",
            ]
        ]
        if !includeSystem { options["ApplicationType"] = "User" }
        try LockdownShim.send(["Command": "Browse", "ClientOptions": options], on: socket)

        // The list arrives in several messages (`Status: BrowsingApplications`). `Complete` ends it.
        var apps: [App] = []
        while true {
            let reply = try LockdownShim.receive(from: socket)
            if let error = reply["Error"] {
                throw Failure.service("\(error) \(reply["ErrorDescription"] ?? "")")
            }
            for entry in reply["CurrentList"] as? [[String: Any]] ?? [] {
                guard let bundle = entry["CFBundleIdentifier"] as? String else { continue }
                // Some apps (folder/widget apps) have a single space as the display name. Fall back to the next candidate.
                let name =
                    [entry["CFBundleDisplayName"], entry["CFBundleName"]]
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? bundle
                let tags = entry["SBAppTags"] as? [String] ?? []
                apps.append(
                    App(
                        bundleId: bundle, name: name, type: entry["ApplicationType"] as? String ?? "",
                        hidden: tags.contains("hidden")))
            }
            if reply["Status"] as? String == "Complete" { break }
        }
        return apps
    }
}
