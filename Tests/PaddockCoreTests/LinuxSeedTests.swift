import Foundation
import Testing
import Yams
@testable import PaddockCore

@Suite struct LinuxSeedTests {
    @Test func takesOnlyLinuxAccountNamesTheImageDoesntHave() throws {
        try LinuxSeed.validate(account: "paddock")
        try LinuxSeed.validate(account: "ci-runner_2")
        for name in ["Paddock", "2fast", "a.b", "", String(repeating: "a", count: 33)] {
            #expect(throws: PaddockError.self, "\(name)") { try LinuxSeed.validate(account: name) }
        }
        for name in ["root", "sshd", "nobody"] {
            let error = #expect(throws: PaddockError.self) { try LinuxSeed.validate(account: name) }
            #expect(error?.message.contains("one of the image's own accounts") == true)
        }
    }

    @Test func namesTheGuestAfterTheVM() {
        #expect(LinuxSeed.hostname(for: "debian") == "debian")
        #expect(LinuxSeed.hostname(for: "CI_linux.2") == "ci-linux-2")
        #expect(LinuxSeed.hostname(for: "__") == "paddock")
    }

    /// The user-data is YAML cloud-init reads: the account with uid 1000, no password, sudo
    /// without one, and the setup script run from the seed with the account's name.
    @Test func userDataMakesTheAccountAndRunsSetup() throws {
        let text = LinuxSeed.userData(account: "paddock", fullName: #"Paddock "CI" Runner"#)
        #expect(text.hasPrefix("#cloud-config\n"))
        let yaml = try #require(try Yams.load(yaml: text) as? [String: Any])
        let user = try #require((yaml["users"] as? [[String: Any]])?.first)
        #expect(user["name"] as? String == "paddock")
        #expect(user["gecos"] as? String == #"Paddock "CI" Runner"#)
        #expect(user["uid"] as? Int == 1000)
        #expect(user["lock_passwd"] as? Bool == true)
        #expect(user["sudo"] as? String == "ALL=(ALL) NOPASSWD:ALL")
        let command = try #require((yaml["runcmd"] as? [[String]])?.first)
        #expect(command.first == "sh" && command.last?.hasSuffix("sh /run/paddock-seed/paddock-setup.sh paddock") == true)
    }

    @Test func setsRosettaUpOnlyWhenTheImageUsesIt() {
        #expect(LinuxSeed.userData(account: "paddock", fullName: "Paddock", rosetta: true)
            .contains("paddock-setup.sh paddock rosetta\""))
        #expect(LinuxSeed.userData(account: "paddock", fullName: "Paddock").contains("paddock-setup.sh paddock\""))
        #expect(LinuxSeed.setupScript.contains(#"if [ "$rosetta" = rosetta ]; then"#))
    }

    @Test func setupScriptIsValidShell() throws {
        #expect(LinuxSeed.setupScript.hasPrefix("#!/bin/sh\n"))
        #expect(LinuxSeed.setupScript.contains("\nEOF\n"))  // the heredoc's end, at the start of its line
        #expect(LinuxSeed.setupScript.contains("dhcp-identifier: mac"))
        let tmp = try TemporaryDirectory()
        let script = tmp.url.appendingPathComponent("paddock-setup.sh")
        try Data(LinuxSeed.setupScript.utf8).write(to: script)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", script.path]
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
    }

    @Test func sealingEmptiesTheMachineIDAndStopsAtAFailure() throws {
        let lines = LinuxSeed.sealScript.split(separator: "\n")
        #expect(lines.first == "set -e")
        #expect(lines.contains("truncate -s 0 /etc/machine-id"))
        #expect(LinuxSeed.mountShare.contains("mount -t virtiofs -o ro paddock-share /mnt/share"))
        for script in [LinuxSeed.sealScript, LinuxSeed.mountShare, LinuxSeed.disableCloudInit] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", "-c", script]
            try check.run()
            check.waitUntilExit()
            #expect(check.terminationStatus == 0, "\(script)")
        }
    }

    /// The desktop scripts are valid shell; setup does nothing without a display manager, and
    /// sets automatic login in each display manager paddock knows.
    @Test func desktopScriptsAreValidShell() throws {
        for script in [LinuxSeed.desktopSetupScript, LinuxSeed.desktopDiagnosisScript, LinuxSeed.accessibilityBusCheck] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", "-c", script]
            try check.run()
            check.waitUntilExit()
            #expect(check.terminationStatus == 0)
        }
        let lines = LinuxSeed.desktopSetupScript.split(separator: "\n")
        #expect(lines.prefix(2) == ["set -e", "[ -L /etc/systemd/system/display-manager.service ] || exit 0"])
        for path in ["/etc/lightdm/lightdm.conf.d/50-paddock.conf", "/etc/gdm3/daemon.conf", "/etc/gdm3/custom.conf",
                     "/etc/gdm/custom.conf", "/etc/sddm.conf.d/50-paddock.conf", "/etc/X11/xorg.conf.d/10-paddock.conf",
                     "/etc/dconf/db/local.d/00-paddock"] {
            #expect(LinuxSeed.desktopSetupScript.contains(path), "\(path)")
        }
        // GNOME's keys sit at the line's start in the script, where dconf reads them.
        for key in ["idle-delay=uint32 0", "lock-enabled=false", "sleep-inactive-ac-type='nothing'", "EOF"] {
            #expect(lines.contains { $0 == key }, "\(key)")
        }
    }

    @Test func makesAnISOLabeledForCloudInit() throws {
        let tmp = try TemporaryDirectory()
        let agent = tmp.url.appendingPathComponent("linux")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("agent".utf8).write(to: agent.appendingPathComponent("paddock-guestd"))
        try Data("[Unit]".utf8).write(to: agent.appendingPathComponent("paddock-guestd.service"))
        let iso = tmp.url.appendingPathComponent("seed.iso")
        try LinuxSeed.makeISO(at: iso, agent: agent, account: "paddock", fullName: "Paddock", name: "debian")
        let data = try Data(contentsOf: iso)
        #expect(data.count > 32 * 1024)
        // ISO 9660 keeps the volume label in the primary volume descriptor, at sector 16.
        #expect(String(decoding: data[(16 * 2048 + 40)..<(16 * 2048 + 46)], as: UTF8.self).uppercased() == "CIDATA")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).sorted() == ["linux", "seed.iso"])
    }
}
