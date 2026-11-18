/// Which macOS versions paddock sets up in a guest, and how. paddock's guest helpers run on
/// macOS 14 and later, which anyone can set up by hand; `build` sets up 26 and later by itself.
public enum GuestSupport {
    /// The oldest macOS the guest agent and session helper run on.
    public static let minimumGuest = 14
    /// The first macOS whose guests take Virtualization's guest provisioning.
    public static let provisioning = 27

    /// How `build` gets through a guest's first boot.
    public enum FirstBoot: Equatable, Sendable {
        /// macOS creates the account in place of Setup Assistant; paddock installs the agent over SSH.
        case provisioning
        /// paddock clicks through Setup Assistant, typing the account, and installs the agent in Terminal.
        case setupAssistant
    }

    /// The major version of a macOS version string such as "26.6.2", or nil if it has none.
    public static func major(_ version: String) -> Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// How `build` sets up a guest of macOS `version`, or why it can't. Setup Assistant shows the
    /// license before the account can log in, so clicking through it needs `license: accept`.
    public static func firstBoot(macOS version: String, acceptsLicense: Bool) throws -> FirstBoot {
        guard let major = major(version) else {
            throw PaddockError("can't tell which macOS '\(version)' is")
        }
        if major >= provisioning {
            return .provisioning
        }
        guard major >= 26 else {
            throw PaddockError("paddock build sets up macOS 26 and later, not \(version); set this one up by hand "
                + "in 'paddock run' instead (see the README)")
        }
        guard acceptsLicense else {
            throw PaddockError("building macOS \(version) needs license: accept, since its Setup Assistant shows the "
                + "license before the account can log in; or set it up by hand in 'paddock run' (see the README)")
        }
        return .setupAssistant
    }
}
