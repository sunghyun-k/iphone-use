import Foundation

/// Installed app list. Uses lockdown's `com.apple.mobile.installation_proxy` through the tunnel shim.
///
/// Why not CoreDevice `appservice`'s `listapps`: it only answered when the result was empty, and with
/// even one app matched it never answered over Wi-Fi. `devicectl device info apps` tries to grab Wi-Fi
/// devices via MobileDevice and dies with `Failed to allocate RSD device`. installation_proxy dates
/// back to the lockdown era and answers in the same shape over USB and Wi-Fi.
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
                return "No app named \"\(name)\". Look it up with `apps --all --filter`."
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
            return nameOrBundle
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
