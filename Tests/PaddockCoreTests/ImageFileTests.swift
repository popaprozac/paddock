import Foundation
import Testing
import Yams
@testable import PaddockCore

@Suite struct ImageFileTests {
    private func decode(_ yaml: String) throws -> ImageFile {
        try YAMLDecoder().decode(ImageFile.self, from: yaml)
    }

    /// The one line a broken file fails with.
    private func failure(_ yaml: String) -> String {
        do {
            _ = try decode(yaml)
            return "decoded"
        } catch {
            return ImageFile.describe(error)
        }
    }

    @Test func decodesEveryKey() throws {
        let file = try decode("""
            name: ios-team
            from: { ipsw: ~/ipsw/UniversalMac_27.2.1.ipsw }
            vm: { cpus: 6, memory: 16, disk: 120 }
            account: { name: bench, full-name: Bench Runner }
            license: accept
            grants: recovery
            share: installers
            steps:
              - name: Xcode
                as: root
                run: |
                  xip -x Xcode.xip
                  mv Xcode.app /Applications
              - name: Homebrew
                run: echo brew
            """)
        #expect(file == ImageFile(
            name: "ios-team", from: .ipsw("~/ipsw/UniversalMac_27.2.1.ipsw"), vm: .init(cpus: 6, memory: 16, disk: 120),
            account: .init(name: "bench", fullName: "Bench Runner"), acceptsLicense: true, grants: .recovery,
            share: "installers", steps: [
                .init(name: "Xcode", user: .root, run: "xip -x Xcode.xip\nmv Xcode.app /Applications\n"),
                .init(name: "Homebrew", user: .user, run: "echo brew"),
            ]))
    }

    @Test func leavesTheOptInsOffAndTheRestToInstall() throws {
        let file = try decode("from: { macos: latest }\naccount: { name: bench }")
        #expect(file.name == nil && file.vm == .init() && file.share == nil && file.steps.isEmpty)
        #expect(!file.acceptsLicense)
        #expect(file.grants == .managed)
    }

    @Test func refusesAMisspelledKeyAnywhere() {
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nlicence: accept")
            == "licence: unknown key; expected name, from, vm, account, license, grants, share, steps, rosetta, desktop")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nsteps: [{ name: x, user: root, run: id }]")
            == "steps[0].user: unknown key; expected name, run, as")
    }

    @Test func refusesAValueOutsideItsChoices() {
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nsteps: [{ name: x, run: id }, { name: y, as: admin, run: id }]")
            == "steps[1].as: expected user or root, not admin")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nlicense: yes")
            == "license: expected accept, not yes")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\ngrants: scripted")
            == "grants: expected managed or recovery, not scripted")
    }

    @Test func pinsAVersionOnlyThroughItsRestoreImage() {
        #expect(failure("from: { macos: 27.2.1 }\naccount: { name: bench }")
            == "from.macos: expected latest, not 27.2.1; to pin a version, give its restore image with ipsw:")
        #expect(failure("from: { macos: latest, ipsw: x.ipsw }\naccount: { name: bench }")
            == "from: give one of macos: latest, ipsw: <path>, debian: 13, ubuntu: 26.04, disk: <path> or url: <https URL>")
    }

    @Test func takesALinuxImageFromDebianOrADiskYouKeep() throws {
        #expect(try decode("from: { debian: 13 }\naccount: { name: bench }").from == .debian(13, .genericcloud))
        let pinned = try decode("from: { disk: images/debian-13-genericcloud-arm64.tar.xz }\naccount: { name: bench }")
        #expect(pinned.from == .disk("images/debian-13-genericcloud-arm64.tar.xz") && pinned.from.isLinux)
        #expect(!(try decode("from: { macos: latest }\naccount: { name: bench }")).from.isLinux)
        #expect(failure("from: { debian: 12 }\naccount: { name: bench }") == "from.debian: expected 13, not 12")
        #expect(failure("from: { debian: trixie }\naccount: { name: bench }") == "from.debian: expected a whole number")
        #expect(failure("from: { debian: 13, macos: latest }\naccount: { name: bench }")
            == "from: give one of macos: latest, ipsw: <path>, debian: 13, ubuntu: 26.04, disk: <path> or url: <https URL>")
    }

    /// Ubuntu's release is taken as written: as a number, 26.10 would read as 26.1.
    @Test func takesALinuxImageFromUbuntu() throws {
        let file = try decode("from: { ubuntu: 26.04 }\naccount: { name: bench }")
        #expect(file.from == .ubuntu("26.04") && file.from.isLinux)
        #expect(failure("from: { ubuntu: 24.04 }\naccount: { name: bench }") == "from.ubuntu: expected 26.04, not 24.04")
        #expect(failure("from: { ubuntu: 26.4 }\naccount: { name: bench }") == "from.ubuntu: expected 26.04, not 26.4")
        #expect(failure("from: { ubuntu: 26.04, variant: generic }\naccount: { name: bench }") == "from.variant: goes with debian:")
    }

    /// Debian's own variant names pick its image; genericcloud unless the file says otherwise.
    @Test func takesDebiansVariantByItsName() throws {
        #expect(try decode("from: { debian: 13, variant: generic }\naccount: { name: bench }").from == .debian(13, .generic))
        #expect(try decode("from: { debian: 13, variant: genericcloud }\naccount: { name: bench }").from == .debian(13, .genericcloud))
        #expect(failure("from: { debian: 13, variant: nocloud }\naccount: { name: bench }")
            == "from.variant: expected genericcloud or generic, not nocloud")
        #expect(failure("from: { disk: d.raw, variant: generic }\naccount: { name: bench }") == "from.variant: goes with debian:")
        #expect(failure("from: { variant: generic }\naccount: { name: bench }")
            == "from: give one of macos: latest, ipsw: <path>, debian: 13, ubuntu: 26.04, disk: <path> or url: <https URL>")
    }

    @Test func takesALinuxImageByURLWithTheHashItMustMatch() throws {
        let sha256 = String(repeating: "ab", count: 32), sha512 = String(repeating: "cd", count: 64)
        let file = try decode("from: { url: 'https://images.example/debian/disk.tar.xz', sha256: \(sha256.uppercased()) }\naccount: { name: bench }")
        #expect(file.from == .url(URL(string: "https://images.example/debian/disk.tar.xz")!, LinuxImage.Checksum(.sha256, sha256)!))
        #expect(file.from.isLinux)
        #expect(try decode("from: { url: 'https://images.example/disk.raw', sha512: \(sha512) }\naccount: { name: bench }").from
            == .url(URL(string: "https://images.example/disk.raw")!, LinuxImage.Checksum(.sha512, sha512)!))

        let url = "url: 'https://images.example/disk.raw'"
        #expect(failure("from: { \(url) }\naccount: { name: bench }") == "from.url: needs sha256: or sha512:, the hash the file must match")
        #expect(failure("from: { \(url), sha256: \(sha256), sha512: \(sha512) }\naccount: { name: bench }")
            == "from.url: needs sha256: or sha512:, the hash the file must match")
        #expect(failure("from: { \(url), sha256: abc }\naccount: { name: bench }") == "from.sha256: expected 64 hex digits")
        #expect(failure("from: { url: 'http://images.example/disk.raw', sha256: \(sha256) }\naccount: { name: bench }")
            == "from.url: expected an https URL, not http://images.example/disk.raw")
        #expect(try decode("from: { url: 'https://images.example/ubuntu.img', sha256: \(sha256) }\naccount: { name: bench }").from
            == .url(URL(string: "https://images.example/ubuntu.img")!, LinuxImage.Checksum(.sha256, sha256)!))
        #expect(failure("from: { url: 'https://images.example/disk.vmdk', sha256: \(sha256) }\naccount: { name: bench }")
            == "from.url: expected a .tar.xz holding disk.raw, a .raw disk, or a .qcow2 or .img disk")
        #expect(failure("from: { debian: 13, sha256: \(sha256) }\naccount: { name: bench }") == "from.sha256: goes with url:")
    }

    @Test func takesRosettaForLinuxImagesOnly() throws {
        #expect(try decode("from: { debian: 13 }\naccount: { name: bench }\nrosetta: true").rosetta)
        #expect(!(try decode("from: { debian: 13 }\naccount: { name: bench }")).rosetta)
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nrosetta: true") == "rosetta: is for Linux images only")
    }

    /// desktop: asks the build to require a desktop; it changes nothing about the source.
    @Test func takesDesktopForLinuxImagesOnly() throws {
        let file = try decode("from: { debian: 13 }\naccount: { name: bench }\ndesktop: true")
        #expect(file.desktop && file.from == .debian(13, .genericcloud))
        #expect(!(try decode("from: { debian: 13 }\naccount: { name: bench }")).desktop)
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\ndesktop: true") == "desktop: is for Linux images only")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\ndesktop: false") == "desktop: is for Linux images only")
    }

    @Test func refusesMacOSOnlyKeysInALinuxImage() {
        #expect(failure("from: { debian: 13 }\naccount: { name: bench }\nlicense: accept") == "license: is for macOS images only")
        #expect(failure("from: { debian: 13 }\naccount: { name: bench }\ngrants: recovery") == "grants: is for macOS images only")
    }

    @Test func saysWhatIsMissingOrMistyped() {
        #expect(failure("from: { macos: latest }") == "account: missing")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nvm: { memory: eight }")
            == "vm.memory: expected a whole number")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nvm: { disk: 0 }")
            == "vm.disk: must be more than 0, not 0")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nsteps: [{ name: x, run: '  ' }]")
            == "steps[0].run: is empty")
        #expect(failure("from: { macos: latest }\naccount: { name: bench }\nname: ../golden").hasPrefix("name: invalid VM name"))
    }

    @Test func everyTemplateIsAValidFileThatLeavesTheLicenseToItsReader() throws {
        for template in ImageTemplate.allCases {
            let file = try decode(template.text)
            #expect(!file.acceptsLicense, "\(template)")
            let steps: [String] = switch template {
            case .ci: ["Install the Command Line Tools", "Check that git works for the account"]
            case .debianDesktop: ["Install Xfce"]
            default: []
            }
            #expect(file.steps.map(\.name) == steps, "\(template)")
            // A Linux image has no license line at all.
            #expect(template.text.contains("# license: accept") == !file.from.isLinux, "\(template)")
        }
        #expect(try decode(ImageTemplate.debian.text).from == .debian(13, .genericcloud))
        #expect(try decode(ImageTemplate.ubuntu.text).from == .ubuntu("26.04"))
        let desktop = try decode(ImageTemplate.debianDesktop.text)
        #expect(desktop.from == .debian(13, .generic) && desktop.desktop && desktop.steps.first?.user == .root)
        #expect(desktop.steps.first?.run.contains("apt-get install -y --no-install-recommends \\\n") == true)
        #expect(try decode(ImageTemplate.minimal.text).from == .latest)
        #expect(try decode(ImageTemplate.ci.text).grants == .recovery)
        #expect(try decode(ImageTemplate.managed.text).grants == .managed)
    }

    /// The commented example steps, uncommented, make a valid file.
    @Test func templateExamplesDecodeWhenUncommented() throws {
        let uncommented = ImageTemplate.minimal.text.replacingOccurrences(of: "# share:", with: "share:")
            .replacingOccurrences(of: "# steps:", with: "steps:")
            .replacingOccurrences(of: "#   ", with: "  ")
        let file = try decode(uncommented)
        #expect(file.share == "installers")
        #expect(file.steps.map(\.user) == [.root, .user, .root, .user])
        #expect(file.steps.first?.run.contains("softwareupdate --install") == true)

        for template in [ImageTemplate.debian, .ubuntu] {
            let linux = try decode(template.text.replacingOccurrences(of: "# share:", with: "share:")
                .replacingOccurrences(of: "# steps:", with: "steps:").replacingOccurrences(of: "#   ", with: "  "))
            #expect(linux.share == "installers", "\(template)")
            #expect(linux.steps.map(\.user) == [.root, .user], "\(template)")
        }
    }
}
