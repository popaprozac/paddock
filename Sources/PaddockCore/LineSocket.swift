import Darwin
import Dispatch
import Foundation
import os

/// A server that reads one request line per connection on a listening socket and answers with
/// one or more lines through a `Responder`, which closes the connection when it finishes.
///
/// `paddock serve` listens on a Unix socket; the guest agent listens on vsock.
public final class LineServer: @unchecked Sendable {
    private let source: any DispatchSourceRead
    private let onStop: @Sendable () -> Void

    /// Serves `fd`, a socket that is already listening. The server owns it from here and
    /// closes it when stopped, then runs `onStop`. Closes each connection whose peer address
    /// `accepts` refuses, unread. Calls `handle` on `queue` with each request line and the
    /// responder for that connection, which it may use from any thread, later.
    public init(
        listening fd: Int32,
        queue: DispatchQueue,
        accepts: @escaping @Sendable (sockaddr_storage) -> Bool = { _ in true },
        handle: @escaping @Sendable (String, Responder) -> Void,
        onStop: @escaping @Sendable () -> Void = {}
    ) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { return }
            guard accepts(peer) else {
                close(client)
                return
            }
            UnixSocket.configure(client, readTimeout: 5)
            // Reading blocks until the client sends its line, so give it its own thread: blocked
            // reads on GCD's shared threads stall other work until GCD adds more, slowly.
            Thread.detachNewThread {
                guard let line = UnixSocket.readLine(client) else {
                    close(client)
                    return
                }
                queue.async {
                    handle(line, Responder(fd: client))
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        self.onStop = onStop
    }

    /// Listens on a Unix socket at `path`.
    ///
    /// The socket file gets mode 0600, so only its owner can connect. Starting a second server
    /// on the same path fails while the first is listening; a socket file left behind by a
    /// process that died is replaced. Stopping the server removes the file.
    public convenience init(
        path: String,
        queue: DispatchQueue,
        accepts: @escaping @Sendable (sockaddr_storage) -> Bool = { _ in true },
        handle: @escaping @Sendable (String, Responder) -> Void
    ) throws {
        var address = try UnixSocket.address(path)
        if UnixSocket.isListening(path) {
            throw PaddockError("another paddock serve is already listening at \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.error("create a socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Mode 0600 before listen(), so no one else can connect even briefly.
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = UnixSocket.error("listen at \(path)")
            close(fd)
            unlink(path)
            throw error
        }
        self.init(listening: fd, queue: queue, accepts: accepts, handle: handle, onStop: { unlink(path) })
    }

    /// Stops accepting connections, closes the socket and runs `onStop`.
    public func stop() {
        guard !source.isCancelled else { return }
        source.cancel()
        onStop()
    }

    deinit {
        stop()
    }
}

/// One connection's way back to its client: any number of lines, then `finish`.
public final class Responder: @unchecked Sendable {
    private let fd: Int32
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32) {
        self.fd = fd
    }

    /// Sends one line. Does nothing once finished.
    public func send(_ line: String) {
        send(lines: [line])
    }

    /// Sends lines in one write. A guest answering line by line over vsock sends a packet per
    /// line, and tens of thousands of small packets stall Virtualization.framework's vsock for
    /// good; written together, the same data goes in a few large packets. Does nothing once
    /// finished.
    public func send(lines: [String]) {
        guard !lines.isEmpty else { return }
        finished.withLock { finished in
            if !finished {
                _ = UnixSocket.writeAll(Data((lines.joined(separator: "\n") + "\n").utf8), to: fd)
            }
        }
    }

    /// Sends a line and then raw bytes as one piece, for answers that carry binary data.
    public func send(_ line: String, then bytes: Data) {
        finished.withLock { finished in
            if !finished {
                UnixSocket.writeLine(line, to: fd)
                _ = UnixSocket.writeAll(bytes, to: fd)
            }
        }
    }

    /// Reads up to `count` raw bytes the client sent after its request line. Nil once the
    /// client stops sending or the read times out.
    public func receive(upTo count: Int) -> Data? {
        UnixSocket.read(upTo: count, from: fd)
    }

    /// Whether the client has closed its end, as when a waiting `paddock acquire` is stopped. Only
    /// for clients that send nothing more after their request line: anything but end of file
    /// counts as still there.
    public var clientHungUp: Bool {
        finished.withLock { finished in
            if finished { return true }
            var byte: UInt8 = 0
            let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            return count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        }
    }

    /// Sends a last line, if given, and closes the connection. Later calls do nothing.
    public func finish(_ line: String? = nil) {
        finished.withLock { finished in
            guard !finished else { return }
            if let line {
                UnixSocket.writeLine(line, to: fd)
            }
            close(fd)
            finished = true
        }
    }

    /// A handler that drops its responder without finishing still closes the connection.
    deinit {
        finish()
    }
}

/// A connection to a line server that sends and reads lines for as long as it stays open, as a
/// view does, with lines up to `maxLine` long.
public final class LineConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var reader: LineReader  // the reading thread's alone
    public static let maxLine = 4 << 20

    public init(path: String) throws {
        fd = try UnixSocket.connect(path)
        reader = LineReader(fd: fd)
    }

    /// Sends one line; false once the connection is gone.
    @discardableResult
    public func send(_ line: String) -> Bool {
        writeLock.withLock { UnixSocket.writeAll(Data((line + "\n").utf8), to: fd) }
    }

    /// The next line, or nil once the server closes the connection (or sends a line over `maxLine`).
    public func readLine() -> String? {
        reader.readLine(limit: Self.maxLine)
    }

    /// Ends the connection both ways: the server reads end of file, and a waiting `readLine` returns nil.
    public func close() {
        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}

public enum LineClient {
    /// Sends `line` to the server at `path` and waits, without a time limit, for the first line
    /// of its answer.
    public static func send(_ line: String, to path: String) throws -> String {
        var answer: String?
        try stream(line, to: path) { line in
            answer = line
            return false
        }
        guard let answer else {
            throw PaddockError("the server at \(path) closed the connection without answering")
        }
        return answer
    }

    /// Sends `line` and passes each line of the answer to `onLine` until the server closes the
    /// connection or `onLine` returns false.
    public static func stream(_ line: String, to path: String, onLine: (String) throws -> Bool) throws {
        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        UnixSocket.writeLine(line, to: fd)
        var reader = LineReader(fd: fd)
        while let answer = reader.readLine(), try onLine(answer) {}
    }
}

/// Reads lines from a socket in blocks of up to 64 KB instead of a system call per byte, for
/// answers of many lines.
struct LineReader {
    let fd: Int32
    private var buffer: [UInt8] = []
    private var start = 0  // where the unread part of `buffer` begins

    init(fd: Int32) {
        self.fd = fd
    }

    /// The next line without its newline, or nil at the end of the stream, on a read timeout or
    /// error, or when a line runs past `limit` bytes.
    mutating func readLine(limit: Int = 64 * 1024) -> String? {
        var searched = start
        while true {
            if let newline = buffer[searched...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[start..<newline], as: UTF8.self)
                start = newline + 1
                if start == buffer.count {
                    buffer.removeAll(keepingCapacity: true)
                    start = 0
                }
                return line
            }
            guard buffer.count - start < limit else { return nil }
            searched = buffer.count
            if start > 0 {
                buffer.removeSubrange(..<start)
                searched -= start
                start = 0
            }
            var block = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &block, block.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: block[..<count])
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw PaddockError("socket path is \(bytes.count) bytes, over the limit of \(capacity - 1): \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw error("create a socket") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw PaddockError("nothing is listening at \(path); start 'paddock serve' first")
        }
        configure(fd, readTimeout: nil)
        return fd
    }

    static func isListening(_ path: String) -> Bool {
        guard let fd = try? connect(path) else { return false }
        close(fd)
        return true
    }

    /// Stops a closed peer from killing the process with SIGPIPE, and bounds how long a read
    /// waits.
    static func configure(_ fd: Int32, readTimeout seconds: Int?) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if let seconds {
            var timeout = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    /// Reads up to a newline. Nil if the peer closes first, the read times out or the line
    /// runs past `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int = 64 * 1024) -> String? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < limit {
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") {
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
        return nil
    }

    static func writeLine(_ line: String, to fd: Int32) {
        _ = writeAll(Data((line + "\n").utf8), to: fd)
    }

    /// Writes all of `data`; false if the peer went away first.
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    /// Reads whatever has arrived, up to `count` bytes. Nil at end of stream or on a timeout.
    static func read(upTo count: Int, from fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(fd, &buffer, count)
        return received > 0 ? Data(buffer[..<received]) : nil
    }

    /// Reads exactly `count` bytes. Nil if the stream ends or times out first.
    static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = read(upTo: count - data.count, from: fd) else { return nil }
            data.append(chunk)
        }
        return data
    }

    static func error(_ action: String) -> PaddockError {
        PaddockError("can't \(action): \(String(cString: strerror(errno)))")
    }
}

/// A Responder whose answers come out the other end of a socket pair: for a request that didn't
/// arrive on a socket, such as one from the control plane, handed to a handler written for one.
public enum ResponderPipe {
    /// A responder to give the handler, and the lines it sends, ending once it finishes. A line is
    /// read only when the stream is asked for the next one, so a handler sending faster than the
    /// lines are taken, as exec's output does to a slow link to the control plane, waits once
    /// 1 MiB is waiting, instead of serve holding everything it sends. Handlers on serve's main
    /// actor send far less, so only one sending from a thread of its own ever waits.
    public static func make() throws -> (Responder, AsyncStream<String>) {
        let (handlerEnd, readerEnd) = try socketPair()
        var size: Int32 = 1 << 20
        setsockopt(handlerEnd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let reader = PipeReader(fd: readerEnd)
        return (Responder(fd: handlerEnd), AsyncStream(unfolding: { await reader.next() }))
    }

    /// As `make`, plus a way to send the handler bytes it reads with `Responder.receive`, as a
    /// client on a socket sends after its request line: for requests whose client keeps sending
    /// while they answer, such as a view's input.
    public static func makeDuplex() throws -> (Responder, AsyncStream<String>, Input) {
        let (handlerEnd, reader) = try socketPair()
        // Its own descriptor, so the reader closing its one when the handler finishes can't hand a
        // later write to whatever else gets that number.
        let writer = dup(reader)
        guard writer >= 0 else {
            close(handlerEnd)
            close(reader)
            throw PaddockError("can't make a socket pair: \(String(cString: strerror(errno)))")
        }
        let (lines, continuation) = AsyncStream<String>.makeStream()
        Thread.detachNewThread {
            var pending = Data()
            while let chunk = UnixSocket.read(upTo: 64 * 1024, from: reader) {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty {
                continuation.yield(String(decoding: pending, as: UTF8.self))
            }
            close(reader)
            continuation.finish()
        }
        return (Responder(fd: handlerEnd), lines, Input(fd: writer))
    }

    /// The client's end of a duplex pipe. Sends never block the caller: they're written in order on
    /// a queue of their own.
    public final class Input: @unchecked Sendable {
        private let fd: Int32
        private let queue = DispatchQueue(label: "paddock.responder-pipe.input")
        private var closed = false  // only on queue

        init(fd: Int32) {
            self.fd = fd
        }

        /// Bytes for the handler. Dropped once finished.
        public func send(_ data: Data) {
            queue.async { [self] in
                guard !closed else { return }
                _ = UnixSocket.writeAll(data, to: fd)
            }
        }

        /// No more bytes: the handler reads end of file next, and `clientHungUp` turns true.
        public func finish() {
            queue.async { [self] in
                guard !closed else { return }
                closed = true
                shutdown(fd, SHUT_WR)
                close(fd)
            }
        }
    }

    /// A connected pair whose closed peer can't kill the process with SIGPIPE.
    private static func socketPair() throws -> (Int32, Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw PaddockError("can't make a socket pair: \(String(cString: strerror(errno)))")
        }
        UnixSocket.configure(ends[0], readTimeout: nil)
        UnixSocket.configure(ends[1], readTimeout: nil)
        return (ends[0], ends[1])
    }

    /// Reads a plain pipe's lines one at a time, as they're asked for, on a queue of its own so
    /// the blocking read never holds the asking task's thread.
    private final class PipeReader: @unchecked Sendable {
        private let queue = DispatchQueue(label: "paddock.responder-pipe.reader")
        private var reader: LineReader  // only on queue
        private var closed = false  // only on queue

        init(fd: Int32) {
            reader = LineReader(fd: fd)
        }

        /// The next line, or nil once the handler has finished.
        func next() async -> String? {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !closed else { return continuation.resume(returning: nil) }
                    // No limit: serve's answers can be longer than an agent's.
                    let line = reader.readLine(limit: .max)
                    if line == nil {
                        closed = true
                        close(reader.fd)
                    }
                    continuation.resume(returning: line)
                }
            }
        }

        /// A stream dropped before its end lets go of the handler, whose sends then fail.
        deinit {
            if !closed { close(reader.fd) }
        }
    }
}
