import Foundation

enum RemoteXPCError: Error, CustomStringConvertible {
    case connectFailed(host: String, port: Int, reason: String)
    /// Where and how it was closed. The same "closed" has different causes: peer closed, GOAWAY, socket error.
    case closed(String)
    case timeout(String)
    case protocolViolation(String)

    var description: String {
        switch self {
        case .connectFailed(let host, let port, let reason):
            return "connection to [\(host)]:\(port) failed: \(reason)"
        case .closed(let how):
            return "connection lost (\(how))."
        case .timeout(let what):
            return "timed out waiting for a reply: \(what)"
        case .protocolViolation(let detail):
            return "protocol violation: \(detail)"
        }
    }
}

/// A blocking TCP socket opened to a tunnel address.
///
/// Everything we do is one request -> one response, so no async is needed. A blocking socket with
/// just a receive timeout is much shorter and easier to debug.
final class TCPSocket {
    private var fd: Int32 = -1

    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let head = info else {
            throw RemoteXPCError.connectFailed(
                host: host, port: port, reason: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(info) }

        var lastError = "no address found"
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let entry = candidate {
            let socketFD = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if socketFD >= 0 {
                if connect(socketFD, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                    fd = socketFD
                    var value: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size))
                    // If the peer closes first after we send a no-reply message (clipboard PUSH, etc.),
                    // write kills the process with SIGPIPE. Take it as an error instead.
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
                    setReceiveTimeout(timeout)
                    return
                }
                lastError = String(cString: strerror(errno))
                close(socketFD)
            } else {
                lastError = String(cString: strerror(errno))
            }
            candidate = entry.pointee.ai_next
        }
        throw RemoteXPCError.connectFailed(host: host, port: port, reason: lastError)
    }

    func setReceiveTimeout(_ seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func write(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            while sent < buffer.count {
                let written = send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if written <= 0 {
                    throw RemoteXPCError.closed("send failed: \(String(cString: strerror(errno)))")
                }
                sent += written
            }
        }
    }

    /// Reads exactly `count` bytes. Throws if the peer disconnects or it times out.
    func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data(count: count)
        var got = 0
        try out.withUnsafeMutableBytes { buffer in
            while got < count {
                let n = recv(fd, buffer.baseAddress!.advanced(by: got), count - got, 0)
                if n == 0 { throw RemoteXPCError.closed("peer closed, got \(got) of \(count) bytes") }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw RemoteXPCError.timeout("only \(got) of \(count) bytes arrived")
                    }
                    throw RemoteXPCError.closed("receive failed: \(String(cString: strerror(errno)))")
                }
                got += n
            }
        }
        return out
    }

    /// Hands over socket ownership. This object won't close the fd afterwards.
    ///
    /// The receiver (DTXSocketTransport) reads its own way, so clear the receive timeout we set.
    /// Left in place, read ends with EAGAIN whenever the device goes quiet and the connection is treated as lost.
    func detach() -> Int32 {
        setReceiveTimeout(0)
        let descriptor = fd
        fd = -1
        return descriptor
    }

    /// Closes immediately. If unread control frames remain in the receive buffer, an RST goes out.
    ///
    /// A device receiving RST discards its unread receive buffer, so after sending a no-reply message,
    /// check separately that the device read everything before closing (`ping()`, `HIDService.sync()`).
    /// But don't close politely by sending only FIN and waiting for the peer to close — the device's
    /// HID service holds on to the half-closed connection and delays the next connection's handshake by nearly 10 s.
    func shutdownAndClose() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
    }

    deinit { shutdownAndClose() }
}

/// A connection to one RemoteXPC service on the device.
///
/// The RSD control connection and individual service connections are the same class — the only
/// difference is whether `sendDeviceHandshake()` is called, which only the RSD control connection does.
final class RemoteXPCConnection {
    private static let rootChannel: UInt32 = 1
    private static let replyChannel: UInt32 = 3
    private static let initialWindowSize: UInt32 = 16 * 1024 * 1024

    private let socket: TCPSocket
    private var nextMessageID: UInt64 = 0
    /// When a DATA frame arrives cut off in the middle of an XPC envelope, collect it here and append the next frame.
    private var pending = Data()

    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        socket = try TCPSocket(host: host, port: port, timeout: timeout)
        try handshake()
    }

    func close() { socket.shutdownAndClose() }

    /// HTTP/2 preamble + opening the RemoteXPC channels.
    ///
    /// The frame order must match devicectl's. The device's RSD layer checks the order, and if
    /// stream 3's HEADERS come after stream 1's terminating envelope it drops the connection with
    /// "Invalid or missing remote device connection version flags".
    private func handshake() throws {
        try socket.write(HTTP2.preface)
        try socket.write(
            HTTP2.settings([(.maxConcurrentStreams, 100), (.initialWindowSize, Self.initialWindowSize)]))
        try socket.write(
            HTTP2.windowUpdate(streamID: 0, increment: Self.initialWindowSize - 65535))
        try socket.write(
            HTTP2.frame(.headers, flags: HTTP2.Flag.endHeaders, streamID: Self.rootChannel))

        try send(wrapper: XPCWrapper.build([:], messageID: nextMessageID), on: Self.rootChannel)
        nextMessageID += 1

        try socket.write(
            HTTP2.frame(.headers, flags: HTTP2.Flag.endHeaders, streamID: Self.replyChannel))
        try send(wrapper: XPCWrapper.control(flags: 0x0201), on: Self.rootChannel)
        try send(
            wrapper: XPCWrapper.control(
                flags: XPCWrapper.Flags.alwaysSet | XPCWrapper.Flags.initHandshake),
            on: Self.replyChannel)

        // Let flow-control frames pass until the peer's SETTINGS arrive.
        var frame = try readFrame()
        while frame.kind != .settings {
            guard frame.kind == .windowUpdate || frame.kind == .headers else {
                throw RemoteXPCError.protocolViolation("frame of type \(frame.type) instead of SETTINGS")
            }
            frame = try readFrame()
        }
        try socket.write(HTTP2.frame(.settings, flags: HTTP2.Flag.ack, streamID: 0))
    }

    /// Called only on the RSD control connection. Introduces this host as a "non-legacy" RemoteXPC peer.
    ///
    /// The UUID must match the host `remoted`'s. The device keeps only one RSD connection per tunnel,
    /// and if a new connection's UUID differs from the previous one it closes every advertised service listener.
    func sendDeviceHandshake(peerUUID: UUID) throws {
        try sendRequest([
            "MessageType": .string("Handshake"),
            "MessagingProtocolVersion": .uint64(7),
            "UUID": .uuid(peerUUID),
            "Properties": .dictionary([
                "RemoteXPCVersionFlags": .uint64(0x0100_0000_0000_0006),
                "SensitivePropertiesVisible": .bool(true),
            ]),
            "Services": .dictionary([:]),
        ])
    }

    func sendRequest(_ entries: [String: XPCObject], wantingReply: Bool = false) throws {
        let wrapper = XPCWrapper.build(
            entries, messageID: nextMessageID, wantingReply: wantingReply)
        try send(wrapper: wrapper, on: Self.rootChannel)
        nextMessageID += 1
    }

    func receiveResponse(timeout: TimeInterval = 10) throws -> [String: XPCObject] {
        socket.setReceiveTimeout(timeout)
        while true {
            let frame = try readDataFrame()
            pending.append(frame.payload)
            guard let parsed = XPCWrapper.parse(pending) else { continue }
            pending = Data()
            guard let body = parsed.body, !body.isEmpty else { continue }
            nextMessageID = parsed.messageID + 1
            return body
        }
    }

    @discardableResult
    func sendReceive(_ entries: [String: XPCObject], timeout: TimeInterval = 10) throws
        -> [String: XPCObject]
    {
        try sendRequest(entries, wantingReply: true)
        return try receiveResponse(timeout: timeout)
    }

    /// Sends an HTTP/2 PING and waits for the ACK.
    ///
    /// The device's HTTP/2 layer takes frames off the socket in arrival order, so once the ACK arrives,
    /// every DATA frame sent before it has left the socket (into the device process). After that, even
    /// an RST close won't discard them. Use it after sending no-reply messages, before closing.
    func ping(timeout: TimeInterval = 5) throws {
        let token = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        try socket.write(HTTP2.frame(.ping, streamID: 0, payload: token))
        socket.setReceiveTimeout(timeout)
        while true {
            let frame = try readFrame()
            switch frame.kind {
            case .ping where frame.flags & HTTP2.Flag.ack != 0 && frame.payload == token:
                return
            case .ping where frame.flags & HTTP2.Flag.ack == 0:
                try socket.write(
                    HTTP2.frame(.ping, flags: HTTP2.Flag.ack, streamID: 0, payload: frame.payload))
            case .goAway:
                throw RemoteXPCError.closed(HTTP2.goAwayReason(frame.payload))
            default:
                continue  // drop control frames and DATA that arrived in between
            }
        }
    }

    // MARK: - Frame I/O

    private func send(wrapper: Data, on streamID: UInt32) throws {
        // Every message we send is well under 16KB and fits in one frame.
        try socket.write(HTTP2.frame(.data, streamID: streamID, payload: wrapper))
    }

    private func readFrame() throws -> HTTP2.Frame {
        let header = try socket.readExactly(HTTP2.headerSize)
        let bytes = [UInt8](header)
        let length = (Int(bytes[0]) << 16) | (Int(bytes[1]) << 8) | Int(bytes[2])
        let streamID =
            (UInt32(bytes[5] & 0x7F) << 24) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 8)
            | UInt32(bytes[8])
        let payload = try socket.readExactly(length)
        return HTTP2.Frame(type: bytes[3], flags: bytes[4], streamID: streamID, payload: payload)
    }

    /// Reads until a DATA frame appears, handling control frames along the way.
    private func readDataFrame() throws -> HTTP2.Frame {
        while true {
            let frame = try readFrame()
            switch frame.kind {
            case .data:
                return frame
            case .settings where frame.flags & HTTP2.Flag.ack == 0:
                try socket.write(HTTP2.frame(.settings, flags: HTTP2.Flag.ack, streamID: 0))
            case .goAway:
                throw RemoteXPCError.closed(HTTP2.goAwayReason(frame.payload))
            default:
                continue  // WINDOW_UPDATE, HEADERS, SETTINGS ACK, etc. can be ignored
            }
        }
    }
}
