import Foundation
import Testing
@testable import PaddockCore

@Suite struct DHCPLeasesTests {
    // The format bootpd writes to /var/db/dhcpd_leases: octets lose their leading zeros.
    static let leases = """
        {
        \tip_address=192.168.64.15
        \thw_address=1,ee:57:d:13:98:1f
        \tidentifier=1,ee:57:d:13:98:1f
        \tlease=0x6a0f9fb7
        \tname=WIN-ODE24RUQ5HV
        }
        {
        \tname=Mac
        \tip_address=192.168.64.7
        \thw_address=1,6:5:4:3:2:1
        \tidentifier=1,6:5:4:3:2:1
        \tlease=0x6a0fa001
        }
        """

    @Test func findsTheLeaseForAMACAddressWithLeadingZeros() {
        #expect(DHCPLeases.ipAddress(for: "06:05:04:03:02:01", in: Self.leases) == "192.168.64.7")
        #expect(DHCPLeases.ipAddress(for: "ee:57:0d:13:98:1f", in: Self.leases) == "192.168.64.15")
    }

    @Test func isCaseInsensitive() {
        #expect(DHCPLeases.ipAddress(for: "EE:57:0D:13:98:1F", in: Self.leases) == "192.168.64.15")
    }

    @Test func returnsNilForAnUnknownMAC() {
        #expect(DHCPLeases.ipAddress(for: "aa:bb:cc:dd:ee:ff", in: Self.leases) == nil)
        #expect(DHCPLeases.ipAddress(for: "aa:bb:cc:dd:ee:ff", in: "") == nil)
    }

    @Test func normalizesMACAddresses() {
        #expect(DHCPLeases.normalize("1,6:5:4:3:2:1") == "06:05:04:03:02:01")
        #expect(DHCPLeases.normalize("06:05:04:03:02:01") == "06:05:04:03:02:01")
        #expect(DHCPLeases.normalize("not a mac") == nil)
    }
}
