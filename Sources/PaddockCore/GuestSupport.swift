/// Which macOS versions paddock sets up in a guest, and how. paddock's guest helpers run on
/// macOS 14 and later, which anyone can set up by hand; `build` sets up 15 and later by itself.
public enum GuestSupport {
    /// The oldest macOS the guest agent and session helper run on.
    public static let minimumGuest = 14
    /// The first macOS whose guests take Virtualization's guest provisioning.
    public static let provisioning = 27
    /// The oldest macOS `build` sets up offline from Recovery, as it does every release below
    /// `provisioning`: the latest three releases, with 27.
    public static let offline = 15
    /// The versions `build` has set up end to end, then `grant` and `serve`, as the table in
    /// docs/golden-images.md lists them. Apple changes first-boot setup between point releases, so another version
    /// is tried but not promised.
    public static let tested: Set<String> = ["15.6.1", "26.6.2", "27.2.1"]

    /// How `build` gets through a guest's first boot.
    public enum FirstBoot: Equatable, Sendable {
        /// macOS creates the account in place of Setup Assistant; paddock installs the agent over SSH.
        case provisioning
        /// paddock writes the account and the agent from Recovery (OfflineSetup), and Setup Assistant
        /// never shows.
        case offline
    }

    /// The major version of a macOS version string such as "26.6.2", or nil if it has none.
    public static func major(_ version: String) -> Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// How `build` sets up a guest of macOS `version`, or why it can't. Setting up offline skips
    /// Setup Assistant and the license it shows, so it needs `license: accept`.
    public static func firstBoot(macOS version: String, acceptsLicense: Bool) throws -> FirstBoot {
        guard let major = major(version) else {
            throw PaddockError("can't tell which macOS '\(version)' is")
        }
        if major >= provisioning {
            return .provisioning
        }
        guard major >= offline else {
            throw PaddockError("paddock build sets up macOS \(offline) and later, not \(version); set this one up "
                + "by hand in 'paddock run' instead (see docs/golden-images.md)")
        }
        guard acceptsLicense else {
            throw PaddockError("building macOS \(version) needs license: accept, since paddock sets it up from Recovery "
                + "and skips Setup Assistant, license included; or set it up by hand in 'paddock run' (see docs/golden-images.md)")
        }
        return .offline
    }
}
