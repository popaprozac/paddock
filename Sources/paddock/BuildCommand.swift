import ArgumentParser
import Foundation
import PaddockCore
import Virtualization
import Yams

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a golden image from an image file, with no one at the keyboard.",
        discussion: """
            The image file, in YAML, says where macOS comes from, the VM's size, the account, \
            whether you accept Apple's license for the image, how the two privacy grants get in, \
            a host folder to share and the steps to run; see docs/golden-images.md. paddock checks the whole \
            file, then asks for the account's password and installs macOS into a new VM named \
            after the file.

            On the VM's first boot, macOS 27 creates the account, and paddock logs in over SSH \
            once to install the guest agent and session helper and turn off sleep, display sleep \
            and the screen saver, then turns Remote Login off for good. With 'license: accept' \
            you accept Apple's license (apple.com/legal/sla) for the image, and paddock reads the \
            guest's screen and clicks through the license and the welcome screen, nothing else.

            macOS 15 and 26 don't create the account, so paddock boots the VM in macOS Recovery first \
            and types a script into its Terminal that writes the account, automatic login and the \
            guest agent, and marks Setup Assistant done. The first boot then logs in by itself, \
            and paddock turns off sleep, display sleep and the screen saver through the guest \
            agent. Remote Login is never on. This way never shows Apple's license, so a macOS 15 or \
            26 image file needs 'license: accept', and the account's password and full name can only \
            use characters on a US keyboard.

            With 'grants: recovery', 'paddock grant' then writes the two grants from macOS \
            Recovery. Last, paddock boots the image once more, runs the steps through the guest \
            agent, each in zsh with set -e, checks the image as serve does and shuts it down.

            paddock needs macOS 27 on this Mac and macOS 15 or later in the VM, and for macOS 27 \
            in the VM, Local Network access for the app it runs in, to reach the guest.

            A Linux image file (from: debian, disk or url) needs no password: paddock checks or \
            downloads the image, makes the VM from its disk, and boots it once with a cloud-init \
            seed that creates the account, with no password and sudo needing none, installs the \
            Linux guest agent and sets the image up for VMs nobody watches.
            """)

    @Argument(help: "Image file (YAML).")
    var file: String

    @Option(help: "Folder with the guest agent's installer; defaults to the 'guest' folder next to paddock.")
    var guest: String?

    func run() async throws {
        let plan = try ImageBuild.Plan(file: URL(fileURLWithPath: (file as NSString).expandingTildeInPath), guest: guest)
        if plan.image.from.isLinux {
            return try await LinuxBuild.run(plan)
        }
        guard #available(macOS 27, *) else { throw PaddockError("paddock build needs macOS 27 on this Mac to make macOS images") }
        let version = try await plan.macOSVersion()
        let firstBoot: GuestSupport.FirstBoot
        do {
            firstBoot = try GuestSupport.firstBoot(macOS: version, acceptsLicense: plan.image.acceptsLicense)
        } catch let error as PaddockError {
            throw PaddockError("\(plan.file.lastPathComponent): \(error.message)")
        }
        let account = plan.image.account
        // An offline setup types the account into Recovery's Terminal, on its US keyboard.
        if firstBoot == .offline {
            do {
                _ = try KeyInput.strokes(typing: OfflineSetup.recoveryScript(account: account.name,
                                                                             fullName: account.fullName ?? account.name))
            } catch {
                throw PaddockError("\(plan.file.lastPathComponent): a macOS \(version) build types account.fullName "
                    + "into the guest, so it can only use characters on a US keyboard")
            }
        }
        if !GuestSupport.tested.contains(version) {
            print("macOS \(version) hasn't been tested with paddock build; trying it.")
        }
        let password = try Provisioning.readPassword(for: account.name)
        if firstBoot == .offline {
            do { _ = try KeyInput.strokes(typing: password) } catch {
                throw PaddockError("a macOS \(version) build types the password into the guest, so it can only use "
                    + "characters on a US keyboard")
            }
        }
        try await ImageBuild.run(plan, version: version, firstBoot: firstBoot, password: password)
    }
}

/// `paddock build <file>`: install → first boot → grant → steps boot, from a checked image file.
@MainActor
enum ImageBuild {
    /// An image file, read and checked against this Mac before anything starts, so a mistake costs
    /// seconds, not a half-built VM.
    struct Plan: Sendable {
        let file: URL
        let name: String
        let image: ImageFile
        let ipsw: String?
        let disk: URL?  // a Linux disk the file names with from.disk
        let share: URL?
        let guest: URL

        nonisolated init(file: URL, guest: String?) throws {
            self.file = file.standardizedFileURL
            let text: String
            do { text = try String(contentsOf: self.file, encoding: .utf8) } catch {
                throw PaddockError("can't read \(self.file.path): \(error.localizedDescription)")
            }
            do { image = try YAMLDecoder().decode(ImageFile.self, from: text) } catch {
                throw PaddockError("\(self.file.lastPathComponent): \(ImageFile.describe(error))")
            }
            name = image.name ?? self.file.deletingPathExtension().lastPathComponent
            try BundleName.validate(name)
            if image.from.isLinux {
                try LinuxSeed.validate(account: image.account.name)
                if let disk = image.vm.disk, disk < 4 {
                    throw PaddockError("\(self.file.lastPathComponent): vm.disk must be at least 4 GB for Linux, not \(disk)")
                }
            } else {
                try Provisioning.validate(account: image.account.name)
                if let disk = image.vm.disk, disk < 32 {
                    throw PaddockError("\(self.file.lastPathComponent): vm.disk must be at least 32 GB for macOS, not \(disk)")
                }
            }

            // Paths in the file are relative to its folder.
            let folder = self.file.deletingLastPathComponent()
            func resolve(_ path: String) -> URL {
                let expanded = (path as NSString).expandingTildeInPath
                return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
            }
            var isFolder: ObjCBool = false
            switch image.from {
            case .latest, .debian, .ubuntu, .url:
                (ipsw, disk) = (nil, nil)
            case let .ipsw(path):
                let url = resolve(path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                    throw PaddockError("\(self.file.lastPathComponent): from.ipsw: no file at \(url.path)")
                }
                (ipsw, disk) = (url.path, nil)
            case let .disk(path):
                let url = resolve(path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                    throw PaddockError("\(self.file.lastPathComponent): from.disk: no file at \(url.path)")
                }
                (ipsw, disk) = (nil, url)
            }
            if let path = image.share {
                let url = resolve(path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                    throw PaddockError("\(self.file.lastPathComponent): share: no folder at \(url.path)")
                }
                share = url
            } else {
                share = nil
            }
            let next = Paddock.binary.deletingLastPathComponent().appendingPathComponent("guest").path
            self.guest = URL(fileURLWithPath: guest ?? next, isDirectory: true).standardizedFileURL
            let installer = image.from.isLinux ? "linux/paddock-guestd" : "install.sh"
            guard FileManager.default.fileExists(atPath: self.guest.appendingPathComponent(installer).path) else {
                throw PaddockError("no \(installer) in \(self.guest.path); run scripts/build.sh, or name the folder with --guest")
            }
            let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
            guard !FileManager.default.fileExists(atPath: bundle.url.path) else {
                throw PaddockError("VM '\(name)' already exists at \(bundle.url.path); delete it or set name: in the file")
            }
        }

        /// The macOS this file installs: its restore image's, or the latest this Mac supports.
        func macOSVersion() async throws -> String {
            if let ipsw {
                return try await RestoreImages.load(from: URL(fileURLWithPath: ipsw)).version
            }
            return try await RestoreImages.fetchLatestSupported().version
        }
    }

    @available(macOS 27, *)
    static func run(_ plan: Plan, version: String, firstBoot: GuestSupport.FirstBoot, password: String) async throws {
        let image = plan.image, account = image.account.name, fullName = image.account.fullName ?? account
        let started = ContinuousClock.now
        try await Install.install(
            name: plan.name, ipsw: plan.ipsw, cpus: image.vm.cpus ?? VMSizing.defaultCPUCount,
            memory: image.vm.memory.map(UInt64.init) ?? VMSizing.defaultMemorySize >> 30,
            diskSize: image.vm.disk.map(UInt64.init) ?? VMSizing.defaultDiskSize >> 30)
        let problems: [String]?
        do {
            switch firstBoot {
            case .provisioning:
                let provisioning = try Provisioning.options(account: account, fullName: fullName, password: password)
                try await GoldenBuild.run(name: plan.name, account: account, password: password,
                                          provisioning: provisioning, guest: plan.guest,
                                          acceptLicense: image.acceptsLicense)
            case .offline:
                try await GoldenBuild.writeOffline(name: plan.name, account: account, fullName: fullName,
                                                   password: password, guest: plan.guest)
                try await GoldenBuild.firstBootOffline(name: plan.name, account: account)
            }
            if image.grants == .recovery {
                try await RecoveryGrant.run(name: plan.name)
            }
            problems = try await ImageSteps.run(name: plan.name, steps: image.steps, share: plan.share).problems
        } catch {
            let bundle = try? PaddockHome.fromEnvironment().bundle(named: plan.name)
            print("The build stopped; '\(plan.name)' is left at \(bundle?.url.path ?? plan.name) to look at. Delete it to build again.")
            if !GuestSupport.tested.contains(version) {
                print("macOS \(version) isn't tested yet and may set up differently: set the image up by hand in "
                    + "'paddock run' instead (see docs/golden-images.md).")
            }
            throw error
        }

        print("Built '\(plan.name)' from \(plan.file.lastPathComponent) in \(DurationFormat.short(ContinuousClock.now - started)).")
        switch problems {
        case nil:
            print("  The image check couldn't run.")
        case let problems? where !problems.isEmpty:
            print("  The image check found:")
            for problem in problems { print("    - \(problem)") }
        default:
            break
        }
        var left: [String] = []
        if !image.acceptsLicense {
            left.append("boot it once with 'paddock run \(plan.name)' to accept the license and the welcome screen, "
                + "then turn on automatic login for '\(account)' in System Settings > Users & Groups")
        }
        if image.grants == .managed {
            left.append("allow paddock-session under Accessibility and /usr/local/libexec/paddock-guestd under Full Disk "
                + "Access in System Settings > Privacy & Security, booted with 'paddock run \(plan.name)', or run 'paddock grant \(plan.name)'")
        }
        if left.isEmpty {
            print("  Ready to serve: paddock serve \(plan.name)")
        } else {
            print("  Left for a person:")
            for step in left { print("    - \(step)") }
        }
    }
}

@MainActor
enum GoldenBuild {
    @available(macOS 27, *)
    static func run(name: String, account: String, password: String, provisioning: VZMacGuestProvisioningOptions,
                    guest: URL, acceptLicense: Bool) async throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        print("Booting '\(name)' and creating the account '\(account)'")
        let vm = try await HeadlessVM.started(bundle: bundle, sharing: guest) { try await $0.start(provisioning: provisioning) }
        do {
            guard let address = try await vm.leasedAddress(within: .seconds(120)) else {
                throw PaddockError("'\(name)' got no DHCP lease within 120 s")
            }
            print("  guest at \(address); waiting for Remote Login")
            try await GuestSSH.waitForLogin(at: address, within: .seconds(120))
            print("  logging in as '\(account)' to install the guest agent and turn off what would stop unattended VMs")
            try await GuestSSH.runAsRoot(setupScript(account: account, installingAgent: true), account: account,
                                         password: password, at: address)
            if acceptLicense {
                print("  accepting the macOS license and finishing Setup Assistant, as the image file's license: accept says")
                try await SetupAssistant.clickThrough(vm, within: .seconds(300))
                print("  '\(account)' is logged in")
            }
            try await GuestSSH.runAsRoot(finishScript(acceptLicense: acceptLicense), account: account, password: password,
                                         at: address)
            print("  waiting for the guest to shut down")
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(name)' didn't shut down within 120 s of its setup")
            }
        } catch {
            await vm.saveScreen(as: "paddock-build-\(name)")
            await vm.stop()
            throw error
        }
    }

    /// A macOS 15 or 26 guest before its first boot, which ignores provisioning: paddock boots it in
    /// Recovery and types OfflineSetup's script into Terminal, after the password into `read -rs`,
    /// so the password is never on screen or in the script. The guest halts once the account,
    /// automatic login and the guest agent are written.
    static func writeOffline(name: String, account: String, fullName: String, password: String,
                             guest: URL) async throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        print("Booting '\(name)' in macOS Recovery to write the account '\(account)' and the guest agent")
        let vm = try await HeadlessVM.started(bundle: bundle, sharing: guest) { try await $0.startInRecovery() }
        do {
            try await RecoveryGrant.openTerminal(vm)
            print("  writing the account, automatic login and the guest agent")
            try await vm.press(KeyInput.strokes(typing: "read -rs P\n"))
            try await Task.sleep(for: .milliseconds(500))
            try await vm.press(KeyInput.strokes(typing: password + "\n"))
            try await vm.press(KeyInput.strokes(typing: OfflineSetup.recoveryScript(account: account, fullName: fullName)))
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(name)' didn't shut down after the setup typed in Recovery's Terminal, so a step failed")
            }
        } catch {
            await vm.saveScreen(as: "paddock-build-\(name)")
            await vm.stop()
            throw error
        }
    }

    /// The first boot after `writeOffline`: the account logs in by itself, paddock checks that
    /// Setup Assistant stayed away, turns off what would stop unattended VMs through the guest
    /// agent, and has the guest shut down. Remote Login is never on.
    static func firstBootOffline(name: String, account: String) async throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        print("Booting '\(name)' to log in as '\(account)' and turn off what would stop unattended VMs")
        let vm = try await HeadlessVM.started(bundle: bundle, sharing: nil) { try await $0.start() }
        do {
            guard try await vm.agentVersion(within: .seconds(180)) != nil else {
                throw PaddockError("the guest agent in '\(name)' didn't answer within 180 s")
            }
            // paddock-session starts when the account logs in to the desktop.
            guard try await vm.sessionHelperVersion(within: .seconds(120)) != nil,
                  try await vm.desktopReady(within: .seconds(60)) else {
                throw PaddockError("'\(account)' didn't log in to the desktop by itself")
            }
            // The per-user Setup Assistant covers the desktop moments after the login, if it starts
            // at all, so the desktop must be in front, with Finder's menu bar, and no Setup
            // Assistant running.
            try await Task.sleep(for: .seconds(10))
            let (lines, screen) = try await vm.readScreen()
            let setupAssistant = try await vm.runInGuest("pgrep -f '/Setup Assistant.app/'", output: { _ in }) == 0
            guard ScreenText.showsFinder(in: lines, screen: screen), !setupAssistant else {
                throw PaddockError("'\(account)' logged in, but Setup Assistant or something else covers the desktop: "
                    + "this macOS may ask for something the offline setup doesn't write")
            }
            print("  '\(account)' is logged in")
            let script = setupScript(account: account, installingAgent: false) + """

                echo "shutting down"
                sync
                (sleep 2; shutdown -h now) </dev/null >/dev/null 2>&1 &
                """
            let status = try await vm.runInGuest(script, asRoot: true) { print("    \($0)") }
            guard status == 0 else {
                throw PaddockError("the guest's setup failed with status \(status)")
            }
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(name)' didn't shut down within 120 s of its setup")
            }
        } catch {
            await vm.saveScreen(as: "paddock-build-\(name)")
            await vm.stop()
            throw error
        }
    }

    /// Runs as root: installs the guest agent from the shared guest folder if `installingAgent`,
    /// turns off what would stop unattended VMs, and turns off automatic updates. On macOS 27 it
    /// runs over SSH, and Remote Login stays on for `finishScript`.
    ///
    /// On 27 neither script touches automatic login. Provisioning turns it on once Setup Assistant
    /// finishes, which takes the license agreement: with `license: accept` the build clicks
    /// through it in between. Otherwise the owner accepts it on a later boot, and Setup Assistant,
    /// finishing then, turns automatic login off. Writing it here doesn't survive that, and marking
    /// Setup Assistant done (`/var/db/.AppleSetupDone`) doesn't stop macOS 27 showing the license.
    static func setupScript(account: String, installingAgent: Bool) -> String {
        let install = installingAgent ? "echo \"installing the guest agent\"\nbash \"/Volumes/My Shared Files/install.sh\"\n" : ""
        return """
        set -euo pipefail
        \(install)echo "turning off sleep, display sleep and the screen saver"
        pmset -a sleep 0 displaysleep 0
        defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
        sudo -u \(account) defaults -currentHost write com.apple.screensaver idleTime 0
        # An image's macOS is pinned and its clones are wiped, so updates would only download in
        # every clone. Security data updates (XProtect and the like) stay on.
        echo "turning off automatic macOS and App Store updates"
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
        defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
        defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
        """
    }

    /// Turns Remote Login off for good and has the guest shut itself down, so its settings are on
    /// disk, not lost to a forced power-off.
    static func finishScript(acceptLicense: Bool) -> String {
        let status = acceptLicense ? "echo \"$(sysadminctl -autologin status 2>&1 | sed 's/.*\\] //')\"\n" : ""
        return """
        set -euo pipefail
        \(status)echo "turning off Remote Login and shutting down"
        launchctl disable system/com.openssh.sshd
        sync
        (sleep 2; shutdown -h now) </dev/null >/dev/null 2>&1 &
        """
    }
}

/// SSH into a guest that a build has just created, which nothing else has reached yet.
enum GuestSSH {
    /// Waits until the guest's sshd accepts connections.
    static func waitForLogin(at address: String, within timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        var last = ""
        while ContinuousClock.now < deadline {
            let (status, output) = try await capture("/usr/bin/nc", ["-z", "-G", "2", address, "22"])
            if status == 0 { return }
            last = output
            try await Task.sleep(for: .seconds(1))
        }
        throw unreachable(last) ?? PaddockError("Remote Login didn't come up at \(address) within \(DurationFormat.short(timeout))")
    }

    /// Runs `script` as root in the guest: logs in as `account` with `password`, which ssh gets
    /// from an AskpassServer, and gives sudo the same password ahead of the script on stdin.
    static func runAsRoot(_ script: String, account: String, password: String, at address: String) async throws {
        let paddock = Paddock.binary.path
        let askpass = try AskpassServer(password: password, helper: paddock)
        defer { askpass.stop() }
        // The guest was created moments ago by this build, on this Mac's private NAT network, so
        // there is no earlier host key to check its key against.
        let arguments = [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10",
            "\(account)@\(address)", "sudo -S -p '' /bin/bash -s",
        ]
        let input = password + "\n" + script + "\n"
        let (status, output) = try await capture("/usr/bin/ssh", arguments, input: input, environment: askpass.environment) {
            print("    \($0)")
        }
        guard status == 0 else {
            throw unreachable(output) ?? PaddockError("the guest's setup failed with status \(status)")
        }
    }

    /// The error for a guest this Mac can't route to: what macOS's Local Network privacy setting
    /// returns to an app that hasn't been allowed it.
    private static func unreachable(_ output: String) -> PaddockError? {
        guard output.contains("No route to host") else { return nil }
        return PaddockError("this Mac can't reach the guest: allow the app paddock runs in, such as Terminal, "
            + "in System Settings > Privacy & Security > Local Network")
    }

    /// Runs a program off the main actor and returns its status and combined output, passing
    /// each line to `line` as it arrives.
    private static func capture(_ path: String, _ arguments: [String], input: String? = nil,
                                environment: [String: String] = [:],
                                line: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try stdin.fileHandleForWriting.close()
            }
            var all = ""
            var pending = Data()
            while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    all += text + "\n"
                    line(text)
                }
            }
            if !pending.isEmpty {
                let text = String(decoding: pending, as: UTF8.self)
                all += text
                line(text)
            }
            process.waitUntilExit()
            return (process.terminationStatus, all)
        }.value
    }
}
