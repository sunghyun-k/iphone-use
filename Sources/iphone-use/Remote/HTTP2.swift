import Foundation

/// Just as much HTTP/2 as RemoteXPC uses.
///
/// It doesn't use standard HTTP/2 semantics — HEADERS are sent as **empty frames with no body** (no
/// HPACK, no pseudo-headers), and all real content rides in DATA frames as XPC wrappers. A general
/// HTTP/2 library would trip over header validation, so we build only the frames we need.
enum HTTP2 {
    static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let headerSize = 9

    enum FrameType: UInt8 {
        case data = 0x0
        case headers = 0x1
        case rstStream = 0x3
        case settings = 0x4
        case ping = 0x6
        case goAway = 0x7
        case windowUpdate = 0x8
    }

    enum Flag {
        static let ack: UInt8 = 0x1
        static let endHeaders: UInt8 = 0x4
    }

    enum Setting: UInt16 {
        case maxConcurrentStreams = 0x3
        case initialWindowSize = 0x4
    }

    /// GOAWAY payload (last stream 4 bytes + error code 4 bytes + debug text) as one line.
    static func goAwayReason(_ payload: Data) -> String {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return "GOAWAY" }
        let code = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let debug = String(decoding: bytes[8...], as: UTF8.self)
        return "GOAWAY error code \(code)" + (debug.isEmpty ? "" : ": \(debug)")
    }

    struct Frame {
        let type: UInt8
        let flags: UInt8
        let streamID: UInt32
        let payload: Data

        var kind: FrameType? { FrameType(rawValue: type) }
    }

    static func frame(_ type: FrameType, flags: UInt8 = 0, streamID: UInt32, payload: Data = Data())
        -> Data
    {
        var out = Data()
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(type.rawValue)
        out.append(flags)
        // The top bit is reserved (R), always 0.
        out.append(UInt8((streamID >> 24) & 0x7F))
        out.append(UInt8((streamID >> 16) & 0xFF))
        out.append(UInt8((streamID >> 8) & 0xFF))
        out.append(UInt8(streamID & 0xFF))
        out.append(payload)
        return out
    }

    static func settings(_ values: [(Setting, UInt32)]) -> Data {
        var payload = Data()
        for (setting, value) in values {
            payload.append(UInt8(setting.rawValue >> 8))
            payload.append(UInt8(setting.rawValue & 0xFF))
            payload.append(UInt8((value >> 24) & 0xFF))
            payload.append(UInt8((value >> 16) & 0xFF))
            payload.append(UInt8((value >> 8) & 0xFF))
            payload.append(UInt8(value & 0xFF))
        }
        return frame(.settings, streamID: 0, payload: payload)
    }

    static func windowUpdate(streamID: UInt32, increment: UInt32) -> Data {
        var payload = Data()
        payload.append(UInt8((increment >> 24) & 0x7F))
        payload.append(UInt8((increment >> 16) & 0xFF))
        payload.append(UInt8((increment >> 8) & 0xFF))
        payload.append(UInt8(increment & 0xFF))
        return frame(.windowUpdate, streamID: streamID, payload: payload)
    }
}
