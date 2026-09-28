import ArgumentParser
import Foundation

/// Installed apps. installation_proxy is reached through the tunnel, so USB and Wi-Fi behave the same (`InstallationProxy`).
struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List installed apps."
    )

    @OptionGroup var device: DeviceOptions

    @Flag(name: .long, help: "Include system apps (implied by --filter).")
    var all = false

    @Flag(name: .long, help: "Also include system services that don't appear on the Home Screen.")
    var hidden = false

    @Option(name: .long, help: "Only apps whose name or bundle ID contains this string (case-insensitive).")
    var filter: String?

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        // Compare with whitespace stripped. The display name of "App Store" contains a no-break space
        // (U+00A0), so a plain contains didn't match "app store".
        let squash = { (text: String) in text.lowercased().filter { !$0.isWhitespace } }
        let needle = filter.map(squash)
        let rows =
            // When searching by name, include system apps (App Store, Settings, ...) too — an agent looking
            // for "App Store" once got an empty list and guessed the bundle ID.
            try InstallationProxy.browse(rsd: rsd, includeSystem: all || hidden || filter != nil)
            .filter { hidden || !$0.hidden }
            .filter { app in
                guard let needle else { return true }
                return squash(app.bundleId).contains(needle) || squash(app.name).contains(needle)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ["bundleId": $0.bundleId, "name": $0.name] }

        let data = try JSONSerialization.data(
            withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// Launches an app and brings it to the foreground.
struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an app (bundle ID or app name)."
    )

    @OptionGroup var device: DeviceOptions

    @OptionGroup var shot: ShotOptions

    @Argument(help: "Bundle ID (com.apple.Preferences) or the app name shown on the Home Screen (Settings).")
    var app: String

    @Flag(name: .long, help: "If it's already running, kill it and launch fresh.")
    var restart = false

    @Flag(name: .long, help: "Don't fetch the accessibility list (ui) after launching.")
    var noUi = false

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        let bundleId = try InstallationProxy.bundleId(for: app, rsd: rsd)
        let pid = try AppService.launch(rsd: rsd, bundleId: bundleId, restart: restart)
        print("Launched \(bundleId) (pid \(pid))")
        try shot.capture(after: nil, udid: device.udid)
        if !noUi { UIScreen.report(afterActionOn: device.udid) }
    }
}

/// Opens a URL. A deep link is the cheapest and most reliable way to jump straight to a specific screen.
///
/// e.g. `open "prefs:root=Bluetooth"`, `open "https://example.com"`, `open "tel:..."`.
struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a URL (deep link) on the device."
    )

    @OptionGroup var device: DeviceOptions

    @OptionGroup var shot: ShotOptions

    @Argument(help: "URL to open.")
    var url: String

    @Option(name: .long, help: "Hand the URL to this app (bundle ID or name). If omitted, the system picks.")
    var app: String?

    @Flag(name: .long, help: "Don't fetch the accessibility list (ui) after opening.")
    var noUi = false

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        if let app {
            try AppService.launch(
                rsd: rsd, bundleId: InstallationProxy.bundleId(for: app, rsd: rsd), url: url)
        } else {
            try AppService.open(rsd: rsd, url: url)
        }
        print("Opened \(url)")
        try shot.capture(after: nil, udid: device.udid)
        if !noUi { UIScreen.report(afterActionOn: device.udid) }
    }
}
