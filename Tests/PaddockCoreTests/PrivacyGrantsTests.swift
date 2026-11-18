import Testing
@testable import PaddockCore

@Suite struct PrivacyGrantsTests {
    private let script = PrivacyGrants.recoveryScript()

    @Test func haltsOnlyIfEveryStepWorked() {
        let lines = script.split(separator: "\n")
        #expect(script.hasPrefix("set -o pipefail &&\n"))
        #expect(lines.last == "halt")
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(" &&") })
    }

    @Test func writesEachHelpersPermissionWithItsOwnCodeRequirement() {
        #expect(script.contains(#""$D/usr/local/libexec/paddock-session" | sed -n 's/^designated => //p' | "$M/csreq" -r- -b /tmp/paddock-0.csreq"#))
        #expect(script.contains(#""$D/usr/local/libexec/paddock-guestd" | sed -n 's/^designated => //p' | "$M/csreq" -r- -b /tmp/paddock-1.csreq"#))
        #expect(script.contains("values ('kTCCServiceAccessibility', '/usr/local/libexec/paddock-session', 1, 2, 4, 1, readfile('/tmp/paddock-0.csreq'), 0, 0);"))
        #expect(script.contains("values ('kTCCServiceSystemPolicyAllFiles', '/usr/local/libexec/paddock-guestd', 1, 2, 4, 1, readfile('/tmp/paddock-1.csreq'), 0, 0);"))
    }

    @Test func canBeTypedOnTheVirtualKeyboard() throws {
        _ = try KeyInput.strokes(typing: script)
    }
}
