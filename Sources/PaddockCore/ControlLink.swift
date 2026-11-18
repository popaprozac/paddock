import CryptoKit
import Foundation

/// The link between `paddock serve` and paddock-control, the control plane: what a Mac sends and
/// checks, matching paddock-control's Go side. A Mac joins once with a join token, which pins the
/// control plane's CA, and keeps a P-256 key; every link then starts with the control plane's
/// random bytes, which the Mac signs.
public enum ControlLink {
    /// What a Mac signs ahead of the control plane's random bytes, so the signature can't be
    /// taken for one made for anything else.
    public static let context = Data("paddock-link-v1:".utf8)

    /// A join token: `pj1.<secret>.<pin>`, both base64url. The pin is the SHA-256 of the control
    /// plane's CA public key; the secret, used once, lets the Mac enroll.
    public struct JoinToken: Equatable, Sendable {
        public let text: String
        public let pin: Data

        public init(_ text: String) throws {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "pj1",
                  let secret = Data(base64URL: String(parts[1])), secret.count == 32,
                  let pin = Data(base64URL: String(parts[2])), pin.count == 32
            else {
                throw PaddockError("that isn't a paddock join token: make one with 'paddock-control join-token'")
            }
            self.text = text
            self.pin = pin
        }
    }

    /// The DER that starts every P-256 public key's SubjectPublicKeyInfo, before its 65-byte
    /// uncompressed point.
    static let p256KeyInfoPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    /// The pin of a P-256 public key given as its uncompressed point (what Security returns for
    /// a certificate's key), or nil for any other key.
    public static func pin(ofP256Point point: Data) -> Data? {
        guard point.count == 65, point.first == 0x04 else { return nil }
        return Data(SHA256.hash(data: p256KeyInfoPrefix + point))
    }

    /// The answer to a link's challenge: an ECDSA signature, in DER, over the SHA-256 of
    /// `context` and the control plane's bytes.
    public static func answer(_ nonce: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: context + nonce).derRepresentation
    }

    /// Every message on the link, as one JSON object, with the Go side's field names.
    public struct Message: Codable, Equatable, Sendable {
        public var type: String  // challenge, auth, welcome, hello, capacity
        public var nonce: Data?
        public var host: String?
        public var signature: Data?
        public var name: String?
        public var version: String?
        public var macos: String?
        public var image: String?
        public var cpus: Int?        // hello: this Mac's cores
        public var memory: UInt64?   // hello: this Mac's memory, in bytes
        public var diskFree: UInt64? // capacity: free space for VMs, in bytes
        public var slots: [SlotReport]?

        public init(type: String, nonce: Data? = nil, host: String? = nil, signature: Data? = nil, name: String? = nil,
                    version: String? = nil, macos: String? = nil, image: String? = nil, cpus: Int? = nil,
                    memory: UInt64? = nil, diskFree: UInt64? = nil, slots: [SlotReport]? = nil) {
            self.type = type
            self.nonce = nonce
            self.host = host
            self.signature = signature
            self.name = name
            self.version = version
            self.macos = macos
            self.image = image
            self.cpus = cpus
            self.memory = memory
            self.diskFree = diskFree
            self.slots = slots
        }
    }

    /// One of serve's slots, as the control plane sees it.
    public struct SlotReport: Codable, Equatable, Sendable {
        public var number: Int
        public var state: String  // warm, assigned, preparing or empty
        public var vm: String?
        public var reason: String?

        public init(number: Int, emptyReason: String?, assigned: Bool, warm: Bool, vm: String?) {
            self.number = number
            state = emptyReason != nil ? "empty" : assigned ? "assigned" : warm ? "warm" : "preparing"
            self.vm = emptyReason == nil ? vm : nil
            reason = emptyReason
        }
    }

    public struct EnrollRequest: Codable, Sendable {
        public var token: String
        public var name: String
        public var publicKey: Data  // SubjectPublicKeyInfo DER

        public init(token: String, name: String, publicKey: Data) {
            self.token = token
            self.name = name
            self.publicKey = publicKey
        }
    }

    public struct EnrollResponse: Codable, Sendable {
        public var host: String?
        public var error: String?
    }

    /// The name a Mac enrolls and reports with: what paddock-control accepts, 1 to 64 printable
    /// characters.
    public static func hostName(_ name: String) -> String {
        let printable = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(64))
    }
}

/// What a Mac keeps once it joins a control plane: where it is, the ID it was given, the CA it
/// trusts there and nothing else, and its own private key, in a folder only its user can read.
/// The private key never leaves the Mac.
public struct HostIdentity: Equatable, Sendable {
    public var url: URL
    public var host: String
    public var authority: Data  // the CA certificate, DER
    public var key: P256.Signing.PrivateKey

    public init(url: URL, host: String, authority: Data, key: P256.Signing.PrivateKey) {
        self.url = url
        self.host = host
        self.authority = authority
        self.key = key
    }

    public static func == (a: HostIdentity, b: HostIdentity) -> Bool {
        a.url == b.url && a.host == b.host && a.authority == b.authority && a.key.rawRepresentation == b.key.rawRepresentation
    }

    private struct Record: Codable {
        var url: URL
        var host: String
        var authority: Data
    }

    /// The folder in a paddock home: `host/`, apart from `control/`, which is the control plane's
    /// own when both run on one Mac.
    public static func folder(in home: PaddockHome) -> URL {
        home.root.appendingPathComponent("host", isDirectory: true)
    }

    /// The identity saved in `folder`, or nil if this Mac hasn't joined.
    public static func load(from folder: URL) throws -> HostIdentity? {
        let recordURL = folder.appendingPathComponent("host.json"), keyURL = folder.appendingPathComponent("host.key")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        return HostIdentity(url: record.url, host: record.host, authority: record.authority, key: key)
    }

    /// Saves the identity, replacing any other, with the folder 0700 and its files 0600.
    public func save(to folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let record = try JSONEncoder().encode(Record(url: url, host: host, authority: authority))
        try Self.writePrivate(key.rawRepresentation, to: folder.appendingPathComponent("host.key"))
        try Self.writePrivate(record, to: folder.appendingPathComponent("host.json"))
    }

    /// Writes through a temporary file created 0600, so the data is never readable by others,
    /// even for a moment, and a crash never leaves half a file.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PaddockError("can't write \(url.path)")
        }
        // rename(2), not FileManager's replace, which can carry the old file's permissions over.
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw PaddockError("can't write \(url.path): \(reason)")
        }
    }
}

extension Data {
    /// Decodes base64url without padding, as Go's RawURLEncoding writes it.
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
