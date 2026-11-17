import Darwin
import Foundation
import Virtualization

/// A VM's own network, run in userspace by paddock-net instead of macOS's shared NAT, so the
/// host decides what the guest can reach. Virtualization.framework gets one end of a datagram
/// socket pair and paddock-net the other, as its stdin; each datagram is one Ethernet frame.
/// The guest reaches nothing until `allow` gives paddock-net a list of names.
public final class UserspaceNetwork {
    /// The address paddock-net's DHCP gives the guest; paddock-net's guestIP must match.
    public static let guestIP = "192.168.127.2"

    public let attachment: VZFileHandleNetworkDeviceAttachment
    private let helper: Process
    private let controlPath: String

    /// Starts the paddock-net binary at `helper` for a guest with `macAddress`. paddock-net
    /// takes new lists on a Unix socket it creates at `controlPath`, which only this user can open.
    public init(helper url: URL, macAddress: String, controlPath: String) throws {
        _ = try UnixSocket.address(controlPath)  // fail here, not at Assign, if the path is too long
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
        process.arguments = ["-mac", macAddress, "-control", controlPath]
        process.standardInput = helperEnd
        do {
            try process.run()
        } catch {
            throw PaddockError("can't start \(url.path): \(error.localizedDescription); build it with scripts/build.sh")
        }
        try? helperEnd.close()  // paddock-net holds its own copy now
        attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmEnd)
        helper = process
        self.controlPath = controlPath
    }

    /// Lets the guest reach `names` and nothing else, replacing the list in force; see the
    /// README for what an entry matches. Connections already open stay open.
    public func allow(_ names: [String]) throws {
        try Self.allow(names, at: controlPath)
    }

    /// Sends a list to the paddock-net listening at `path` and waits up to 5 s for it to take it.
    static func allow(_ names: [String], at path: String) throws {
        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        UnixSocket.configure(fd, readTimeout: 5)
        let request = try JSONEncoder().encode(["allow": names])
        UnixSocket.writeLine(String(decoding: request, as: UTF8.self), to: fd)
        guard let line = UnixSocket.readLine(fd) else {
            throw PaddockError("paddock-net didn't answer at \(path)")
        }
        guard let answer = try? JSONDecoder().decode([String: String].self, from: Data(line.utf8)) else {
            throw PaddockError("unreadable answer from paddock-net: \(line.prefix(200))")
        }
        if let error = answer["error"] {
            throw PaddockError("paddock-net refused the list: \(error)")
        }
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
