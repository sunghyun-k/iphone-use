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
    /// The panel's native orientation (`nativeOrientation`). iPhone is `rot0`, iPad is `rot270`.
    ///
    /// Screenshots and `bounds` are in screen buffer space (iPad: landscape 2420×1668), but touch
    /// coordinates are in the panel's native orientation (iPad: portrait). Send them unrotated and the wrong spot gets tapped (PITFALLS #23).
    var rotation = "rot0"

    static let normalizedMax = 65535.0

    /// Asks the device for its current screen size.
    static func query(rsd: RemoteServiceDiscovery) throws -> ScreenSize {
        let connection = try rsd.connect(to: "com.apple.coredevice.deviceinfo")
        defer { connection.close() }

        let output = try CoreDeviceService(connection: connection)
            .invoke("com.apple.coredevice.feature.getdisplayinfo")

        // Several displays may come back — the one with `current: true` is the built-in screen.
        let displays = output["displays"]?.arrayValue ?? []
        for display in displays {
            guard let entry = display.dictionaryValue,
                let bounds = entry["bounds"]?.arrayValue, bounds.count >= 2,
                let size = bounds[1].arrayValue, size.count >= 2,
                case .double(let width) = size[0], case .double(let height) = size[1],
                width > 0, height > 0
            else { continue }
            var screen = ScreenSize(width: width, height: height)
            screen.rotation = entry["nativeOrientation"]?.stringValue ?? "rot0"
            return screen
        }
        throw CoreDeviceService.Failure.invocationFailed(
            feature: "getdisplayinfo", detail: "could not find the screen size")
    }

    /// Pixel coordinates -> HID normalized coordinates, rotated by `rotation`.
    ///
    /// The `rot270` formula was verified on an iPad (iOS 26.6) by tapping the Settings icon. The other
    /// two follow the same rule and haven't been checked on hardware.
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
