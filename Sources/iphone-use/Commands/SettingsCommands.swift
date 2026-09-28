import ArgumentParser
import Foundation

/// The Device Hub settings panel. Without arguments, prints the current values as JSON.
///
/// Changes are the device's real settings (same as changing them in Settings). Restore them when done.
struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "View or change appearance, text size, accessibility toggles and VoiceOver.",
        discussion: """
            Without options, prints the current values as JSON. With options, changes them and prints the result.

            With VoiceOver on, a tap becomes "select", so touch/swipe don't behave as usual.
            Use this command to turn it off too (--voiceover off).
            """
    )

    enum Switch: String, ExpressibleByArgument {
        case on, off
        var enabled: Bool { self == .on }
    }

    enum Style: String, ExpressibleByArgument {
        case light, dark
    }

    @OptionGroup var device: DeviceOptions

    @Option(name: .long, help: "Appearance: light, dark.")
    var style: Style?

    @Option(
        name: .long,
        help: """
            Text size: \(DeviceSettings.textSizes.map(\.alias).joined(separator: ", ")) \
            (default is l). Device names (extraLarge etc.) also work.
            """)
    var textSize: String?

    @Option(name: .long, help: "Reduce Motion: on, off.")
    var reduceMotion: Switch?

    @Option(name: .long, help: "Increase Contrast: on, off.")
    var increaseContrast: Switch?

    @Option(name: .long, help: "Show Borders (Button Shapes): on, off.")
    var showBorders: Switch?

    @Option(name: .long, help: "Reduce Transparency: on, off.")
    var reduceTransparency: Switch?

    @Option(name: .long, help: "VoiceOver: on, off.")
    var voiceover: Switch?

    @Option(name: .long, help: "Liquid Glass opacity (0-1, default 0.5).")
    var liquidGlass: Double?

    func validate() throws {
        if let textSize, DeviceSettings.textSize(named: textSize) == nil {
            throw ValidationError("Unknown text size: \(textSize)")
        }
        if let liquidGlass, !(0...1).contains(liquidGlass) {
            throw ValidationError("--liquid-glass must be between 0 and 1.")
        }
    }

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        var toggles: [String: Bool] = [:]
        for (name, value) in [
            ("reduce-motion", reduceMotion), ("increase-contrast", increaseContrast),
            ("show-borders", showBorders), ("reduce-transparency", reduceTransparency),
            ("voiceover", voiceover),
        ] {
            if let value { toggles[name] = value.enabled }
        }

        let changing =
            style != nil || textSize != nil || !toggles.isEmpty || liquidGlass != nil
        if changing {
            try DeviceSettings.set(
                rsd: rsd, style: style?.rawValue,
                textSize: textSize.flatMap(DeviceSettings.textSize(named:)),
                toggles: toggles, liquidGlass: liquidGlass)
        }

        let data = try JSONSerialization.data(
            withJSONObject: try DeviceSettings.current(rsd: rsd),
            options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// Location simulation. Changes the location for the whole device (all apps).
struct LocationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location",
        abstract: "Pin the device location to coordinates, or restore it (--clear).",
        discussion: """
            Stays until cleared. Always restore it with `location --clear` when done.
            """
    )

    @OptionGroup var device: DeviceOptions

    /// Takes unrecognized dash arguments too and parses them here, so a negative coordinate (`-122.0`) isn't mistaken for an option.
    @Argument(parsing: .allUnrecognized, help: "Latitude longitude (e.g. 37.3349 -122.009).")
    var coordinates: [String] = []

    @Flag(name: .long, help: "Stop simulating and return to the real location.")
    var clear = false

    private var point: (latitude: Double, longitude: Double)? {
        guard coordinates.count == 2, let latitude = Double(coordinates[0]),
            let longitude = Double(coordinates[1])
        else { return nil }
        return (latitude, longitude)
    }

    func validate() throws {
        if clear { return }
        guard let point else {
            throw ValidationError("Give a latitude and longitude, or use --clear.")
        }
        guard (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else {
            throw ValidationError("Coordinates out of range.")
        }
    }

    func run() throws {
        let rsd = try SessionPool.rsd(udid: device.udid)
        defer { SessionPool.release(rsd) }

        if clear {
            try DeviceSettings.clearLocation(rsd: rsd)
            print("Location simulation cleared")
        } else if let point {
            try DeviceSettings.simulateLocation(
                rsd: rsd, latitude: point.latitude, longitude: point.longitude)
            print("Location pinned (\(point.latitude), \(point.longitude))")
        }
    }
}
