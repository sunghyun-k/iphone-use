import Foundation

/// Injects real input events into the device.
///
/// Uses two RemoteXPC services.
/// - `universalhidservice`: plugs **raw HID reports** into HID surfaces the device has already registered.
///   The main touchscreen is `_ServiceID 257`.
/// - `hid.indigo`: hardware button (volume, etc.) state changes.
///
/// **Coordinates are normalized to 0..65535.** Pixels or points passed as-is fall out of range and
/// are silently dropped — nothing happens on screen, which makes the cause hard to find.
final class HIDService {
    /// Main touchscreen surface.
    static let mainTouchscreen: UInt64 = 257
    /// Keyboard surface the device has already registered. No need to create a virtual keyboard.
    static let keyboardSurface: UInt64 = 512

    /// ID of the 58-byte touch report.
    private static let touchReportID: UInt8 = 0x09
    /// "Contact held" / "released".
    private static let stateContact: UInt8 = 0xC2
    private static let stateRelease: UInt8 = 0x02

    private let universal: RemoteXPCConnection
    private let indigo: RemoteXPCConnection
    /// When a button was last released. `sync()` waits for a while after this.
    private var lastButtonRelease: Date?
    /// How long to wait after releasing a button before the next action.
    ///
    /// The home button waits a moment after release while the device decides whether it's a double
    /// click. If the connection closes in that window, the press itself is canceled (Wi-Fi measurement:
    /// at 0.3 s every press was ignored, from 0.45 s every one registered), and a following press merges
    /// into a double press (app switcher). In the daemon, with no cost to reopening, even 0.55 s merged; 0.8 s stopped it.
    private static let buttonSettle: TimeInterval = 0.8

    init(rsd: RemoteServiceDiscovery) throws {
        universal = try rsd.connect(to: "com.apple.coredevice.hid.universalhidservice")
        indigo = try rsd.connect(to: "com.apple.coredevice.hid.indigo")
    }

    func close() {
        universal.close()
        indigo.close()
    }

    /// List of registered HID surfaces. For diagnostics.
    ///
    /// **Once called, this connection is done.** The device drops the connection after replying and
    /// the HID service refuses new connections for a while (see `sync()`). Don't use it outside `hid-info`.
    func connectedSurfaces() throws -> [String: XPCObject] {
        try universal.sendReceive([
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .string("Request"),
            "payload": .dictionary(["connectedServices": .dictionary([:])]),
        ])
    }

    /// Waits until the device has read every report sent so far.
    ///
    /// Reports get no reply, so sending alone doesn't tell us they arrived. USB was fine, but over
    /// Wi-Fi closing right after sending made the device discard them with RST before reading, and
    /// whole swipes and key inputs vanished. So both connections do one HTTP/2 PING round trip before closing.
    ///
    /// Don't substitute a request that gets a reply (`connectedSurfaces`). The device's HID service
    /// drops the connection right after sending that reply, then ignores new connection handshakes for
    /// nearly 10 seconds (looks like launchd's restart throttling). Commands issued back to back all time out.
    ///
    /// Right after a button release, wait a bit longer (`buttonSettle`). Even the daemon, which doesn't
    /// close the connection, waits — otherwise repeated `button home` merges into a double press and the app switcher appears.
    func sync() throws {
        try universal.ping()
        try indigo.ping()
        if let released = lastButtonRelease {
            let remaining = Self.buttonSettle - Date().timeIntervalSince(released)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            lastButtonRelease = nil
        }
    }

    // MARK: - Touch

    /// Touches one point and releases.
    ///
    /// Why several contact samples: send just one and release immediately, and UIKit sometimes
    /// treats it as noise and ignores it.
    func tap(x: Int, y: Int, hold: TimeInterval = 0.08) throws {
        let samples = max(2, Int(hold / 0.02))
        for _ in 0..<samples {
            try sendTouch(state: Self.stateContact, x: x, y: y)
            Thread.sleep(forTimeInterval: hold / Double(samples))
        }
        try sendTouch(state: Self.stateRelease, x: x, y: y)
    }

    /// A drag between two points.
    ///
    /// If you don't want inertial scrolling, make `duration` long — the speed of the last segment
    /// becomes the flick speed.
    /// With `holdAtEnd` > 0, it decelerates toward the end (ease-out), pauses at the end point, then releases.
    /// Dragging at constant speed and just stopping in place still left inertia — the device doesn't
    /// count reports repeating the same point as movement and flung at the last real movement speed
    /// (0.5 s constant speed: 1.8× the dragged distance).
    /// Only decelerating so the last movement speed itself is near 0 makes it travel exactly the dragged distance.
    func swipe(
        from start: (x: Int, y: Int), to end: (x: Int, y: Int), duration: TimeInterval = 0.35,
        holdAtEnd: TimeInterval = 0
    ) throws {
        let steps = max(2, Int(duration / 0.016))
        for index in 0...steps {
            let t = Double(index) / Double(steps)
            let progress = holdAtEnd > 0 ? 1 - pow(1 - t, 3) : t
            try sendTouch(
                state: Self.stateContact,
                x: start.x + Int(Double(end.x - start.x) * progress),
                y: start.y + Int(Double(end.y - start.y) * progress))
            Thread.sleep(forTimeInterval: duration / Double(steps))
        }
        if holdAtEnd > 0 {
            // Sent once and done, the device doesn't see a "stop". Keep sending the same point while stopped.
            let until = Date().addingTimeInterval(holdAtEnd)
            while Date() < until {
                try sendTouch(state: Self.stateContact, x: end.x, y: end.y)
                Thread.sleep(forTimeInterval: 0.016)
            }
        }
        try sendTouch(state: Self.stateRelease, x: end.x, y: end.y)
    }

    /// Long press.
    func press(x: Int, y: Int, duration: TimeInterval) throws {
        let steps = max(2, Int(duration / 0.02))
        for _ in 0..<steps {
            try sendTouch(state: Self.stateContact, x: x, y: y)
            Thread.sleep(forTimeInterval: duration / Double(steps))
        }
        try sendTouch(state: Self.stateRelease, x: x, y: y)
    }

    private func sendTouch(state: UInt8, x: Int, y: Int) throws {
        try sendReport(
            surface: Self.mainTouchscreen, report: Self.touchReport(state: state, x: x, y: y))
    }

    /// 58-byte mainTouchscreen report.
    ///
    /// ```
    /// 0     report ID (0x09)
    /// 1-2   constant 0x01 0x05
    /// 3     state (0xC2 contact / 0x02 release)
    /// 4-7   X, Y (UInt16 LE each, normalized 0..65535)
    /// 8-39  reserved (0)
    /// 40-43 constant 0x02 0x00 0x00 0x00
    /// 44-49 host timestamp (48-bit LE)
    /// 50-57 reserved (0)
    /// ```
    static func touchReport(state: UInt8, x: Int, y: Int) -> Data {
        var report = Data([touchReportID, 0x01, 0x05, state])

        let clampedX = UInt16(clamping: x)
        let clampedY = UInt16(clamping: y)
        report.append(UInt8(clampedX & 0xFF))
        report.append(UInt8(clampedX >> 8))
        report.append(UInt8(clampedY & 0xFF))
        report.append(UInt8(clampedY >> 8))

        report.append(Data(repeating: 0, count: 32))
        report.append(Data([0x02, 0x00, 0x00, 0x00]))

        let timestamp = DispatchTime.now().uptimeNanoseconds & ((1 << 48) - 1)
        for shift in stride(from: 0, to: 48, by: 8) {
            report.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        report.append(Data(repeating: 0, count: 8))
        return report
    }

    func sendReport(surface: UInt64, report: Data) throws {
        try universal.sendRequest([
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .string("Request"),
            "payload": .dictionary([
                "send": .dictionary(["_0": .data(report), "_1": .uint64(surface)])
            ]),
        ])
    }

    // MARK: - Keyboard

    /// 39-byte keyboard report.
    ///
    /// ```
    /// 0     report ID (0x01)
    /// 1-30  240-bit usage bitmap — usage u is bit (u%8) of byte 1+(u/8)
    /// 31-36 host timestamp (48-bit LE)
    /// 37-38 reserved (0)
    /// ```
    /// Sends **the full set of keys currently down** every time, not deltas. An empty set means all released.
    static func keyboardReport(usages: [UInt8]) -> Data {
        var report = Data([0x01])
        var bitmap = [UInt8](repeating: 0, count: 30)
        for usage in usages where usage < 240 {
            bitmap[Int(usage) / 8] |= 1 << (usage % 8)
        }
        report.append(contentsOf: bitmap)

        let timestamp = DispatchTime.now().uptimeNanoseconds & ((1 << 48) - 1)
        for shift in stride(from: 0, to: 48, by: 8) {
            report.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        report.append(Data([0, 0]))
        return report
    }

    /// Presses and releases a key. `modifiers` are usages held along with it (e.g. left Shift 0xE1).
    ///
    /// Modifiers are **pressed separately first**, the way a person types, then the key. Put modifier
    /// and key in the same report and the device sometimes misses the modifier — over Wi-Fi ⌘V went
    /// through the Korean layout and came out as a Hangul letter. On release, the key goes up first too.
    func typeKey(_ usage: UInt8, modifiers: [UInt8] = [], hold: TimeInterval = 0.02) throws {
        if !modifiers.isEmpty {
            try sendReport(surface: Self.keyboardSurface, report: Self.keyboardReport(usages: modifiers))
            Thread.sleep(forTimeInterval: hold)
        }
        try sendReport(surface: Self.keyboardSurface, report: Self.keyboardReport(usages: modifiers + [usage]))
        Thread.sleep(forTimeInterval: hold)
        if !modifiers.isEmpty {
            try sendReport(surface: Self.keyboardSurface, report: Self.keyboardReport(usages: modifiers))
            Thread.sleep(forTimeInterval: hold)
        }
        try sendReport(surface: Self.keyboardSurface, report: Self.keyboardReport(usages: []))
        Thread.sleep(forTimeInterval: hold)
    }

    // MARK: - Hardware buttons

    enum ButtonState: UInt64 {
        case down = 1
        case up = 2
        case canceled = 3
    }

    /// Presses and releases the button given by HID usage page/code.
    func pressButton(usagePage: UInt64, usageCode: UInt64, hold: TimeInterval = 0.08) throws {
        try sendButton(usagePage: usagePage, usageCode: usageCode, state: .down)
        Thread.sleep(forTimeInterval: hold)
        try sendButton(usagePage: usagePage, usageCode: usageCode, state: .up)
        lastButtonRelease = Date()
    }

    func sendButton(usagePage: UInt64, usageCode: UInt64, state: ButtonState) throws {
        try indigo.sendRequest([
            "messageType": .string("IndigoButtonEvent"),
            "payload": .dictionary([
                "state": .uint64(state.rawValue),
                "usagePage": .uint64(usagePage),
                "usageCode": .uint64(usageCode),
            ]),
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.hid.button"),
        ])
    }
}
