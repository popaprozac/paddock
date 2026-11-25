import Foundation
import PaddockCore
import Testing
@testable import paddock

/// A VM handed out lapses only once nothing used it for its whole lease.
@MainActor @Suite struct LeaseTests {
    @Test func lapsesOnlyOnceUnusedForItsLease() throws {
        let slot = Slot(number: 1, source: "golden")
        let (acquire, _) = try ResponderPipe.make()
        slot.startLease(60, with: acquire)
        acquire.finish()
        let start = ContinuousClock.now
        #expect(!slot.lapsed(at: start + .seconds(120)), "a slot with nothing handed out never lapses")

        slot.assigned = true
        #expect(!slot.lapsed(at: start + .seconds(30)))
        let (build, _) = try ResponderPipe.make()
        slot.use(by: build)
        #expect(!slot.lapsed(at: start + .seconds(600)), "a request still running keeps it in use")
        build.finish()
        #expect(!slot.lapsed(at: start + .seconds(650)), "unused for 50 s of 60 since it was last seen running")
        #expect(slot.lapsed(at: start + .seconds(661)))
    }

    @Test func aDroppedRequestStopsCountingAsUse() throws {
        let slot = Slot(number: 1, source: "golden")
        slot.assigned = true
        do {
            let (dropped, _) = try ResponderPipe.make()
            slot.startLease(60, with: dropped)
        }
        #expect(slot.lapsed(at: .now + .seconds(61)))
    }
}
