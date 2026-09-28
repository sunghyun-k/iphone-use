import ArgumentParser
import Foundation

/// Connected devices, USB and Wi-Fi together.
///
/// Merges two sources.
/// - `remotepairingd`: devices reachable through a tunnel. Both USB and Wi-Fi show up here. This is what
///   the tool's screen/input path uses.
/// - MobileDevice: sees **USB only**; Wi-Fi devices don't appear at all. Also consulted so a USB device
///   whose tunnel isn't up yet isn't missed.
struct DevicesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List connected devices (USB and Wi-Fi)."
    )

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    /// Accepted like on other commands. If given, shows only that device (UDID or name).
    @OptionGroup var device: DeviceOptions

    func run() throws {
        var rows: [[String: String]] = []

        for info in RemotePairingTunnel.devices() {
            guard let udid = info["udid"] as? String else { continue }
            let state = info["connectionState"] as? [String: Any]
            let connected = state?["value"] as? [String: Any]
            let physical = connected?["attachedPhysically"] as? Bool ?? false

            var row = ["udid": udid, "transport": physical ? "usb" : "wifi"]
            row["name"] = info["name"] as? String
            row["model"] = info["model"] as? String
            // Read from device properties remoted already has. Doesn't query the device again.
            if let rsd = connected?["rsdDeviceInfo"] as? [String: Any],
                let uuid = rsd["uuid"] as? String
            {
                row["osVersion"] = Self.remoteProperty(uuid, "OSVersion")
            }
            rows.append(row)
        }

        // USB devices not visible through a tunnel (older iOS etc.). The list must still work without MobileDevice.
        let known = Set(rows.compactMap { $0["udid"]?.uppercased() })
        for device in (try? DeviceDiscovery.connectedDevices()) ?? [] {
            guard let udid = device.udid, !known.contains(udid.uppercased()) else { continue }
            var row = ["udid": udid, "transport": "usb"]
            try? device.withSession { connected in
                for (key, field) in [
                    ("DeviceName", "name"), ("ProductType", "model"), ("ProductVersion", "osVersion"),
                ] {
                    if let value = connected.value(for: key) as? String { row[field] = value }
                }
            }
            rows.append(row)
        }

        // Wi-Fi devices have no properties in remoted (without a tunnel up there's no `rsdDeviceInfo` at
        // all), so the version is empty. CoreDevice keeps the last seen version, so fill it from the
        // devicectl list (~0.2 s).
        if rows.contains(where: { $0["osVersion"] == nil }) {
            let known = Self.coreDeviceVersions()
            for index in rows.indices where rows[index]["osVersion"] == nil {
                rows[index]["osVersion"] = rows[index]["udid"].flatMap { known[$0.uppercased()] }
            }
        }

        if let wanted = device.udid {
            rows = rows.filter {
                $0["udid"]?.caseInsensitiveCompare(wanted) == .orderedSame
                    || $0["name"]?.caseInsensitiveCompare(wanted) == .orderedSame
            }
        }

        if json {
            let data = try JSONSerialization.data(
                withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard !rows.isEmpty else {
            FileHandle.standardError.write(Data("No connected devices.\n".utf8))
            return
        }
        for row in rows {
            print(
                [
                    row["udid"] ?? "?", row["name"] ?? "?", row["model"] ?? "?",
                    "iOS \(row["osVersion"] ?? "?")", row["transport"] ?? "?",
                ].joined(separator: "  "))
        }
    }

    /// UDID -> OS version as known to `devicectl list devices`. Empty if Xcode is missing or it fails.
    private static func coreDeviceVersions() -> [String: String] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-devices-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "-q", "--json-output", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        process.waitUntilExit()

        guard let data = try? Data(contentsOf: output),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = json["result"] as? [String: Any],
            let devices = result["devices"] as? [[String: Any]]
        else { return [:] }

        var versions: [String: String] = [:]
        for entry in devices {
            let hardware = entry["hardwareProperties"] as? [String: Any]
            let properties = entry["deviceProperties"] as? [String: Any]
            if let udid = hardware?["udid"] as? String,
                let version = properties?["osVersionNumber"] as? String
            {
                versions[udid.uppercased()] = version
            }
        }
        return versions
    }

    private static func remoteProperty(_ uuid: String, _ key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/remotectl")
        process.arguments = ["get-property", uuid, key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !value.isEmpty ? value : nil
    }
}
