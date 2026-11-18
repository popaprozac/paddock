import Foundation
import Testing
@testable import PaddockCore

@Suite struct OfflineSetupTests {
    private let script = OfflineSetup.recoveryScript(account: "bench", fullName: "Pat O'Brien")

    @Test func haltsOnlyIfEveryStepWorked() {
        let lines = script.split(separator: "\n")
        #expect(lines.last == "halt")
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(" &&") })
    }

    @Test func createsTheAccountAsAnAdmin() {
        let dscl = #"dscl -f "$N" localonly"#
        #expect(script.contains(#"\#(dscl) -create /Local/Target/Users/bench UniqueID 501 &&"#))
        #expect(script.contains(#"\#(dscl) -passwd /Local/Target/Users/bench "$P" &&"#))
        #expect(script.contains("\(dscl) -merge /Local/Target/Groups/admin GroupMembership bench &&"))
        #expect(script.contains(#"touch "$D/private/var/db/.AppleSetupDone" &&"#))
    }

    @Test func quotesTheFullNameForTheShell() {
        #expect(script.contains(#"RealName 'Pat O'\''Brien' &&"#))
    }

    @Test func forgetsThePasswordOnceItIsWritten() throws {
        let unset = try #require(script.range(of: "unset P &&"))
        let lastUse = try #require(script.range(of: #""$P""#, options: .backwards))
        #expect(lastUse.upperBound < unset.lowerBound)
    }

    @Test func logsInAutomaticallyPastThePerUserSetupAssistant() {
        #expect(script.contains(#"> "$D/private/etc/kcpassword" &&"#))
        #expect(script.contains(#"com.apple.loginwindow" autoLoginUser bench &&"#))
        #expect(script.contains(#"defaults write "$A" DidSeePrivacy -bool true &&"#))
        #expect(script.contains(#"defaults write "$A" LastSeenBuddyBuildVersion "$PB" &&"#))
        #expect(script.contains(#"chown -R 501:20 "$H" &&"#))
        #expect(script.contains(#"touch "$D/private/var/db/.AppleDiagnosticsSetupDone" &&"#))
    }

    @Test func canBeTypedOnTheVirtualKeyboard() throws {
        _ = try KeyInput.strokes(typing: script)
    }

    /// The Perl program, run on this Mac: the password, a NUL, NULs to 12 bytes, XORed with the key.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func obscuresThePasswordAsAutomaticLoginReadsIt() throws {
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-e", OfflineSetup.kcpasswordProgram, "hunter2"]
        let output = Pipe()
        perl.standardOutput = output
        try perl.run()
        perl.waitUntilExit()
        let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
        let padded = Array("hunter2".utf8) + [UInt8](repeating: 0, count: 5)
        let expected = padded.enumerated().map { $1 ^ key[$0 % key.count] }
        #expect([UInt8](output.fileHandleForReading.readDataToEndOfFile()) == expected)
    }
}
