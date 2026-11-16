import Testing
@testable import PaddockCore

@Suite struct DurationFormatTests {
    @Test func subMillisecond() { #expect(DurationFormat.short(.microseconds(420)) == "0.4 ms") }
    @Test func milliseconds() { #expect(DurationFormat.short(.milliseconds(12)) == "12 ms") }
    @Test func roundsMilliseconds() { #expect(DurationFormat.short(.microseconds(611_600)) == "612 ms") }
    @Test func seconds() { #expect(DurationFormat.short(.milliseconds(18_440)) == "18.4 s") }
    @Test func minutes() { #expect(DurationFormat.short(.seconds(872)) == "14m 32s") }
}
