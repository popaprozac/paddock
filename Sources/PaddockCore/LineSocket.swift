import Darwin
import Dispatch
import Foundation

/// A Unix domain socket server that reads one request line per connection, answers with one
/// line and closes the connection.
///
/// The socket file gets mode 0600, so only its owner can connect. Starting a second server on
/// the same path fails while the first is listening; a socket file left behind by a process
/// that died is replaced.
public final class LineServer: @unchecked Sendable {
    public typealias Reply = @Sendable (String) -> Void

    private let path: String
    private let source: any DispatchSourceRead

    /// Calls `handle` on `queue` with each request line. `handle` must call its reply exactly
    /// once, from any thread, and may do so later.
    public init(
        path: String,
        queue: DispatchQueue,
        handle: @escaping @Sendable (String, @escaping Reply) -> Void
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

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            UnixSocket.configure(client, readTimeout: 5)
            // Reading blocks until the client sends its line, so keep it off `queue`.
            DispatchQueue.global().async {
                guard let line = UnixSocket.readLine(client) else {
                    close(client)
                    return
                }
                queue.async {
                    handle(line) { answer in
                        UnixSocket.writeLine(answer, to: client)
                        close(client)
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.path = path
        self.source = source
    }

    /// Stops accepting connections and removes the socket file.
    public func stop() {
        guard !source.isCancelled else { return }
        source.cancel()
        unlink(path)
    }

    deinit {
        stop()
    }
}

public enum LineClient {
    /// Sends `line` to the server at `path` and waits, without a time limit, for its answer.
    public static func send(_ line: String, to path: String) throws -> String {
        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        UnixSocket.writeLine(line, to: fd)
        guard let answer = UnixSocket.readLine(fd) else {
            throw PaddockError("the server at \(path) closed the connection without answering")
        }
        return answer
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
            guard read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") {
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
        return nil
    }

    static func writeLine(_ line: String, to fd: Int32) {
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            sent += count
        }
    }

    static func error(_ action: String) -> PaddockError {
        PaddockError("can't \(action): \(String(cString: strerror(errno)))")
    }
}
