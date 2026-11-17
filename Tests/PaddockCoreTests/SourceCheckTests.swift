import Testing
@testable import PaddockCore

@Suite struct SourceCheckTests {
    @Test func findsNothingWrongInAnImageSetUpForUnattendedVMs() {
        #expect(SourceCheck.problems(in: ["lock=is off", "saver=0", "displaysleep=0", "sleep=0", "files=all"]).isEmpty)
    }

    @Test func namesEachSettingThatBreaksUnattendedVMs() {
        // As a golden image left with macOS's defaults answered in testing.
        let problems = SourceCheck.problems(in: ["lock=delay is immediate", "saver=unset", "displaysleep=10", "sleep=0", "files=limited"])
        #expect(problems.count == 4)
        #expect(problems[0].contains("delay is immediate"))
        #expect(problems[1].contains("20 minutes"))
        #expect(problems[2].contains("display sleeps after 10 minutes"))
        #expect(problems[3].contains("Full Disk Access"))
    }

    @Test func saysWhenItCantReadASetting() {
        #expect(SourceCheck.problems(in: ["displaysleep=0", "sleep=0", "files=all"]).count == 2)
    }
}
