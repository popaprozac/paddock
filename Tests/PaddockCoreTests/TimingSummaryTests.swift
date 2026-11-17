import Testing
@testable import PaddockCore

@Suite struct TimingSummaryTests {
    @Test func oddCountUsesTheMiddleValue() throws {
        let summary = try #require(TimingSummary([.milliseconds(30), .milliseconds(10), .milliseconds(20)]))
        #expect(summary.median == .milliseconds(20))
        #expect(summary.minimum == .milliseconds(10))
        #expect(summary.maximum == .milliseconds(30))
    }

    @Test func evenCountAveragesTheTwoMiddleValues() throws {
        let summary = try #require(TimingSummary([.seconds(4), .seconds(1), .seconds(2), .seconds(3)]))
        #expect(summary.median == .milliseconds(2500))
    }

    @Test func emptyHasNoSummary() {
        #expect(TimingSummary([]) == nil)
    }
}
