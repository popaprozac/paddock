import Darwin
import Foundation

/// Reads `/var/db/dhcpd_leases`, where macOS's DHCP server (bootpd) records the addresses it
/// hands to VMs on the shared NAT network.
public enum DHCPLeases {
    public static let defaultPath = "/var/db/dhcpd_leases"

    public static func ipAddress(for macAddress: String, path: String = defaultPath) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return ipAddress(for: macAddress, in: text)
    }

    /// Finds the address leased to `macAddress` in the text of a leases file.
    public static func ipAddress(for macAddress: String, in leases: String) -> String? {
        guard let wanted = normalize(macAddress) else { return nil }
        var ip: String?
        var hardware: String?
        for rawLine in leases.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                ip = nil
                hardware = nil
            } else if line == "}" {
                if hardware == wanted, let ip { return ip }
            } else if line.hasPrefix("ip_address=") {
                ip = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                hardware = normalize(String(line.dropFirst("hw_address=".count)))
            }
        }
        return nil
    }

    /// bootpd writes `1,6:5:4:3:2:1` (type prefix, no leading zeros); this returns `06:05:04:03:02:01`.
    public static func normalize(_ address: String) -> String? {
        let octets = (address.split(separator: ",").last ?? Substring(address)).split(separator: ":")
        guard octets.count == 6 else { return nil }
        var normalized: [String] = []
        for octet in octets {
            guard let value = UInt8(octet, radix: 16) else { return nil }
            normalized.append(String(format: "%02x", value))
        }
        return normalized.joined(separator: ":")
    }
}

/// A minimal TCP check for an SSH server: connect, read the first line, look for `SSH-`.
public enum SSHProbe {
    public static func banner(host: String, port: UInt16 = 22, timeout: Duration) -> String? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 || errno == EINPROGRESS else { return nil }

        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        guard wait(fd, for: POLLOUT, milliseconds: milliseconds) else { return nil }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { return nil }

        guard wait(fd, for: POLLIN, milliseconds: milliseconds) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[..<count], as: UTF8.self)
        guard text.hasPrefix("SSH-") else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func wait(_ fd: Int32, for event: Int32, milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(event), revents: 0)
        return poll(&descriptor, 1, milliseconds) == 1
    }
}
