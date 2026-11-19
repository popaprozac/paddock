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
            == "licence: unknown key; expected name, from, vm, account, license, grants, share, steps")
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
            == "from: give one of macos: latest or ipsw: <path>")
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
            #expect(file.steps.map(\.name) == (template == .ci
                ? ["Install the Command Line Tools", "Check that git works for the account"] : []), "\(template)")
            #expect(template.text.contains("# license: accept"), "\(template)")
        }
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
    }
}
