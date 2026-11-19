import CryptoKit
import Foundation
import Testing
@testable import PaddockCore

@Suite struct ControlLinkTests {
    private let secret = String(repeating: "A", count: 43)  // 32 zero bytes in base64url
    private let pin = String(repeating: "_", count: 42) + "8"  // 32 bytes of 0xFF

    @Test func readsJoinAndLoginTokens() throws {
        let join = try ControlLink.Token("  pj1.\(secret).\(pin)\n")
        #expect(join.text == "pj1.\(secret).\(pin)" && join.kind == .host)
        #expect(join.pin == Data(repeating: 0xFF, count: 32))
        #expect(try ControlLink.Token("pl1.\(secret).\(pin)").kind == .client)
        for junk in ["", "pj1.", "pj2.\(secret).\(pin)", "pj1.\(secret)", "pj1.abc.\(pin)", "pj1.\(secret).\(pin).x"] {
            #expect(throws: PaddockError.self) { try ControlLink.Token(junk) }
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
        // A client signs over its own context, so its answer never passes as a host's.
        let asClient = try P256.Signing.ECDSASignature(
            derRepresentation: ControlLink.answer(nonce, with: key, context: ControlLink.clientContext))
        #expect(key.publicKey.isValidSignature(asClient, for: Data("paddock-client-v1:".utf8) + nonce))
        #expect(!key.publicKey.isValidSignature(asClient, for: Data("paddock-link-v1:".utf8) + nonce))
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

    @Test func keepsEachIdentityPrivateAndReadsItBack() throws {
        let tmp = try TemporaryDirectory()
        let home = PaddockHome(root: tmp.url)
        let folder = ControlIdentity.folder(in: home, for: .host)
        #expect(folder.lastPathComponent == "host" && ControlIdentity.folder(in: home, for: .client).lastPathComponent == "client")
        #expect(try ControlIdentity.load(.host, from: folder) == nil)
        let identity = ControlIdentity(kind: .host, url: URL(string: "https://studio.local:7443")!, id: "host-0123",
                                       authority: Data([1, 2]), key: P256.Signing.PrivateKey())
        try identity.save(to: folder)
        #expect(try ControlIdentity.load(.host, from: folder) == identity)
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0 }
        #expect(mode(folder.path) == 0o700)
        #expect(mode(folder.appendingPathComponent("host.key").path) == 0o600)
        #expect(mode(folder.appendingPathComponent("host.json").path) == 0o600)
        let replaced = ControlIdentity(kind: .host, url: identity.url, id: "host-4567", authority: Data([3]),
                                       key: P256.Signing.PrivateKey())
        try replaced.save(to: folder)
        #expect(try ControlIdentity.load(.host, from: folder) == replaced)
        let clientFolder = ControlIdentity.folder(in: home, for: .client)
        let client = ControlIdentity(kind: .client, url: identity.url, id: "client-89ab", authority: Data([1, 2]),
                                     key: P256.Signing.PrivateKey())
        try client.save(to: clientFolder)
        #expect(try ControlIdentity.load(.client, from: clientFolder) == client)
        #expect(FileManager.default.fileExists(atPath: clientFolder.appendingPathComponent("client.key").path))
    }

    /// What `serve --join` saved before clients existed, as on a Mac that joined already.
    @Test func readsAHostIdentitySavedBeforeClients() throws {
        let tmp = try TemporaryDirectory()
        let key = P256.Signing.PrivateKey()
        try Data(#"{"url":"https:\/\/studio.local:7443","host":"host-0123","authority":"AQI="}"#.utf8)
            .write(to: tmp.url.appendingPathComponent("host.json"))
        try key.rawRepresentation.write(to: tmp.url.appendingPathComponent("host.key"))
        let loaded = try #require(try ControlIdentity.load(.host, from: tmp.url))
        #expect(loaded.id == "host-0123" && loaded.kind == .host && loaded.authority == Data([1, 2]))
    }

    @Test func readsTheControlPlanesTimes() throws {
        let json = #"[{"id":"host-1","name":"Studio","enrolled":"2026-11-18T12:58:05.123456-08:00","online":true,"#
            + #""lastSeen":"2026-11-18T20:58:06Z","slots":[{"number":1,"state":"warm"}]}]"#
        let hosts = try ControlLink.decoder().decode([ControlLink.HostStatus].self, from: Data(json.utf8))
        // ISO8601DateFormatter keeps milliseconds, plenty for showing a time.
        #expect(abs((hosts.first?.enrolled.timeIntervalSince1970 ?? 0) - 1_795_035_485.123) < 0.001)
        #expect(hosts.first?.lastSeen?.timeIntervalSince1970 == 1_795_035_486)
        #expect(hosts.first?.slots?.first?.state == "warm")
    }

    @Test func keepsTheHostNameToWhatTheControlPlaneTakes() {
        #expect(ControlLink.hostName("Zach's Mac Studio") == "Zach's Mac Studio")
        #expect(ControlLink.hostName(" \u{7}\n ") == "Mac")
        #expect(ControlLink.hostName(String(repeating: "x", count: 80)).count == 64)
    }

    /// A Mac takes only VM operations from its link, never one naming a file on it.
    @Test func takesOnlyVMOperationsThatNameNoFileFromTheLink() throws {
        for line in [#"{"op":"acquire","allow":["github.com"]}"#, #"{"op":"exec","vm":"v","command":"ls"}"#,
                     #"{"op":"release","vm":"v"}"#, #"{"op":"axtree","vm":"v"}"#, #"{"op":"input","vm":"v"}"#] {
            #expect(try ControlLink.checkRemote(line) == line)
        }
        for line in [#"{"op":"task","vm":"v","bundle":"/etc/passwd","result":"/tmp/x"}"#,
                     #"{"op":"screenshot","vm":"v","result":"/Users/zach/.ssh/authorized_keys"}"#,
                     #"{"op":"exec","vm":"v","command":"ls","result":"/tmp/x"}"#, #"{"vm":"v"}"#, "not json"] {
            #expect(throws: PaddockError.self) { try ControlLink.checkRemote(line) }
        }
    }
}

@Suite struct ResponderPipeTests {
    @Test func passesWhatAHandlerSendsLineByLine() async throws {
        let (responder, lines) = try ResponderPipe.make()
        responder.send("first")
        responder.send(lines: ["second", "third"])
        responder.finish("last")
        var got: [String] = []
        for await line in lines { got.append(line) }
        #expect(got == ["first", "second", "third", "last"])
    }

    @Test func endsWhenAHandlerDropsItsResponder() async throws {
        var lines: AsyncStream<String>
        do {
            let (responder, stream) = try ResponderPipe.make()
            responder.send("only")
            lines = stream
        }
        var got: [String] = []
        for await line in lines { got.append(line) }
        #expect(got == ["only"])
    }
}
