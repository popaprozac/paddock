import Foundation

/// Where paddock keeps VM bundles and downloaded restore images.
///
/// Defaults to `~/.paddock`; set `PADDOCK_HOME` to use another directory. Clones must be on the
/// same APFS volume as their source, so keep the golden image and its clones under one home.
public struct PaddockHome: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PaddockHome {
        if let override = environment["PADDOCK_HOME"], !override.isEmpty {
            return PaddockHome(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return PaddockHome(root: home.appendingPathComponent(".paddock", isDirectory: true))
    }

    public var vmsDirectory: URL {
        root.appendingPathComponent("vms", isDirectory: true)
    }

    /// Where `paddock serve` listens for `acquire` and `release`.
    public var socketURL: URL {
        root.appendingPathComponent("serve.sock")
    }

    public var ipswCacheDirectory: URL {
        root.appendingPathComponent("cache/ipsw", isDirectory: true)
    }

    /// Where `paddock build` keeps the Linux images it downloads.
    public var linuxCacheDirectory: URL {
        root.appendingPathComponent("cache/linux", isDirectory: true)
    }

    /// The bundle for a VM name. The bundle may not exist yet.
    public func bundle(named name: String) throws -> VMBundle {
        try BundleName.validate(name)
        return VMBundle(url: vmsDirectory.appendingPathComponent(name, isDirectory: true))
    }
}

/// VM names become directory names, so keep them to a safe character set.
public enum BundleName {
    public static func validate(_ name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let valid = !name.isEmpty
            && name.count <= 64
            && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        guard valid else {
            throw PaddockError(
                "invalid VM name '\(name)': use up to 64 letters, digits, '-', '_' or '.', not starting with '.'")
        }
    }

    /// A fresh 6-hex-digit id, to tell bundles of one source apart.
    public static func shortID() -> String {
        UUID().uuidString.prefix(6).lowercased()
    }

    /// The start of slot `number`'s bundle names for `source`, with a fresh id.
    public static func slotStem(_ number: Int, of source: String) -> String {
        "\(source.prefix(40))-slot\(number)-\(shortID())"
    }

    /// The bundle name for the saved state of the slot whose names start with `stem`, or with
    /// `saved` false, for one of its clones.
    public static func slotBundle(of stem: String, saved: Bool) -> String {
        "\(stem)-\(saved ? "saved" : shortID())"
    }

    /// Whether `name` is one serve gives its slots' bundles for `source`: "<source>-slot<n>-<id>"
    /// and then "-saved" or "-<id>", each id 6 lowercase hex digits, so what a killed serve left
    /// can be told from a VM someone named.
    public static func isSlotBundle(_ name: String, of source: String) -> Bool {
        let prefix = "\(source.prefix(40))-slot"
        guard name.hasPrefix(prefix) else { return false }
        let parts = name.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        let isID = { (part: Substring) in part.count == 6 && part.allSatisfy { "0123456789abcdef".contains($0) } }
        guard parts.count == 3, let number = Int(parts[0]), number > 0, String(number) == parts[0] else { return false }
        return isID(parts[1]) && (parts[2] == "saved" || isID(parts[2]))
    }
}
