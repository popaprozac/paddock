import Testing
@testable import PaddockCore

@Suite struct DurationFormatTests {
    @Test func subMillisecond() { #expect(DurationFormat.short(.microseconds(420)) == "0.4 ms") }
    @Test func milliseconds() { #expect(DurationFormat.short(.milliseconds(12)) == "12 ms") }
    @Test func roundsMilliseconds() { #expect(DurationFormat.short(.microseconds(611_600)) == "612 ms") }
    @Test func seconds() { #expect(DurationFormat.short(.milliseconds(18_440)) == "18.4 s") }
    @Test func roundsUpToWholeMilliseconds() { #expect(DurationFormat.short(.microseconds(990)) == "1 ms") }
    @Test func roundsUpToSeconds() { #expect(DurationFormat.short(.microseconds(999_700)) == "1.0 s") }
    @Test func roundsUpToMinutes() { #expect(DurationFormat.short(.milliseconds(59_960)) == "1m 0s") }
    @Test func minutes() { #expect(DurationFormat.short(.seconds(872)) == "14m 32s") }

    @Test func readsALease() {
        #expect(DurationFormat.seconds(in: "90s") == 90)
        #expect(DurationFormat.seconds(in: "30m") == 1800)
        #expect(DurationFormat.seconds(in: "4h") == 14_400)
        #expect(DurationFormat.seconds(in: "2d") == 172_800)
        for wrong in ["", "h", "0h", "-1h", "1.5h", "4 h", "4", "4w", "1h30m", "\(Int.max)d"] {
            #expect(DurationFormat.seconds(in: wrong) == nil, "\(wrong)")
        }
    }

    @Test func writesALease() {
        #expect(DurationFormat.lease(20) == "20s")
        #expect(DurationFormat.lease(3600) == "1h")
        #expect(DurationFormat.lease(5400) == "1h 30m")
        #expect(DurationFormat.lease(172_800) == "2d")
    }
}
