import Foundation

/// axAuditDaemon wire format.
///
/// Every value in this protocol is wrapped one layer at a time as `{"ObjectType": ..., "Value": ...}`.
/// Scalars/dictionaries are wrapped as `passthrough`, domain objects under a `<Class>_v1` name.
/// (The real `AXAuditElement` class lives in AccessibilityAudit.framework, but encoding goes through
/// `AXAuditObjectTransportManager`, so an instance can't simply be passed. Building the dictionary
/// ourselves has no dependency and is reliable.)
enum AXWire {
    static func passthrough(_ value: Any) -> [String: Any] {
        ["ObjectType": "passthrough", "Value": value]
    }

    /// Element handle. `PlatformElementValue_v1` is an opaque token the device gave us.
    ///
    /// Without one more wrapping layer around the token it leaks into a sibling key and every attribute
    /// comes back null (exactly the bug in pymobiledevice3 11.16.3).
    static func element(_ token: Data) -> [String: Any] {
        [
            "ObjectType": "AXAuditElement_v1",
            "Value": passthrough(["PlatformElementValue_v1": passthrough(token)]),
        ]
    }

    /// Attribute descriptor.
    ///
    /// The daemon seems to look only at the name and ignore the other fields, but actions only take
    /// with `PerformsActionValue_v1 = 1` / `ValueTypeValue_v1 = 1`.
    static func attribute(
        named name: String,
        humanReadable: String? = nil,
        performsAction: Int = 0,
        settable: Int = 0,
        valueType: Int = 2
    ) -> [String: Any] {
        let fields: [String: Any] = [
            "AttributeNameValue_v1": name,
            "HumanReadableNameValue_v1": humanReadable ?? name,
            "DisplayAsTree_v1": 0,
            "IsInternal_v1": 0,
            "PerformsActionValue_v1": performsAction,
            "SettableValue_v1": settable,
            "ValueTypeValue_v1": valueType,
        ]
        return [
            "ObjectType": "AXAuditElementAttribute_v1",
            "Value": passthrough(fields.mapValues { passthrough($0) }),
        ]
    }

    /// Action descriptor. `AXAction-2010` is VoiceOver's "activate" (tap).
    static func action(_ name: String, humanReadable: String) -> [String: Any] {
        attribute(named: name, humanReadable: humanReadable, performsAction: 1, valueType: 1)
    }

    /// A point. **Passed as a bare `NSValue(CGPoint)`, not wrapped in an envelope.**
    ///
    /// Wrapped as `AXAuditPoint_v1`, the device crashes with
    /// `-[__NSDictionaryI CGPointValue]: unrecognized selector` — this one argument skips the
    /// transport manager and calls `CGPointValue` directly.
    /// (`pymobiledevice3` can't build an NSValue, so it can't use this call.)
    static func point(x: Double, y: Double) -> NSValue {
        NSValue(point: NSPoint(x: x, y: y))
    }

    /// Inspector focus move direction.
    enum Direction: Int {
        case previous = 3
        case next = 4
        case first = 5
        case last = 6
    }

    static func moveOptions(_ direction: Direction) -> [String: Any] {
        passthrough([
            "allowNonAX": passthrough(0),
            "direction": passthrough(direction.rawValue),
            "includeContainers": passthrough(1),
        ])
    }

    /// Strips `{ObjectType, Value}` wrappers down to the payload. `Data` is left as is.
    static func unwrap(_ value: Any?, depth: Int = 0) -> Any? {
        guard depth < 24 else { return "..." }

        switch value {
        case let dictionary as [String: Any]:
            if dictionary["ObjectType"] != nil, dictionary.count == 2, dictionary["Value"] != nil {
                return unwrap(dictionary["Value"], depth: depth + 1)
            }
            return dictionary.compactMapValues { unwrap($0, depth: depth + 1) }

        case let array as [Any]:
            return array.compactMap { unwrap($0, depth: depth + 1) }

        case is NSNull:
            return nil

        default:
            return value
        }
    }

    /// Into a shape JSONSerialization accepts. `Data` becomes an uppercase hex string.
    static func jsonReady(_ value: Any?) -> Any {
        switch value {
        case let data as Data:
            return data.map { String(format: "%02X", $0) }.joined()
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonReady($0) }
        case let array as [Any]:
            return array.map { jsonReady($0) }
        case let value?:
            return value
        case nil:
            return NSNull()
        }
    }
}
