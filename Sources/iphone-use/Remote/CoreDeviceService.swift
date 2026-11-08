import Foundation

/// Envelope for CoreDevice feature calls.
///
/// Every request is wrapped as `{CoreDevice.featureIdentifier, CoreDevice.input, ...}`. On success
/// the result is in `CoreDevice.output`; on failure the reason is in `CoreDevice.error`.
struct CoreDeviceService {
    let connection: RemoteXPCConnection

    enum Failure: Error, CustomStringConvertible {
        case invocationFailed(feature: String, detail: String)

        var description: String {
            switch self {
            case .invocationFailed(let feature, let detail):
                return "\(feature) call failed: \(detail)"
            }
        }
    }

    /// The version devicectl introduces itself with. Too low and the daemon refuses.
    private static let coreDeviceVersion = XPCObject.dictionary([
        "components": .array([.uint64(629), .uint64(3)]),
        "originalComponentsCount": .int64(2),
        "stringValue": .string("629.3"),
    ])

    func invoke(
        _ feature: String, action: String? = nil, input: [String: XPCObject] = [:],
        timeout: TimeInterval = 15
    ) throws -> [String: XPCObject] {
        guard
            let output = try invokeRaw(feature, action: action, input: input, timeout: timeout)
                .dictionaryValue
        else {
            throw Failure.invocationFailed(feature: feature, detail: "output is not a dictionary")
        }
        return output
    }

    /// Accepts any output shape. Some features, like `listapps`, return an array.
    ///
    /// `action` picks among several actions under one feature. Settings features work like this —
    /// `customizeuistyle` has `getuserinterfacestyle`/`setuserinterfacestyle`, and without an
    /// action the default (usually get) runs. **Unknown input keys are silently ignored**, so if you
    /// mean set but forget the action, you get the current value back with no error.
    func invokeRaw(
        _ feature: String, action: String? = nil, input: [String: XPCObject] = [:],
        timeout: TimeInterval = 15
    ) throws -> XPCObject {
        var envelope: [String: XPCObject] = [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(2),
            "CoreDevice.coreDeviceVersion": Self.coreDeviceVersion,
            "CoreDevice.deviceIdentifier": .string(UUID().uuidString),
            "CoreDevice.featureIdentifier": .string(feature),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
        ]
        if let action { envelope["CoreDevice.actionIdentifier"] = .string(action) }
        let response = try connection.sendReceive(envelope, timeout: timeout)

        guard let output = response["CoreDevice.output"] else {
            var detail = "\(response.mapValues { $0.jsonReady })"
            if let error = response["CoreDevice.error"]?.dictionaryValue,
                let userInfo = error["userInfo"]?.dictionaryValue,
                let message = userInfo["NSLocalizedDescription"]?.stringValue
            {
                detail = message
            }
            throw Failure.invocationFailed(feature: feature, detail: detail)
        }
        return output
    }
}

/// Screen size in pixels. Needed to convert pixel coordinates to HID's 0..65535.
struct ScreenSize {
    let width: Double
    let height: Double
    /// How far the screenshot is turned from the touch panel: `nativeOrientation` plus
    /// `currentOrientation`. iPhone is `rot0`, iPad is `rot270`.
    ///
    /// Screenshots are in screen buffer space (iPad: landscape 2420×1668), but touch coordinates are in
    /// the panel's native orientation (iPad: portrait). Send them unrotated and the wrong spot gets
    /// tapped (PITFALLS #23). The foldable's inner panel also turns with the UI, which
    /// `currentOrientation` reports (PITFALLS #51).
    var rotation = "rot0"

    static let normalizedMax = 65535.0

    /// The panel's `uniqueId`, passed to `capturescreenshot` as `displayUniqueID` so the screenshot
    /// comes from the same panel. nil if the device doesn't report one.
    var displayID: String?
    /// The panel's HID touchscreen surface (`HIDService.touchSurface`).
    ///
    /// Touchscreens are numbered from 257 in the order `getdisplayinfo` lists the panels: on the foldable
    /// iPhone the cover panel is 257 and the inner one 258, each tagged with its panel's `displayUUID`.
    /// The HID surface list would say so directly, but asking for it stalls HID input for minutes
    /// (PITFALLS #15), so the order is assumed (PITFALLS #51).
    var touchSurface = HIDService.mainTouchscreen

    /// Asks the device for the size of the panel that is lit now.
    ///
    /// The foldable iPhone has two panels and lists the cover one first even while it is unfolded and
    /// the cover is off, so take the `active` one, not the first (PITFALLS #51). Falls back to the
    /// first panel with a size when none is active (screen off).
    static func query(rsd: RemoteServiceDiscovery) throws -> ScreenSize {
        let connection = try rsd.connect(to: "com.apple.coredevice.deviceinfo")
        defer { connection.close() }

        let output = try CoreDeviceService(connection: connection)
            .invoke("com.apple.coredevice.feature.getdisplayinfo")

        // Wireless/TV-out entries come back with zero bounds; skip them.
        var panels: [(screen: ScreenSize, active: Bool)] = []
        for display in output["displays"]?.arrayValue ?? [] {
            guard let entry = display.dictionaryValue,
                let bounds = entry["bounds"]?.arrayValue, bounds.count >= 2,
                let size = bounds[1].arrayValue, size.count >= 2,
                case .double(let width) = size[0], case .double(let height) = size[1],
                width > 0, height > 0
            else { continue }
            // `bounds` stays in the panel's frame while the screenshot follows the UI: the foldable's inner
            // panel held sideways reports rot90 and 2007x2853, and captures 2853x2007 (PITFALLS #51).
            let current = quarterTurns(entry["currentOrientation"]?.stringValue)
            let native = quarterTurns(entry["nativeOrientation"]?.stringValue)
            var screen =
                current % 2 == 0
                ? ScreenSize(width: width, height: height) : ScreenSize(width: height, height: width)
            screen.rotation = "rot\((current + native) % 4 * 90)"
            screen.displayID = entry["uniqueId"]?.stringValue
            screen.touchSurface = HIDService.mainTouchscreen + UInt64(panels.count)
            panels.append((screen, entry["active"]?.boolValue ?? false))
        }
        guard let screen = (panels.first { $0.active } ?? panels.first)?.screen else {
            throw CoreDeviceService.Failure.invocationFailed(
                feature: "getdisplayinfo", detail: "could not find the screen size")
        }
        return screen
    }

    /// "rot90" -> 1. Unknown or missing counts as 0.
    private static func quarterTurns(_ orientation: String?) -> Int {
        ["rot0": 0, "rot90": 1, "rot180": 2, "rot270": 3][orientation ?? ""] ?? 0
    }

    /// Pixel coordinates -> HID normalized coordinates, rotated by `rotation`.
    ///
    /// The `rot270` formula was verified on an iPad (iOS 26.6) by tapping the Settings icon, and `rot90`
    /// on the foldable iPhone's inner panel held sideways (iOS 27.3). `rot180` follows the same rule and
    /// hasn't been checked on hardware.
    func normalize(x: Double, y: Double) -> (x: Int, y: Int) {
        let u = min(max(x / width, 0), 1)
        let v = min(max(y / height, 0), 1)
        let (dx, dy): (Double, Double) =
            switch rotation {
            case "rot90": (v, 1 - u)
            case "rot180": (1 - u, 1 - v)
            case "rot270": (1 - v, u)
            default: (u, v)
            }
        return (Int((dx * Self.normalizedMax).rounded()), Int((dy * Self.normalizedMax).rounded()))
    }
}
