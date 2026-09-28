import Foundation

/// Launching apps and opening URLs. This is CoreDevice `appservice`'s `launchapplication`.
///
/// We talk to it directly instead of calling devicectl. devicectl tries to grab Wi-Fi devices via
/// MobileDevice and dies with `Failed to allocate RSD device`. The feature itself works fine over Wi-Fi.
enum AppService {
    static let serviceName = "com.apple.coredevice.appservice"
    private static let launchFeature = "com.apple.coredevice.feature.launchapplication"
    /// Target for opening a bare URL. Send the URL to SpringBoard and LaunchServices hands it to
    /// whichever app handles it. An empty bundle ID is rejected with "The application failed to launch."
    private static let urlRouter = "com.apple.springboard"
    /// The daemon that runs appservice on the device.
    private static let daemonName = "dtappserviced"

    /// Launches the app (or brings it to the front if already running) and returns its pid.
    /// With `url`, the URL is handed to that app (deep link).
    @discardableResult
    static func launch(
        rsd: RemoteServiceDiscovery, bundleId: String, url: String? = nil, restart: Bool = false
    ) throws -> Int {
        var options: [String: XPCObject] = [
            "arguments": .array([]),
            "environmentVariables": .dictionary([:]),
            "standardIOUsesPseudoterminals": .bool(false),
            "startStopped": .bool(false),
            "terminateExisting": .bool(restart),
            "user": .dictionary(["shortName": .string("mobile")]),
            // The key must exist even when empty, and the value must be a binary plist.
            "platformSpecificOptions": .data(emptyBinaryPlist),
        ]
        // The Codable shape of Swift `URL`. A plain string gets "dictionary required here".
        if let url { options["payloadURL"] = .dictionary(["relative": .string(encoded(url))]) }

        let input: [String: XPCObject] = [
            "applicationSpecifier": .dictionary([
                "bundleIdentifier": .dictionary(["_0": .string(bundleId)])
            ]),
            "options": .dictionary(options),
            "standardIOIdentifiers": .dictionary([:]),
        ]

        let output = try invokeRecovering(rsd: rsd, input: input)
        guard let token = output["processToken"]?.dictionaryValue,
            let pid = token["processIdentifier"]?.intValue
        else {
            throw CoreDeviceService.Failure.invocationFailed(
                feature: launchFeature, detail: "no pid in the response")
        }
        return pid
    }

    /// Opens the URL in the device's default handler. The returned pid is SpringBoard's.
    @discardableResult
    static func open(rsd: RemoteServiceDiscovery, url: String) throws -> Int {
        try launch(rsd: rsd, bundleId: urlRouter, url: url)
    }

    /// Running processes: pid -> executable path.
    ///
    /// The first 4 bytes of an accessibility element token are the owning app's pid (little endian),
    /// so this tells us which app is on screen, or whether it's the home screen (SpringBoard).
    static func processes(rsd: RemoteServiceDiscovery) throws -> [Int: String] {
        let connection = try rsd.connect(to: serviceName)
        defer { connection.close() }
        let output = try CoreDeviceService(connection: connection)
            .invoke("com.apple.coredevice.feature.listprocesses", timeout: 8)
        var result: [Int: String] = [:]
        func collect(_ value: XPCObject) {
            if let entry = value.dictionaryValue {
                if let pid = entry["processIdentifier"]?.intValue {
                    let path = entry["executableURL"]?.dictionaryValue?["relative"]?.stringValue ?? ""
                    result[pid] = path
                }
                entry.values.forEach(collect)
            } else if let items = value.arrayValue {
                items.forEach(collect)
            }
        }
        output.values.forEach(collect)
        return result
    }

    /// After one timeout, kill `dtappserviced` on the device and retry.
    ///
    /// Once this daemon gets stuck, it accepts every later call and never answers. It still replies
    /// right away to input decoding errors, so it looks alive, but real actions never come back.
    /// One confirmed cause is the app list feature (`listapps`), which never finishes when the result
    /// is non-empty (that's why the app list goes through `InstallationProxy`).
    /// It's a developer daemon that launchd respawns on demand, so killing it is invisible to the user.
    private static func invokeRecovering(rsd: RemoteServiceDiscovery, input: [String: XPCObject])
        throws -> [String: XPCObject]
    {
        func attempt() throws -> [String: XPCObject] {
            let connection = try rsd.connect(to: serviceName)
            defer { connection.close() }
            return try CoreDeviceService(connection: connection)
                .invoke(launchFeature, input: input, timeout: 8)
        }

        do {
            return try attempt()
        } catch RemoteXPCError.timeout {
            let hub = try InstrumentsHub(rsd: rsd)
            defer { hub.close() }
            for pid in try hub.pids(named: daemonName) { try hub.kill(pid: pid) }
            Thread.sleep(forTimeInterval: 0.5)
            return try attempt()
        }
    }

    private static let emptyBinaryPlist = try! PropertyListSerialization.data(
        fromPropertyList: [String: Any](), format: .binary, options: 0)

    /// Percent-encodes only characters that can't go into a URL as-is (Hangul, spaces). Existing `%XX` stays.
    ///
    /// When text can't be typed on the device (PITFALLS #11), putting the query in a URL is the easiest
    /// workaround, so agents can write `open "https://…/search?q=wallpaper"` without worrying about encoding.
    static func encoded(_ url: String) -> String {
        var allowed = CharacterSet(charactersIn: UnicodeScalar(0x21)...UnicodeScalar(0x7E))
        allowed.remove(charactersIn: "\"<>\\^`{|}")
        return url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
    }
}
