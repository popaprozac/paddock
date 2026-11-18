/// Starter image files for `paddock init`, named for what each does differently. They are
/// starting points, not kinds of image: any file can take any setting. Each is commented for the
/// person editing it, and none accepts Apple's license for them: that line ships commented out.
public enum ImageTemplate: String, CaseIterable, Sendable {
    /// The latest macOS with nothing left to click: for your own agents and for you.
    case minimal
    /// A pinned macOS plus the tools CI jobs need.
    case ci
    /// A pinned macOS, with a person accepting the license and making the privacy grants in the
    /// image, so paddock never writes the privacy database: for teams whose policy asks for that.
    case managed

    public var text: String {
        switch self {
        case .minimal:
            """
            # A golden image for your own agents and for you: the latest macOS, set up with nothing
            # left to click. Build it with: paddock build <this file>
            # The VM is named after this file; set name: to choose another.

            from: { macos: latest }      # the latest macOS this Mac supports

            account:
              name: paddock              # the account the VM logs in as; build asks for its password

            \(Self.license)

            # paddock-session needs Accessibility and paddock-guestd Full Disk Access. recovery has
            # paddock write both from macOS Recovery, with SIP on; managed leaves them to you.
            grants: recovery

            \(Self.steps)

            """
        case .ci:
            """
            # A golden image for CI runners: a pinned macOS, set up with nothing left to click, plus
            # the tools your jobs need. Build it on a builder Mac with: paddock build <this file>
            # The VM is named after this file; set name: to choose another.

            from:
              # Pin the version with its restore image, relative to this file's folder. paddock
              # install keeps the ones it downloads in ~/.paddock/cache/ipsw.
              ipsw: restore.ipsw

            vm: { cpus: 4, memory: 8, disk: 120 }   # in GB; Xcode alone takes about 40

            account:
              name: runner               # the account jobs run as; build asks for its password

            \(Self.license)

            # paddock-session needs Accessibility and paddock-guestd Full Disk Access; paddock
            # writes both from macOS Recovery, with SIP on.
            grants: recovery

            \(Self.steps)

            """
        case .managed:
            """
            # A golden image for teams whose policy has a person make the privacy grants: a pinned
            # macOS, the two grants allowed once by hand in the image, so paddock never writes the
            # privacy database, and the license accepted by a person or by policy. A starting
            # point: change any setting, such as grants: recovery. Build it with:
            #   paddock build <this file>
            # The VM is named after this file; set name: to choose another.

            from:
              # Pin the version with its restore image, relative to this file's folder. paddock
              # install keeps the ones it downloads in ~/.paddock/cache/ipsw.
              ipsw: restore.ipsw

            account:
              # A service account: people and agents reach VMs through paddock, not by logging in.
              name: paddock

            \(Self.license)
            # Otherwise a person accepts it once, with: paddock run <name>

            # paddock-session needs Accessibility and paddock-guestd Full Disk Access: a person
            # allows them once in System Settings, with paddock run <name>, and every clone keeps
            # them. MDM profiles don't reach clones, since enrollment doesn't survive cloning.
            grants: managed

            \(Self.steps)
            # A monitoring agent that reports to its own server, such as osquery or fleetd, goes
            # in as a step; see the README on agents in cloned images.

            """
        }
    }

    private static let license = """
        # Uncomment to accept Apple's macOS Software License Agreement for this image
        # (https://www.apple.com/legal/sla/); paddock then clicks through it, and nothing else.
        # license: accept
        """

    private static let steps = """
        # A host folder, read-only in the guest at /Volumes/My Shared Files, and steps that run
        # in order after setup, each in zsh with set -e, as the account or as root.
        # share: installers
        # steps:
        #   - name: Install a package from the share
        #     as: root
        #     run: installer -pkg "/Volumes/My Shared Files/tool.pkg" -target /
        #   - name: Hide the Dock
        #     run: defaults write com.apple.dock autohide -bool true
        """
}
