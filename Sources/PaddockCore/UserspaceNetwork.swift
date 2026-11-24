import Darwin
import Foundation
import Virtualization

/// A VM's own network, run in userspace by paddock-net instead of macOS's shared NAT, so the
/// host decides what the guest can reach. Virtualization.framework gets one end of a datagram
/// socket pair and paddock-net the other, as its stdin; each datagram is one Ethernet frame.
/// paddock-net's stdout is its control socket: one end of a stream socket pair whose other end
/// only this object holds, so no other process can change the list, and there's no path whose
/// length a socket would limit. The guest reaches nothing until `allow` gives paddock-net a list
/// of names.
public final class UserspaceNetwork {
    /// The address paddock-net's DHCP gives the guest; paddock-net's guestIP must match.
    public static let guestIP = "192.168.127.2"

    public let attachment: VZFileHandleNetworkDeviceAttachment
    private let helper: Process
    private let control: NetworkControl

    /// Starts the paddock-net binary at `helper` for a guest with `macAddress`.
    public init(helper url: URL, macAddress: String) throws {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw PaddockError("can't create paddock-net's control socket: \(String(cString: strerror(errno)))")
        }
        let control = NetworkControl(fd: ends[0])
        UnixSocket.configure(ends[1], readTimeout: nil)
        let helperControl = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw PaddockError("can't create the VM's network socket: \(String(cString: strerror(errno)))")
        }
        // Generous buffers, receive larger than send, so bursts of frames aren't dropped.
        for fd in fds {
            var send: Int32 = 1 << 20
            var receive: Int32 = 4 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        }
        let vmEnd = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let helperEnd = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)

        let process = Process()
        process.executableURL = url
        process.arguments = ["-mac", macAddress]
        process.standardInput = helperEnd
        process.standardOutput = helperControl
        do {
            try process.run()
        } catch {
            throw PaddockError("can't start \(url.path): \(error.localizedDescription); build it with scripts/build.sh")
        }
        try? helperEnd.close()  // paddock-net holds its own copies now
        try? helperControl.close()
        attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmEnd)
        helper = process
        self.control = control
    }

    /// Lets the guest reach `names` and nothing else, replacing the list in force; see
    /// docs/network.md for what an entry matches. Connections already open stay open.
    public func allow(_ names: [String]) throws {
        try control.allow(names)
    }

    /// Stops paddock-net. The guest loses its network.
    public func stop() {
        if helper.isRunning {
            helper.terminate()
        }
    }

    deinit {
        stop()
    }
}

/// paddock's end of paddock-net's control socket: a line of JSON each way per list.
final class NetworkControl: @unchecked Sendable {
    private let lock = NSLock()  // one list at a time, so each answer is read by its own list
    private var fd: Int32  // under lock; -1 once an answer went missing

    init(fd: Int32) {
        UnixSocket.configure(fd, readTimeout: 5)
        self.fd = fd
    }

    /// Sends a list and waits up to 5 s for paddock-net to take it. Once an answer is missing, a
    /// late one could be read as the next list's, so the socket is closed and later lists fail.
    func allow(_ names: [String]) throws {
        let request = try JSONEncoder().encode(["allow": names])
        // paddock-net reads lines of up to 64 KB.
        guard request.count < 64 * 1024 else {
            throw PaddockError("the list is over 64 KB")
        }
        try lock.withLock {
            guard fd >= 0 else {
                throw PaddockError("paddock-net stopped answering, so it takes no more lists")
            }
            guard UnixSocket.writeAll(request + Data("\n".utf8), to: fd), let line = UnixSocket.readLine(fd) else {
                close(fd)
                fd = -1
                throw PaddockError("paddock-net didn't answer")
            }
            guard let answer = try? JSONDecoder().decode([String: String].self, from: Data(line.utf8)) else {
                throw PaddockError("unreadable answer from paddock-net: \(line.prefix(200))")
            }
            if let error = answer["error"] {
                throw PaddockError("paddock-net refused the list: \(error)")
            }
        }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }
}
