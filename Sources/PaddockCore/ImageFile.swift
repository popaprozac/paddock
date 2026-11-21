import Foundation

/// An image file: what `paddock build <file>` makes a golden image from, written in YAML. It
/// decodes with any Decoder, so PaddockCore needs no YAML parser. Every mapping's keys are
/// checked, so a misspelled key fails with its path instead of being ignored; `describe` turns a
/// failure into one line.
///
/// ```yaml
/// from: { macos: latest }      # or { ipsw: path/to/restore.ipsw }, which pins the version;
///                              # or for Linux { debian: 13 }, { debian: 13, variant: generic },
///                              # { disk: path/to/image.tar.xz } or { url: https://..., sha256: <hash> }
/// vm: { cpus: 4, memory: 8, disk: 80 }
/// account: { name: bench, full-name: Bench }
/// license: accept              # leave out and a person accepts it
/// grants: recovery             # or managed, the default
/// share: installers            # a host folder, read-only in the guest
/// steps:
///   - name: Homebrew
///     as: user                 # or root
///     run: |
///       ...
/// ```
public struct ImageFile: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The latest macOS this Mac supports.
        case latest
        /// A restore image file, which pins the version.
        case ipsw(String)
        /// The latest build of a Debian release's arm64 image in a variant Debian publishes, from
        /// cloud.debian.org: genericcloud unless the file says generic.
        case debian(Int, LinuxImage.Debian.Variant)
        /// A Linux disk you keep, which pins the build: a genericcloud `.tar.xz` as Debian
        /// publishes it, or a raw disk image.
        case disk(String)
        /// A Linux disk to download, as `disk` takes them, which must match its hash: the hash pins
        /// the build, wherever the file is.
        case url(URL, LinuxImage.Checksum)

        public var isLinux: Bool {
            switch self {
            case .latest, .ipsw: false
            case .debian, .disk, .url: true
            }
        }
    }

    /// The Debian releases `from: { debian: N }` builds from.
    public static let debianReleases = LinuxImage.debianCodenames.keys.sorted()

    /// How the helpers' privacy grants get into the image: `managed` leaves them to a person or
    /// clicking them once in the image, `recovery` has `paddock grant` write them.
    public enum Grants: String, CaseIterable, Sendable {
        case managed, recovery
    }

    public enum User: String, CaseIterable, Sendable {
        case user, root
    }

    /// Sizes for the new VM; nil takes `paddock install`'s default.
    public struct VM: Equatable, Sendable {
        public var cpus: Int?
        /// In GB.
        public var memory: Int?
        /// In GB.
        public var disk: Int?

        public init(cpus: Int? = nil, memory: Int? = nil, disk: Int? = nil) {
            self.cpus = cpus
            self.memory = memory
            self.disk = disk
        }
    }

    /// The account the build creates. Its name is checked where the account is made.
    public struct Account: Equatable, Sendable {
        public var name: String
        public var fullName: String?
    }

    /// A shell script the build runs in the guest after its first boot, as `user`.
    public struct Step: Equatable, Sendable {
        public var name: String
        public var user: User
        public var run: String
    }

    /// The VM's name; nil means the file's name.
    public var name: String?
    public var from: Source
    public var vm: VM
    public var account: Account
    public var acceptsLicense: Bool
    public var grants: Grants
    /// As written: relative to the image file's folder unless it starts with "/".
    public var share: String?
    /// A Linux image runs x86-64 Linux programs through Rosetta.
    public var rosetta = false
    /// The build must find a working desktop in a Linux image, or fail. It looks for one either way.
    public var desktop = false
    public var steps: [Step]

    /// One line for a file that doesn't decode: where, then what, as in
    /// "steps[1].as: expected user or root, not admin".
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])): missing"
        case let .valueNotFound(_, context):
            return "\(path(context.codingPath)): needs a value"
        case let .typeMismatch(type, context):
            let expected = switch type {
            case is String.Type: "text"
            case is Int.Type: "a whole number"
            case is [Any].Type: "a list"
            default: "keys and values"
            }
            return "\(path(context.codingPath)): expected \(expected)"
        case let .dataCorrupted(context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        guard !keys.isEmpty else { return "the file" }
        return keys.enumerated().map { index, key in
            if let item = key.intValue { return "[\(item)]" }
            return index == 0 ? key.stringValue : ".\(key.stringValue)"
        }.joined()
    }
}

extension ImageFile: Decodable {
    private enum Keys: String, CodingKey, CaseIterable {
        case name, from, vm, account, license, grants, share, steps, rosetta, desktop
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.strictContainer(keyedBy: Keys.self)
        name = try keys.decodeIfPresent(String.self, forKey: .name)
        if let name {
            do { try BundleName.validate(name) } catch let error as PaddockError {
                throw DecodingError.dataCorruptedError(forKey: .name, in: keys, debugDescription: error.message)
            }
        }
        from = try keys.decode(Source.self, forKey: .from)
        if from.isLinux {
            // A Linux guest has no Apple license to accept and no privacy database to grant in.
            for key in [Keys.license, .grants] where keys.contains(key) {
                throw DecodingError.dataCorruptedError(forKey: key, in: keys, debugDescription: "is for macOS images only")
            }
        }
        vm = try keys.decodeIfPresent(VM.self, forKey: .vm) ?? VM()
        account = try keys.decode(Account.self, forKey: .account)
        acceptsLicense = try keys.choice(["accept"], forKey: .license) != nil
        grants = try keys.choice(Grants.allCases, forKey: .grants) ?? .managed
        share = try keys.decodeIfPresent(String.self, forKey: .share)
        steps = try keys.decodeIfPresent([Step].self, forKey: .steps) ?? []
        rosetta = try keys.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        if rosetta, !from.isLinux {
            // macOS runs Intel apps through Rosetta on its own; this is the Linux share.
            throw DecodingError.dataCorruptedError(forKey: .rosetta, in: keys, debugDescription: "is for Linux images only")
        }
        desktop = try keys.decodeIfPresent(Bool.self, forKey: .desktop) ?? false
        if keys.contains(.desktop), !from.isLinux {
            throw DecodingError.dataCorruptedError(forKey: .desktop, in: keys, debugDescription: "is for Linux images only")
        }
    }
}

extension ImageFile.Source: Decodable {
    private enum Keys: String, CodingKey, CaseIterable {
        case macos, ipsw, debian, disk, url, sha256, sha512, variant
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.strictContainer(keyedBy: Keys.self)
        let hashes = keys.allKeys.filter { $0 == .sha256 || $0 == .sha512 }
        let sources = keys.allKeys.filter { !hashes.contains($0) && $0 != .variant }
        guard sources.count == 1, let key = sources.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "give one of macos: latest, ipsw: <path>, debian: 13, disk: <path> or url: <https URL>"))
        }
        if key != .url, let hash = hashes.first {
            throw DecodingError.dataCorruptedError(forKey: hash, in: keys, debugDescription: "goes with url:")
        }
        if key != .debian, keys.contains(.variant) {
            throw DecodingError.dataCorruptedError(forKey: .variant, in: keys, debugDescription: "goes with debian:")
        }
        switch key {
        case .macos:
            // shortcut: only the latest; a version number needs a catalog to find its image.
            _ = try keys.choice(["latest"], forKey: .macos, hint: "to pin a version, give its restore image with ipsw:")
            self = .latest
        case .ipsw:
            self = .ipsw(try keys.decode(String.self, forKey: .ipsw))
        case .debian:
            let release = try keys.decode(Int.self, forKey: .debian)
            guard ImageFile.debianReleases.contains(release) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .debian, in: keys, debugDescription: "expected \(ImageFile.debianReleases.map(String.init).joined(separator: ", ")), not \(release)")
            }
            self = .debian(release, try keys.choice(LinuxImage.Debian.Variant.allCases, forKey: .variant) ?? .genericcloud)
        case .disk:
            self = .disk(try keys.decode(String.self, forKey: .disk))
        case .url:
            let text = try keys.decode(String.self, forKey: .url)
            guard let url = URL(string: text), url.scheme == "https", url.host != nil else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: keys, debugDescription: "expected an https URL, not \(text)")
            }
            guard LinuxImage.isDiskFileName(url.lastPathComponent) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url, in: keys, debugDescription: "expected a .tar.xz holding disk.raw, or a .raw disk")
            }
            guard hashes.count == 1, let hashKey = hashes.first else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url, in: keys, debugDescription: "needs sha256: or sha512:, the hash the file must match")
            }
            let algorithm: LinuxImage.Checksum.Algorithm = hashKey == .sha256 ? .sha256 : .sha512
            let hex = try keys.decode(String.self, forKey: hashKey).lowercased()
            guard let checksum = LinuxImage.Checksum(algorithm, hex) else {
                throw DecodingError.dataCorruptedError(
                    forKey: hashKey, in: keys, debugDescription: "expected \(algorithm.hexLength) hex digits")
            }
            self = .url(url, checksum)
        case .sha256, .sha512, .variant:
            preconditionFailure("a hash or variant is never the source; sources leaves them out")
        }
    }
}

extension ImageFile.VM: Decodable {
    private enum Keys: String, CodingKey, CaseIterable {
        case cpus, memory, disk
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.strictContainer(keyedBy: Keys.self)
        cpus = try keys.positive(forKey: .cpus)
        memory = try keys.positive(forKey: .memory)
        disk = try keys.positive(forKey: .disk)
    }
}

extension ImageFile.Account: Decodable {
    private enum Keys: String, CodingKey, CaseIterable {
        case name
        case fullName = "full-name"
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.strictContainer(keyedBy: Keys.self)
        name = try keys.decode(String.self, forKey: .name)
        fullName = try keys.decodeIfPresent(String.self, forKey: .fullName)
    }
}

extension ImageFile.Step: Decodable {
    private enum Keys: String, CodingKey, CaseIterable {
        case name, run
        case user = "as"
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.strictContainer(keyedBy: Keys.self)
        name = try keys.decode(String.self, forKey: .name)
        user = try keys.choice(ImageFile.User.allCases, forKey: .user) ?? .user
        run = try keys.decode(String.self, forKey: .run)
        guard !run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .run, in: keys, debugDescription: "is empty")
        }
    }
}

/// Any key, to see every key a mapping has, known or not.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// The mapping's container, after checking it has no key but `Keys`'.
    fileprivate func strictContainer<Keys: CodingKey & CaseIterable>(keyedBy: Keys.Type) throws -> KeyedDecodingContainer<Keys> {
        let known = Keys.allCases.map(\.stringValue)
        if let unknown = try container(keyedBy: AnyKey.self).allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath + [unknown], debugDescription: "unknown key; expected \(known.joined(separator: ", "))"))
        }
        return try container(keyedBy: Keys.self)
    }
}

extension KeyedDecodingContainer {
    /// The value at `key` if it is one of `values`, nil if the key is absent.
    fileprivate func choice(_ values: [String], forKey key: Key, hint: String? = nil) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard values.contains(value) else {
            let expected = values.count == 1 ? values[0] : values.dropLast().joined(separator: ", ") + " or " + values.last!
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "expected \(expected), not \(value)" + (hint.map { "; \($0)" } ?? ""))
        }
        return value
    }

    fileprivate func choice<Value: RawRepresentable & CaseIterable>(_ values: [Value], forKey key: Key) throws -> Value?
    where Value.RawValue == String {
        try choice(values.map(\.rawValue), forKey: key).flatMap(Value.init(rawValue:))
    }

    fileprivate func positive(forKey key: Key) throws -> Int? {
        guard let value = try decodeIfPresent(Int.self, forKey: key) else { return nil }
        guard value > 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "must be more than 0, not \(value)")
        }
        return value
    }
}
