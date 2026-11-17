import Darwin
import Foundation
import Virtualization

/// A VM's own network, run in userspace by paddock-net instead of macOS's shared NAT, so the
/// host decides what the guest can reach. Virtualization.framework gets one end of a datagram
/// socket pair and paddock-net the other, as its stdin; each datagram is one Ethernet frame.
public final class UserspaceNetwork {
    /// The address paddock-net's DHCP gives the guest; paddock-net's guestIP must match.
    public static let guestIP = "192.168.127.2"

    public let attachment: VZFileHandleNetworkDeviceAttachment
    private let helper: Process

    /// Starts the paddock-net binary at `helper` for a guest with `macAddress`.
    public init(helper url: URL, macAddress: String) throws {
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
        do {
            try process.run()
        } catch {
            throw PaddockError("can't start \(url.path): \(error.localizedDescription); build it with scripts/build.sh")
        }
        try? helperEnd.close()  // paddock-net holds its own copy now
        attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: vmEnd)
        helper = process
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
