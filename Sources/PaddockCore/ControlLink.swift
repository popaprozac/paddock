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
    /// What a client signs instead, so a host's signature never passes for a client's.
    public static let clientContext = Data("paddock-client-v1:".utf8)

    /// What an identity may do: a host serves VMs and reports its slots; a client, a person's CLI
    /// or an agent, asks for them.
    public enum Kind: String, Codable, Sendable {
        case host, client

        var tokenPrefix: String { self == .host ? "pj1" : "pl1" }
    }

    /// A join token (`pj1.`, for a Mac) or a login token (`pl1.`, for a CLI or agent), then
    /// `<secret>.<pin>`, both base64url. The pin is the SHA-256 of the control plane's CA public
    /// key; the secret, used once, lets its holder enroll.
    public struct Token: Equatable, Sendable {
        public let text: String
        public let kind: Kind
        public let pin: Data

        public init(_ text: String) throws {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, let kind = [Kind.host, .client].first(where: { $0.tokenPrefix == parts[0] }),
                  let secret = Data(base64URL: String(parts[1])), secret.count == 32,
                  let pin = Data(base64URL: String(parts[2])), pin.count == 32
            else {
                throw PaddockError("that isn't a paddock token: make one with 'paddock-control join-token' for a Mac, "
                    + "or 'paddock-control login-token' to log in")
            }
            self.text = text
            self.kind = kind
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

    /// What a Mac takes from the control plane over its link: serve's VM operations, naming no file
    /// on the Mac. A request from the link that named one could reach any file serve's user can,
    /// so a screenshot from the link gets a file the Mac picks itself, and task, which reads and
    /// writes bundles, doesn't come over the link yet.
    public static let remoteOperations: Set<String> = ["acquire", "release", "exec", "axtree", "input", "screenshot"]

    /// The most a piece of a file sent over a link holds.
    public static let chunkSize = 256 * 1024

    /// `line`, one of serve's requests, if a Mac takes it from the control plane; or why not.
    public static func checkRemote(_ line: String) throws -> String {
        guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let op = request["op"] as? String
        else { throw PaddockError("that isn't one of serve's requests") }
        guard remoteOperations.contains(op) else {
            throw PaddockError("this Mac doesn't take '\(op)' from the control plane")
        }
        guard request["bundle"] == nil, request["result"] == nil else {
            throw PaddockError("a request from the control plane can't name a file on this Mac")
        }
        return line
    }

    /// The answer to a link's challenge: an ECDSA signature, in DER, over the SHA-256 of the
    /// context (a host's, unless given) and the control plane's bytes.
    public static func answer(_ nonce: Data, with key: P256.Signing.PrivateKey, context: Data = context) throws -> Data {
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
        public var client: String?  // a client's auth and welcome: its ID
        public var id: String?      // request and response: pairs them on one link
        public var op: String?      // request: hosts or logout
        public var hosts: [HostStatus]?
        public var error: String?   // response: why the request failed
        public var done: Bool?      // response: the request's last answer
        public var serve: String?   // request to a host: one of serve's request lines
        public var line: String?    // response from a host: one of serve's answer lines
        public var data: Data?      // response: a piece of a file, such as a screenshot, in order
        public var note: String?    // response: news for whoever waits, such as no free VM

        public init(type: String, nonce: Data? = nil, host: String? = nil, signature: Data? = nil, name: String? = nil,
                    version: String? = nil, macos: String? = nil, image: String? = nil, cpus: Int? = nil,
                    memory: UInt64? = nil, diskFree: UInt64? = nil, slots: [SlotReport]? = nil, client: String? = nil,
                    id: String? = nil, op: String? = nil, done: Bool? = nil, line: String? = nil,
                    data: Data? = nil, serve: String? = nil) {
            self.type = type
            self.nonce = nonce
            self.host = host
            self.client = client
            self.id = id
            self.op = op
            self.done = done
            self.line = line
            self.data = data
            self.serve = serve
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

    /// A Mac in the pool, as the control plane reports it to a client.
    public struct HostStatus: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var enrolled: Date
        public var online: Bool
        public var remote: String?
        public var connected: Date?
        public var lastSeen: Date?
        public var version: String?
        public var macos: String?
        public var image: String?
        public var cpus: Int?
        public var memory: UInt64?
        public var diskFree: UInt64?
        public var slots: [SlotReport]?
    }

    public struct EnrollRequest: Codable, Sendable {
        public var token: String
        public var name: String
        public var publicKey: Data  // SubjectPublicKeyInfo DER
        public var `as`: Kind

        public init(token: String, name: String, publicKey: Data, as kind: Kind) {
            self.token = token
            self.name = name
            self.publicKey = publicKey
            self.as = kind
        }
    }

    public struct EnrollResponse: Codable, Sendable {
        public var host: String?
        public var client: String?
        public var error: String?
    }

    /// Reads the control plane's JSON: its times are RFC 3339, with fractions of a second.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 time: \(text)"))
        }
        return decoder
    }

    /// The name a Mac enrolls and reports with: what paddock-control accepts, 1 to 64 printable
    /// characters.
    public static func hostName(_ name: String) -> String {
        let printable = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(64))
    }
}

/// What a Mac (a host) or a CLI (a client) keeps once it joins a control plane: where it is, the ID
/// it was given, the CA it trusts there and nothing else, and its own private key, in a folder only
/// its user can read. The private key never leaves the Mac.
public struct ControlIdentity: Equatable, Sendable {
    public var kind: ControlLink.Kind
    public var url: URL
    public var id: String
    public var authority: Data  // the CA certificate, DER
    public var key: P256.Signing.PrivateKey

    public init(kind: ControlLink.Kind, url: URL, id: String, authority: Data, key: P256.Signing.PrivateKey) {
        self.kind = kind
        self.url = url
        self.id = id
        self.authority = authority
        self.key = key
    }

    public static func == (a: ControlIdentity, b: ControlIdentity) -> Bool {
        a.kind == b.kind && a.url == b.url && a.id == b.id && a.authority == b.authority
            && a.key.rawRepresentation == b.key.rawRepresentation
    }

    /// The saved form: a host's ID under "host", as serve first wrote it, a client's under "client".
    private struct Record: Codable {
        var url: URL
        var host: String?
        var client: String?
        var authority: Data
    }

    /// The folder in a paddock home: `host/` or `client/`, apart from `control/`, which is the
    /// control plane's own when it runs on the same Mac.
    public static func folder(in home: PaddockHome, for kind: ControlLink.Kind) -> URL {
        home.root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// The identity of `kind` saved in `folder`, or nil if there's none.
    public static func load(_ kind: ControlLink.Kind, from folder: URL) throws -> ControlIdentity? {
        let recordURL = folder.appendingPathComponent("\(kind.rawValue).json")
        let keyURL = folder.appendingPathComponent("\(kind.rawValue).key")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        guard let id = kind == .host ? record.host : record.client else {
            throw PaddockError("\(recordURL.path) has no \(kind.rawValue) ID")
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        return ControlIdentity(kind: kind, url: record.url, id: id, authority: record.authority, key: key)
    }

    /// Saves the identity, replacing any other of its kind, with the folder 0700 and its files 0600.
    public func save(to folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let record = Record(url: url, host: kind == .host ? id : nil, client: kind == .client ? id : nil, authority: authority)
        try Self.writePrivate(key.rawRepresentation, to: folder.appendingPathComponent("\(kind.rawValue).key"))
        try Self.writePrivate(try JSONEncoder().encode(record), to: folder.appendingPathComponent("\(kind.rawValue).json"))
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
