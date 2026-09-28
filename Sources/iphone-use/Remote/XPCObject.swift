import Foundation

/// libxpc's serialization format.
///
/// RemoteXPC wraps XPC objects in this format and carries them in HTTP/2 DATA frames.
/// All integers are little endian, and strings/data are padded to 4-byte boundaries.
indirect enum XPCObject {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(UInt64)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([XPCObject])
    case dictionary([String: XPCObject])

    enum Kind: UInt32 {
        case null = 0x0000_1000
        case bool = 0x0000_2000
        case int64 = 0x0000_3000
        case uint64 = 0x0000_4000
        case double = 0x0000_5000
        case date = 0x0000_7000
        case data = 0x0000_8000
        case string = 0x0000_9000
        case uuid = 0x0000_A000
        case array = 0x0000_E000
        case dictionary = 0x0000_F000
    }
}

// MARK: - Writing

/// Buffer that accumulates little-endian bytes. Handles 4-byte alignment padding itself.
struct XPCWriter {
    private(set) var bytes = Data()

    mutating func u32(_ value: UInt32) { withLittle(value) }
    mutating func u64(_ value: UInt64) { withLittle(value) }
    mutating func i64(_ value: Int64) { withLittle(UInt64(bitPattern: value)) }
    mutating func raw(_ data: Data) { bytes.append(data) }

    /// Pads with zeros up to a 4-byte boundary.
    mutating func align() {
        let remainder = bytes.count % 4
        if remainder != 0 {
            bytes.append(Data(repeating: 0, count: 4 - remainder))
        }
    }

    private mutating func withLittle<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
}

extension XPCObject {
    func encoded() -> Data {
        var writer = XPCWriter()
        encode(into: &writer)
        return writer.bytes
    }

    func encode(into writer: inout XPCWriter) {
        switch self {
        case .null:
            writer.u32(Kind.null.rawValue)

        case .bool(let value):
            writer.u32(Kind.bool.rawValue)
            writer.u32(value ? 1 : 0)

        case .int64(let value):
            writer.u32(Kind.int64.rawValue)
            writer.i64(value)

        case .uint64(let value):
            writer.u32(Kind.uint64.rawValue)
            writer.u64(value)

        case .double(let value):
            writer.u32(Kind.double.rawValue)
            writer.u64(value.bitPattern)

        case .date(let value):
            writer.u32(Kind.date.rawValue)
            writer.u64(value)

        case .data(let value):
            writer.u32(Kind.data.rawValue)
            writer.u32(UInt32(value.count))
            writer.raw(value)
            writer.align()

        case .string(let value):
            // The length includes the NUL, followed by 4-byte alignment padding.
            writer.u32(Kind.string.rawValue)
            var utf8 = Data(value.utf8)
            utf8.append(0)
            writer.u32(UInt32(utf8.count))
            writer.raw(utf8)
            writer.align()

        case .uuid(let value):
            writer.u32(Kind.uuid.rawValue)
            withUnsafeBytes(of: value.uuid) { writer.raw(Data($0)) }

        case .array(let items):
            writer.u32(Kind.array.rawValue)
            var body = XPCWriter()
            body.u32(UInt32(items.count))
            for item in items { item.encode(into: &body) }
            writer.u32(UInt32(body.bytes.count))
            writer.raw(body.bytes)

        case .dictionary(let entries):
            writer.u32(Kind.dictionary.rawValue)
            var body = XPCWriter()
            body.u32(UInt32(entries.count))
            // Key order has no meaning in the protocol, but sorting makes dumps easier to compare.
            for key in entries.keys.sorted() {
                var utf8 = Data(key.utf8)
                utf8.append(0)
                body.raw(utf8)
                body.align()
                entries[key]!.encode(into: &body)
            }
            writer.u32(UInt32(body.bytes.count))
            writer.raw(body.bytes)
        }
    }
}

// MARK: - Reading

/// A reader that returns `nil` on truncated bytes. When HTTP/2 frames arrive split, the next frame
/// must be appended and retried, so parse failure and "not all here yet" aren't distinguished.
struct XPCReader {
    let bytes: Data
    var offset: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    var remaining: Int { bytes.endIndex - offset }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        defer { offset += 8 }
        return bytes[offset..<offset + 8].withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }

    mutating func take(_ count: Int) -> Data? {
        guard remaining >= count else { return nil }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func align() {
        let consumed = offset - bytes.startIndex
        let remainder = consumed % 4
        if remainder != 0 { offset += 4 - remainder }
    }

    /// NUL-terminated, 4-byte-aligned string (dictionary key format).
    mutating func alignedCString() -> String? {
        guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        let text = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        align()
        return text
    }
}

extension XPCObject {
    static func decode(from reader: inout XPCReader) -> XPCObject? {
        guard let rawKind = reader.u32(), let kind = Kind(rawValue: rawKind) else { return nil }

        switch kind {
        case .null:
            return .null

        case .bool:
            guard let value = reader.u32() else { return nil }
            return .bool(value != 0)

        case .int64:
            guard let value = reader.u64() else { return nil }
            return .int64(Int64(bitPattern: value))

        case .uint64:
            guard let value = reader.u64() else { return nil }
            return .uint64(value)

        case .double:
            guard let value = reader.u64() else { return nil }
            return .double(Double(bitPattern: value))

        case .date:
            guard let value = reader.u64() else { return nil }
            return .date(value)

        case .data:
            guard let length = reader.u32(), let payload = reader.take(Int(length)) else {
                return nil
            }
            reader.align()
            return .data(payload)

        case .string:
            guard let length = reader.u32(), let payload = reader.take(Int(length)) else {
                return nil
            }
            reader.align()
            let trimmed = payload.last == 0 ? payload.dropLast() : payload[...]
            return .string(String(decoding: trimmed, as: UTF8.self))

        case .uuid:
            guard let payload = reader.take(16) else { return nil }
            let bytes = [UInt8](payload)
            return .uuid(
                UUID(
                    uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                        bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
                        bytes[14], bytes[15]
                    )))

        case .array:
            guard let size = reader.u32(), let body = reader.take(Int(size)) else { return nil }
            var inner = XPCReader(body)
            guard let count = inner.u32() else { return nil }
            var items: [XPCObject] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let item = XPCObject.decode(from: &inner) else { return nil }
                items.append(item)
            }
            return .array(items)

        case .dictionary:
            guard let size = reader.u32(), let body = reader.take(Int(size)) else { return nil }
            var inner = XPCReader(body)
            guard let count = inner.u32() else { return nil }
            var entries: [String: XPCObject] = [:]
            for _ in 0..<count {
                guard let key = inner.alignedCString(),
                    let value = XPCObject.decode(from: &inner)
                else { return nil }
                entries[key] = value
            }
            return .dictionary(entries)
        }
    }
}

// MARK: - Convenience accessors

extension XPCObject {
    var dictionaryValue: [String: XPCObject]? {
        if case .dictionary(let entries) = self { return entries }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int64(let value): return Int(value)
        case .uint64(let value): return Int(value)
        default: return nil
        }
    }

    var arrayValue: [XPCObject]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// Lowered to a JSON-friendly form for logging and debugging.
    var jsonReady: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int64(let value): return value
        case .uint64(let value): return value
        case .double(let value): return value
        case .date(let value): return value
        case .data(let value): return value.map { String(format: "%02X", $0) }.joined()
        case .string(let value): return value
        case .uuid(let value): return value.uuidString
        case .array(let items): return items.map { $0.jsonReady }
        case .dictionary(let entries): return entries.mapValues { $0.jsonReady }
        }
    }
}
