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
    /// Debian with no screen, for commands, files and tasks: Linux CI and agents.
    case debian

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

            \(Self.steps())

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

            \(Self.steps(installingCommandLineTools: true))

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

            \(Self.steps())
            # A monitoring agent that reports to its own server, such as osquery or fleetd, goes
            # in as a step; see docs/golden-images.md on agents in cloned images.

            """
        case .debian:
            """
            # A golden image of Debian 13 for Linux CI and agents: commands, files and tasks, with no
            # screen. Build it with: paddock build <this file>
            # The VM is named after this file; set name: to choose another.

            # The latest genericcloud arm64 build from cloud.debian.org, checked against Debian's
            # SHA512SUMS. To pin a build, give the .tar.xz you keep, from: { disk: <path> }, or
            # one to download with the hash it must match: from: { url: <https URL>, sha512: <hash> }
            from: { debian: 13 }

            vm: { cpus: 4, memory: 4, disk: 16 }   # in GB

            account:
              # Commands run as this account, uid 1000. It has no password, and sudo needs none.
              name: paddock

            # Uncomment to run x86-64 Linux programs through Rosetta, which this Mac must have.
            # rosetta: true

            # A host folder, read-only in the guest at /mnt/share, and steps that run in order after
            # setup, each in bash with set -e, as the account or as root.
            # share: installers
            # steps:
            #   - name: Install build tools
            #     as: root
            #     run: apt-get update && apt-get install -y build-essential git
            #   - name: Check that git works for the account
            #     run: git --version

            """
        }
    }

    private static let license = """
        # Uncomment to accept Apple's macOS Software License Agreement for this image
        # (https://www.apple.com/legal/sla/); paddock then clicks through it, and nothing else.
        # license: accept
        """

    /// The Command Line Tools, for git: Apple's on-demand install, as Homebrew's installer does it.
    private static let commandLineTools = [
        "# git and the compilers, which paddock task and most jobs need, from Apple's software",
        "# update servers. Installing them accepts Apple's Xcode and SDK license for this image.",
        "- name: Install the Command Line Tools",
        "  as: root",
        "  run: |",
        "    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
        #"    label=$(softwareupdate --list 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -n 1)"#,
        #"    if [ -z "$label" ]; then echo "softwareupdate lists no Command Line Tools"; exit 1; fi"#,
        #"    softwareupdate --install "$label""#,
        "    rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
        "- name: Check that git works for the account",
        "  run: xcode-select -p && git --version",
    ]

    private static let examples = [
        "- name: Install a package from the share",
        "  as: root",
        #"  run: installer -pkg "/Volumes/My Shared Files/tool.pkg" -target /"#,
        "- name: Hide the Dock",
        "  run: defaults write com.apple.dock autohide -bool true",
    ]

    /// A shared folder and steps, commented out, with the Command Line Tools' steps in force or not.
    private static func steps(installingCommandLineTools: Bool = false) -> String {
        let header = [
            "# A host folder, read-only in the guest at /Volumes/My Shared Files, and steps that run",
            "# in order after setup, each in zsh with set -e, as the account or as root.",
            "# share: installers",
        ]
        guard installingCommandLineTools else {
            return (header + ["# steps:"] + (commandLineTools + examples).map { "#   " + $0 }).joined(separator: "\n")
        }
        return (header + ["steps:"] + commandLineTools.map { "  " + $0 } + examples.map { "  # " + $0 })
            .joined(separator: "\n")
    }
}
