import CryptoKit
import Foundation
import Testing
@testable import PaddockCore

@Suite struct ControlLinkTests {
    private let secret = String(repeating: "A", count: 43)  // 32 zero bytes in base64url
    private let pin = String(repeating: "_", count: 42) + "8"  // 32 bytes of 0xFF

    @Test func readsAJoinToken() throws {
        let token = try ControlLink.JoinToken("  pj1.\(secret).\(pin)\n")
        #expect(token.text == "pj1.\(secret).\(pin)")
        #expect(token.pin == Data(repeating: 0xFF, count: 32))
        for junk in ["", "pj1.", "pj2.\(secret).\(pin)", "pj1.\(secret)", "pj1.abc.\(pin)", "pj1.\(secret).\(pin).x"] {
            #expect(throws: PaddockError.self) { try ControlLink.JoinToken(junk) }
        }
    }

    /// The pin is over the key's SubjectPublicKeyInfo, as Go's x509 writes it and CryptoKit does.
    @Test func pinsAP256KeyByItsKeyInfo() {
        let key = P256.Signing.PrivateKey().publicKey
        #expect(ControlLink.p256KeyInfoPrefix + key.x963Representation == key.derRepresentation)
        #expect(ControlLink.pin(ofP256Point: key.x963Representation) == Data(SHA256.hash(data: key.derRepresentation)))
        #expect(ControlLink.pin(ofP256Point: Data(repeating: 4, count: 33)) == nil)
    }

    /// What the control plane checks: the signature over context and nonce, under the enrolled key.
    @Test func answersAChallengeWithTheEnrolledKey() throws {
        let key = P256.Signing.PrivateKey()
        let nonce = Data((0..<32).map { UInt8($0) })
        let answer = try ControlLink.answer(nonce, with: key)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: answer)
        #expect(key.publicKey.isValidSignature(signature, for: Data("paddock-link-v1:".utf8) + nonce))
        #expect(!key.publicKey.isValidSignature(signature, for: nonce))
    }

    @Test func reportsEachSlotsState() {
        #expect(ControlLink.SlotReport(number: 1, emptyReason: nil, assigned: false, warm: true, vm: "a").state == "warm")
        #expect(ControlLink.SlotReport(number: 1, emptyReason: nil, assigned: true, warm: true, vm: "a").state == "assigned")
        #expect(ControlLink.SlotReport(number: 1, emptyReason: nil, assigned: false, warm: false, vm: "a").state == "preparing")
        let empty = ControlLink.SlotReport(number: 2, emptyReason: "no disk", assigned: false, warm: false, vm: "a")
        #expect(empty.state == "empty" && empty.reason == "no disk" && empty.vm == nil)
    }

    /// The Go side's names: type, nonce, host, signature, macos, diskFree, slots, number, state.
    @Test func writesMessagesWithTheControlPlanesFieldNames() throws {
        let hello = ControlLink.Message(type: "capacity", diskFree: 7,
                                        slots: [.init(number: 1, emptyReason: nil, assigned: false, warm: true, vm: "v")])
        let json = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)
        #expect(json.contains(#""type":"capacity""#) && json.contains(#""diskFree":7"#))
        #expect(json.contains(#""number":1"#) && json.contains(#""state":"warm""#) && !json.contains("nonce"))
        let challenge = try JSONDecoder().decode(ControlLink.Message.self, from: Data(#"{"type":"challenge","nonce":"AAEC"}"#.utf8))
        #expect(challenge.nonce == Data([0, 1, 2]))
    }

    @Test func keepsTheIdentityPrivateAndReadsItBack() throws {
        let tmp = try TemporaryDirectory()
        let folder = tmp.url.appendingPathComponent("host")
        #expect(try HostIdentity.load(from: folder) == nil)
        let identity = HostIdentity(url: URL(string: "https://studio.local:7443")!, host: "host-0123", authority: Data([1, 2]),
                                    key: P256.Signing.PrivateKey())
        try identity.save(to: folder)
        #expect(try HostIdentity.load(from: folder) == identity)
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0 }
        #expect(mode(folder.path) == 0o700)
        #expect(mode(folder.appendingPathComponent("host.key").path) == 0o600)
        #expect(mode(folder.appendingPathComponent("host.json").path) == 0o600)
        let replaced = HostIdentity(url: identity.url, host: "host-4567", authority: Data([3]), key: P256.Signing.PrivateKey())
        try replaced.save(to: folder)
        #expect(try HostIdentity.load(from: folder) == replaced)
    }

    @Test func keepsTheHostNameToWhatTheControlPlaneTakes() {
        #expect(ControlLink.hostName("Zach's Mac Studio") == "Zach's Mac Studio")
        #expect(ControlLink.hostName(" \u{7}\n ") == "Mac")
        #expect(ControlLink.hostName(String(repeating: "x", count: 80)).count == 64)
    }
}
