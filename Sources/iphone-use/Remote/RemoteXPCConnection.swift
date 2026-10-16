import Foundation

enum RemoteXPCError: Error, CustomStringConvertible {
    /// Where and how it was closed. The same "closed" has different causes: peer closed, GOAWAY, socket error.
    case closed(String)
    case timeout(String)
    case protocolViolation(String)

    var description: String {
        switch self {
        case .closed(let how):
            return "connection lost (\(how))."
        case .timeout(let what):
            return "timed out waiting for a reply: \(what)"
        case .protocolViolation(let detail):
            return "protocol violation: \(detail)"
        }
    }
}

/// A blocking socket connected to one device service.
///
/// Everything we do is one request -> one response, so no async is needed. A blocking socket with
/// just a receive timeout is much shorter and easier to debug.
final class TCPSocket {
    private var fd: Int32 = -1
    /// Releases whatever handed out the socket (a lockdown service connection). Runs once, on close.
    var onClose: (() -> Void)?

    /// Takes ownership of an already connected socket (from `CoreDeviceClient.serviceSocket`).
    init(adopting descriptor: Int32, timeout: TimeInterval = 10) {
        fd = descriptor
        // CoreDeviceService hands the socket over non-blocking. Left that way, every read fails at
        // once with EAGAIN and looks like a timeout.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var value: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size))
        // If the peer closes first after we send a no-reply message (clipboard PUSH, etc.),
        // write kills the process with SIGPIPE. Take it as an error instead.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        setReceiveTimeout(timeout)
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
        onClose?()
        onClose = nil
    }

    deinit { shutdownAndClose() }
}

/// A connection to one RemoteXPC service on the device.
///
final class RemoteXPCConnection {
    private static let rootChannel: UInt32 = 1
    private static let replyChannel: UInt32 = 3
    private static let initialWindowSize: UInt32 = 16 * 1024 * 1024

    private let socket: TCPSocket
    private var nextMessageID: UInt64 = 0
    /// When a DATA frame arrives cut off in the middle of an XPC envelope, collect it here and append the next frame.
    private var pending = Data()

    init(socket: TCPSocket) throws {
        self.socket = socket
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
