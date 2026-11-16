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
