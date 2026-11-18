import ArgumentParser
import Foundation
import PaddockCore
import Virtualization

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up a VM that 'paddock install' just made as a golden image, unattended.",
        discussion: """
            On the VM's first boot, macOS 27 creates the account in place of Setup Assistant. \
            paddock then logs in over SSH once, with the password it asked for, and as root \
            installs the guest agent and session helper from the 'guest' folder build.sh stages, \
            turns off sleep, display sleep and the screen saver, turns Remote Login off for good \
            and shuts the guest down. From then on nothing reaches the guest over the network.

            Then boot it once with 'paddock run <vm>' to click through the license agreement and \
            the welcome screen, which macOS still shows, to turn on automatic login again in \
            System Settings > Users & Groups, since Setup Assistant turns it off as it finishes, \
            and to grant paddock-session Accessibility and paddock-guestd Full Disk Access. With \
            --accept-macos-license, you accept Apple's license (apple.com/legal/sla) for the image \
            instead: the build reads the guest's screen and clicks through the license agreement \
            and the welcome screen on the first boot, so Setup Assistant finishes with automatic \
            login on, and only the two grants are left. It clicks nothing else; any other page \
            stops the build, with a screenshot of it. paddock needs macOS 27 on this Mac \
            and in the VM, and Local Network access for the app it runs in, to reach the guest.
            """)

    @Argument(help: "VM that 'paddock install' made, which has never booted.")
    var name: String

    @Option(help: "Short name of the account to create.")
    var account: String

    @Option(help: "Full name of the account; defaults to its short name.")
    var fullName: String?

    @Option(help: "Folder with the guest agent's installer; defaults to the 'guest' folder next to paddock.")
    var guest: String?

    @Flag(name: .customLong("accept-macos-license"),
          help: ArgumentHelp(
              "Accept Apple's macOS Software License Agreement (apple.com/legal/sla) for this image on your behalf.",
              discussion: "The build then clicks through the license and the welcome screen on the first boot."))
    var acceptMacOSLicense = false

    func validate() throws {
        try BundleName.validate(name)
        do { try Provisioning.validate(account: account) } catch let error as PaddockError { throw ValidationError(error.message) }
    }

    func run() async throws {
        guard #available(macOS 27, *) else { throw PaddockError("paddock build needs macOS 27 on this Mac") }
        let next = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("guest").path
        let folder = URL(fileURLWithPath: guest ?? next, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("install.sh").path) else {
            throw PaddockError("no install.sh in \(folder.path); run scripts/build.sh, or name the folder with --guest")
        }
        let password = try Provisioning.readPassword(for: account)
        let provisioning = try Provisioning.options(account: account, fullName: fullName ?? account, password: password)
        try await GoldenBuild.run(name: name, account: account, password: password, provisioning: provisioning,
                                  guest: folder, acceptLicense: acceptMacOSLicense)
    }
}

@MainActor
enum GoldenBuild {
    @available(macOS 27, *)
    static func run(name: String, account: String, password: String, provisioning: VZMacGuestProvisioningOptions,
                    guest: URL, acceptLicense: Bool) async throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let vm = try HeadlessVM(bundle: bundle, config: try bundle.readConfig(), sharing: guest)
        // Attached before the first frame, so a failed build can show what the guest's screen says.
        try? vm.attachScreen()
        print("Booting '\(name)' and creating the account '\(account)'")
        try await vm.start(provisioning: provisioning)
        do {
            guard let address = try await vm.leasedAddress(within: .seconds(120)) else {
                throw PaddockError("'\(name)' got no DHCP lease within 120 s")
            }
            print("  guest at \(address); waiting for Remote Login")
            try await GuestSSH.waitForLogin(at: address, within: .seconds(120))
            print("  logging in as '\(account)' to install the guest agent and turn off what would stop unattended VMs")
            try await GuestSSH.runAsRoot(setupScript, account: account, password: password, at: address)
            if acceptLicense {
                print("  accepting the macOS license and finishing Setup Assistant, as --accept-macos-license says")
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
            if let image = try? await vm.screenshot() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("paddock-build-\(name).png")
                if (try? FrameImage.writePNG(image, to: url)) != nil {
                    print("  the guest's screen when the build failed: \(url.path)")
                }
            }
            await vm.stop()
            throw error
        }
        print("""
            Built '\(name)'. Boot it once to finish:
              paddock run \(name)
            then \(acceptLicense ? "" : "click through the license agreement and the welcome screen, turn on automatic login for '\(account)' in System Settings > Users & Groups, ")allow \
            paddock-session in System Settings > Privacy & Security > Accessibility when macOS asks, add \
            /usr/local/libexec/paddock-guestd under Full Disk Access, and shut down from the Apple menu.
            """)
    }

    /// Runs as root through sudo, from the shared guest folder: installs the guest agent and turns
    /// off what would stop unattended VMs. Remote Login stays on for `finishScript`.
    ///
    /// Neither script touches automatic login. Provisioning turns it on once Setup Assistant
    /// finishes, which takes the license agreement: with `--accept-macos-license` the build clicks
    /// through it in between. Otherwise the owner accepts it on a later boot, and Setup Assistant,
    /// finishing then, turns automatic login off. Writing it here doesn't survive that, and marking
    /// Setup Assistant done (`/var/db/.AppleSetupDone`) doesn't stop macOS 27 showing the license.
    static let setupScript = """
        set -euo pipefail
        echo "installing the guest agent"
        bash "/Volumes/My Shared Files/install.sh"
        echo "turning off sleep, display sleep and the screen saver"
        pmset -a sleep 0 displaysleep 0
        defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
        sudo -u "$SUDO_USER" defaults -currentHost write com.apple.screensaver idleTime 0
        """

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
        let paddock = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
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
