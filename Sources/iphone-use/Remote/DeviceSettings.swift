import Foundation

/// Device Hub's settings panel (appearance, text size, accessibility toggles, VoiceOver, Liquid Glass)
/// and location simulation.
///
/// All are features of the `com.apple.coredevice.configuration` service, with separate get/set
/// **actions** under each feature (`CoreDevice.actionIdentifier`). Without an action, get runs and the
/// input is ignored — if a set seems silently ignored, check the action name first.
/// Input and output have the same shape: `{"reduceMotion": {"enabled": true}}`.
enum DeviceSettings {
    private static let service = "com.apple.coredevice.configuration"
    private static let appearanceFeature = "com.apple.coredevice.feature.customizeappearancesettings"
    private static let actionPrefix = "com.apple.coredevice.action."

    /// Items that are just on/off. (CLI name, action suffix, input/output key)
    struct Toggle {
        let name: String
        let action: String
        let key: String
    }

    static let toggles = [
        Toggle(name: "reduce-motion", action: "reducemotion", key: "reduceMotion"),
        Toggle(name: "increase-contrast", action: "deviceincreasecontrast", key: "increaseContrast"),
        Toggle(name: "show-borders", action: "showborders", key: "showBorders"),
        Toggle(name: "reduce-transparency", action: "reducetransparency", key: "reduceTransparency"),
        Toggle(name: "voiceover", action: "voiceover", key: "voiceOverConfiguration"),
    ]

    /// Text sizes. The device's names (same order as UIContentSizeCategory) and short aliases.
    static let textSizes: [(name: String, alias: String)] = [
        ("extraSmall", "xs"), ("small", "s"), ("medium", "m"), ("large", "l"),
        ("extraLarge", "xl"), ("extraExtraLarge", "xxl"), ("extraExtraExtraLarge", "xxxl"),
        ("accessibilityMedium", "ax1"), ("accessibilityLarge", "ax2"),
        ("accessibilityExtraLarge", "ax3"), ("accessibilityExtraExtraLarge", "ax4"),
        ("accessibilityExtraExtraExtraLarge", "ax5"),
    ]

    static func textSize(named text: String) -> String? {
        textSizes.first { $0.alias == text.lowercased() || $0.name.lowercased() == text.lowercased() }?
            .name
    }

    // MARK: - Reading

    /// Current values for the whole panel, in a shape that can be printed as JSON directly.
    /// Items the device doesn't support are skipped and their names collected in `unsupported`.
    /// An iPad (iOS 26.6) rejected the Liquid Glass read with "not supported on this device"; if one
    /// failure failed the whole thing, none of the other values would be visible.
    static func current(rsd: RemoteServiceDiscovery) throws -> [String: Any] {
        try withService(rsd) { call in
            var state: [String: Any] = [:]
            var unsupported: [String] = []
            func read(_ name: String, _ body: () throws -> Void) {
                do { try body() } catch { unsupported.append(name) }
            }

            read("style") { state["style"] = try call("getuserinterfacestyle", [:])["style"]?.stringValue }

            // `{"textSize": {"size": {"large": {}}}}` — the size is an enum case with no associated value, so it arrives as a key.
            read("textSize") {
                state["textSize"] = try call("getdevicetextsize", [:])["textSize"]?.dictionaryValue?["size"]?
                    .dictionaryValue?.keys.first
            }

            for toggle in toggles {
                read(toggle.name) {
                    let output = try call("get" + toggle.action, [:])
                    state[toggle.name] = output[toggle.key]?.dictionaryValue?["enabled"]?.boolValue
                }
            }

            read("liquidGlass") {
                let glass = try call("getliquidglassconfiguration", [:])["configuration"]?
                    .dictionaryValue?["opacity"]
                // It comes from a Float, so it prints like 0.800000011920929. Round to two decimals.
                if case .double(let opacity)? = glass {
                    // Left as a Double, JSONSerialization prints 0.80000000000000004.
                    state["liquidGlass"] = NSDecimalNumber(string: String(format: "%.2f", opacity))
                }
            }
            if !unsupported.isEmpty { state["unsupported"] = unsupported }
            return state
        }
    }

    // MARK: - Writing

    static func set(
        rsd: RemoteServiceDiscovery,
        style: String? = nil, textSize: String? = nil, toggles values: [String: Bool] = [:],
        liquidGlass: Double? = nil
    ) throws {
        try withService(rsd) { call in
            if let style {
                _ = try call("setuserinterfacestyle", ["style": .string(style)])
            }
            if let textSize {
                _ = try call(
                    "setdevicetextsize",
                    ["textSize": .dictionary(["size": .dictionary([textSize: .dictionary([:])])])])
            }
            for toggle in toggles {
                guard let enabled = values[toggle.name] else { continue }
                _ = try call(
                    "set" + toggle.action,
                    [toggle.key: .dictionary(["enabled": .bool(enabled)])])
            }
            if let liquidGlass {
                // The device-side type is Float, so a Double that isn't exactly a Float (0.8, etc.)
                // is rejected with "value doesn't fit in Float". Truncate to Float first.
                let opacity = Double(Float(liquidGlass))
                _ = try call(
                    "setliquidglassconfiguration",
                    ["configuration": .dictionary(["opacity": .double(opacity)])])
            }
        }
    }

    // MARK: - Location

    private static let locationService = "com.apple.coredevice.locationservice"
    private static let locationFeature = "com.apple.coredevice.feature.simulatelocation"

    /// Pins the whole device's location to these coordinates. Stays until `clearLocation`.
    static func simulateLocation(rsd: RemoteServiceDiscovery, latitude: Double, longitude: Double)
        throws
    {
        let connection = try rsd.connect(to: locationService)
        defer { connection.close() }
        _ = try CoreDeviceService(connection: connection).invoke(
            locationFeature, action: actionPrefix + "setsimulatedlocation",
            input: ["latitude": .double(latitude), "longitude": .double(longitude)])
    }

    static func clearLocation(rsd: RemoteServiceDiscovery) throws {
        let connection = try rsd.connect(to: locationService)
        defer { connection.close() }
        _ = try CoreDeviceService(connection: connection).invoke(
            locationFeature, action: actionPrefix + "clearsimulatedlocation")
    }

    // MARK: -

    /// Passes in a function that calls an action. **Opens a new connection per call** — this service
    /// closes the connection right after replying, so a second request on the same one fails with "connection lost".
    private static func withService<T>(
        _ rsd: RemoteServiceDiscovery,
        _ body: (_ call: (String, [String: XPCObject]) throws -> [String: XPCObject]) throws -> T
    ) throws -> T {
        try body { action, input in
            let connection = try rsd.connect(to: service)
            defer { connection.close() }
            return try CoreDeviceService(connection: connection)
                .invoke(appearanceFeature, action: actionPrefix + action, input: input)
        }
    }
}
