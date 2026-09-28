import Foundation

/// The XPC message envelope carried in one DATA frame.
///
/// ```
/// magic(0x29B00B92) | flags | size:u64 | message_id:u64 | payload?
/// payload = magic(0x42133742) | version(5) | XPCObject
/// ```
/// `size` counts **only the payload length** (the 8-byte message_id is excluded). A size of 0 means a
/// control envelope with no payload — used in the handshake.
enum XPCWrapper {
    static let magic: UInt32 = 0x29B0_0B92
    static let payloadMagic: UInt32 = 0x4213_3742
    static let protocolVersion: UInt32 = 5

    enum Flags {
        static let alwaysSet: UInt32 = 0x0000_0001
        static let dataPresent: UInt32 = 0x0000_0100
        static let wantingReply: UInt32 = 0x0001_0000
        static let initHandshake: UInt32 = 0x0040_0000
    }

    static func build(
        _ entries: [String: XPCObject], messageID: UInt64 = 0, wantingReply: Bool = false
    ) -> Data {
        var flags = Flags.alwaysSet
        if !entries.isEmpty { flags |= Flags.dataPresent }
        if wantingReply { flags |= Flags.wantingReply }

        var payload = Data()
        payload.append(le(payloadMagic))
        payload.append(le(protocolVersion))
        payload.append(XPCObject.dictionary(entries).encoded())

        var out = Data()
        out.append(le(magic))
        out.append(le(flags))
        out.append(le(UInt64(payload.count)))
        out.append(le(messageID))
        out.append(payload)
        return out
    }

    /// Control envelope with no payload.
    static func control(flags: UInt32, messageID: UInt64 = 0) -> Data {
        var out = Data()
        out.append(le(magic))
        out.append(le(flags))
        out.append(le(UInt64(0)))
        out.append(le(messageID))
        return out
    }

    struct Parsed {
        let flags: UInt32
        let messageID: UInt64
        /// nil for a control envelope with no payload.
        let body: [String: XPCObject]?
    }

    /// `nil` if bytes are short — the caller appends the next DATA frame and retries.
    static func parse(_ bytes: Data) -> Parsed? {
        var reader = XPCReader(bytes)
        guard let gotMagic = reader.u32(), gotMagic == magic,
            let flags = reader.u32(),
            let size = reader.u64(),
            let messageID = reader.u64()
        else { return nil }

        guard size > 0 else { return Parsed(flags: flags, messageID: messageID, body: nil) }
        guard let payload = reader.take(Int(size)) else { return nil }

        var inner = XPCReader(payload)
        guard let gotPayloadMagic = inner.u32(), gotPayloadMagic == payloadMagic,
            inner.u32() != nil,
            let object = XPCObject.decode(from: &inner),
            let body = object.dictionaryValue
        else { return nil }

        return Parsed(flags: flags, messageID: messageID, body: body)
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}
