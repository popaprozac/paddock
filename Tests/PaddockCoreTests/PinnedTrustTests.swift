import Foundation
import Security
import Testing
@testable import PaddockCore

/// The certificates are shaped as paddock-control's pki.go makes them, with fixed dates: two CAs
/// with the same name, and a server certificate for control.test, valid in January 2026, from each.
@Suite struct PinnedTrustTests {
    @Test func acceptsTheServerOfThePinnedCA() throws {
        let trust = PinnedTrust(.pin(try #require(PinnedTrust.pin(of: Self.authorityA))))
        #expect(trust.accepts(Self.chain(Self.serverA, Self.authorityA), host: "control.test"))
        #expect(trust.matchedAuthority.map { CFEqual($0, Self.authorityA) } == true)
        #expect(trust.failure == nil)
    }

    /// Anyone can put the real CA's certificate in a chain: what counts is who signed the server's.
    @Test func refusesAnotherCAsServerEvenWithThePinnedCAInItsChain() throws {
        let pin = try #require(PinnedTrust.pin(of: Self.authorityA))
        for chain in [Self.chain(Self.serverB, Self.authorityA), Self.chain(Self.serverB, Self.authorityB)] {
            let trust = PinnedTrust(.pin(pin))
            #expect(!trust.accepts(chain, host: "control.test"))
            #expect(trust.failure?.contains("isn't the control plane the join token is for") == true)
            #expect(trust.matchedAuthority == nil)
        }
    }

    @Test func acceptsOnlyTheSavedCAsServerForItsName() {
        #expect(PinnedTrust(.authority(Self.authorityA)).accepts(Self.chain(Self.serverA, Self.authorityA), host: "control.test"))
        #expect(!PinnedTrust(.authority(Self.authorityA)).accepts(Self.chain(Self.serverB, Self.authorityB), host: "control.test"))
        #expect(!PinnedTrust(.authority(Self.authorityB)).accepts(Self.chain(Self.serverA, Self.authorityA), host: "control.test"))
        let elsewhere = PinnedTrust(.authority(Self.authorityA))
        #expect(!elsewhere.accepts(Self.chain(Self.serverA, Self.authorityA), host: "other.test"))
        #expect(elsewhere.failure?.contains("start it with --name other.test") == true)
    }

    /// A server's chain as a TLS handshake hands it over, checked in the middle of January 2026,
    /// with nothing fetched from the network.
    private static func chain(_ certificates: SecCertificate...) -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, nil), &trust)
        SecTrustSetVerifyDate(trust!, Date(timeIntervalSince1970: 1_768_435_200) as CFDate)  // 2026-01-15
        SecTrustSetNetworkFetchAllowed(trust!, false)
        return trust!
    }

    private static func certificate(_ base64: String) -> SecCertificate {
        SecCertificateCreateWithData(nil, Data(base64Encoded: base64)! as CFData)!
    }

    private static let authorityA = certificate(
        "MIIBejCCASCgAwIBAgIBAjAKBggqhkjOPQQDAjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUgQ0Ew" +
        "HhcNMjYwMTAxMDAwMDAwWhcNNDYwMTAxMDAwMDAwWjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUg" +
        "Q0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT/wz+sj9wpSbEB181NSe64aHm8f22Vu891JF8v3HeyKO1mlz7Z" +
        "RN8bVkiRIxgW6FumddluHenCwcV31+pmPZE2o0UwQzAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgwBgEB/wIB" +
        "ADAdBgNVHQ4EFgQUJpIg/Ky2U/+LKuT/qKlfyFQF4fEwCgYIKoZIzj0EAwIDSAAwRQIgCO8tWA3V1aH1SbzkLkc2" +
        "MXyyr9nh2WBfWl/Fsh9tXAMCIQC/v6KV9Q46dtP0BdCcYV0IiSrT0Bb0P7072XTdiOSDTA==")
    private static let serverA = certificate(
        "MIIBkjCCATmgAwIBAgIBBDAKBggqhkjOPQQDAjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUgQ0Ew" +
        "HhcNMjYwMTAxMDAwMDAwWhcNMjYwMTMxMDAwMDAwWjAgMR4wHAYDVQQDExVwYWRkb2NrIGNvbnRyb2wgcGxhbmUw" +
        "WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASMCte16EeR/r9GmjshGU0DKrqaPUNycRJ5DWzg6uHFskiw/ECfsqYC" +
        "CZJTFwVhfmNXPiSAJucVbWvm0L8oXQr+o2EwXzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEw" +
        "HwYDVR0jBBgwFoAUJpIg/Ky2U/+LKuT/qKlfyFQF4fEwFwYDVR0RBBAwDoIMY29udHJvbC50ZXN0MAoGCCqGSM49" +
        "BAMCA0cAMEQCIG3N4qI+p+u/n+eNpZyYBVtjoA0GlpresHpIH8rGvfXnAiBtvCCYr1IhJZbciHbkw2WqS/duiXQw" +
        "WnKaX0rohj5xVw==")
    private static let authorityB = certificate(
        "MIIBeTCCASCgAwIBAgIBAzAKBggqhkjOPQQDAjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUgQ0Ew" +
        "HhcNMjYwMTAxMDAwMDAwWhcNNDYwMTAxMDAwMDAwWjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUg" +
        "Q0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASJOPoi4zxa0KdzQbZHWCxS5aQqn3rZqHO7K5W25C8Eig40Adwi" +
        "PSONf45geGxLO2bQ5833lVzqGLEwbVJyVsz3o0UwQzAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgwBgEB/wIB" +
        "ADAdBgNVHQ4EFgQUk+JwXW4FmWrwsOhyNG38r5HzdSswCgYIKoZIzj0EAwIDRwAwRAIgFEQYWfnFCVsU8SAF+h4D" +
        "4re7y5j4XBzlDGv3hQSzoqICIDECWJNC4IDxVDcHat/McEXOxWgNdrRhlE6uZCCI2q5j")
    private static let serverB = certificate(
        "MIIBkjCCATmgAwIBAgIBBTAKBggqhkjOPQQDAjAjMSEwHwYDVQQDExhwYWRkb2NrIGNvbnRyb2wgcGxhbmUgQ0Ew" +
        "HhcNMjYwMTAxMDAwMDAwWhcNMjYwMTMxMDAwMDAwWjAgMR4wHAYDVQQDExVwYWRkb2NrIGNvbnRyb2wgcGxhbmUw" +
        "WTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASycsoRNAHHf+I54v08uovh2l10eRnosofKZFgqorBwkRYoTe/zeUOU" +
        "tHZgs9i7KoWIpQejH0tEqV3iSGCvw+KXo2EwXzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEw" +
        "HwYDVR0jBBgwFoAUk+JwXW4FmWrwsOhyNG38r5HzdSswFwYDVR0RBBAwDoIMY29udHJvbC50ZXN0MAoGCCqGSM49" +
        "BAMCA0cAMEQCIFX3FCObgAbrMtJR6L95yIVhX2yU2LbDsz21yXzUn+zIAiAfYu9KfCbp/zrrqw3Jsw86LM6M1UXY" +
        "pfvZoWez4HwN7A==")
}
