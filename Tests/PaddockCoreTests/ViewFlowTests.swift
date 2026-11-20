import Foundation
import Testing
@testable import PaddockCore

@Suite struct ViewFlowTests {
    /// Feeds `seconds` seconds of one acknowledged frame each, at `roundTrip` ms, adapting after each.
    func run(_ flow: inout ViewFlow, seconds: Int, roundTrip: Double, from start: inout Int) {
        for _ in 0..<seconds {
            flow.sent(start, at: 0)
            flow.acknowledged(start, at: roundTrip / 1000)
            _ = flow.adapt()
            start += 1
        }
    }

    @Test func theWindowCoversARoundTripAndAHalf() {
        var flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
        #expect(flow.window == 7)  // 100 ms assumed before any round trip: 30 × 0.1 × 1.5 → 5, plus 2
        var frame = 1
        run(&flow, seconds: 5, roundTrip: 400, from: &frame)
        #expect(flow.window == 20)  // 30 × 0.4 × 1.5 → 18, plus 2
        run(&flow, seconds: 30, roundTrip: 2000, from: &frame)
        #expect(flow.window <= 32)
    }

    @Test func onlyAWindowsWorthGoesOutUnacknowledged() {
        var flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
        for frame in 1...flow.window {
            #expect(flow.canSend)
            flow.sent(frame, at: 0)
        }
        #expect(!flow.canSend)
        flow.acknowledged(1, at: 0.1)
        #expect(flow.canSend)
    }

    @Test func oneSlowSecondDoesntCutButTwoDo() {
        var flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
        var frame = 1
        run(&flow, seconds: 10, roundTrip: 200, from: &frame)
        #expect(flow.kbps == 2000 && flow.fps == 30)
        run(&flow, seconds: 1, roundTrip: 600, from: &frame)
        #expect(flow.kbps == 2000)
        run(&flow, seconds: 1, roundTrip: 600, from: &frame)
        #expect(flow.kbps == 1500 && flow.fps == 24)
        run(&flow, seconds: 20, roundTrip: 600, from: &frame)
        #expect(flow.kbps == ViewFlow.minKbps && flow.fps == ViewFlow.minFPS)
        run(&flow, seconds: 60, roundTrip: 200, from: &frame)
        #expect(flow.kbps == 2000 && flow.fps == 30)
    }

    /// The spike's failure: freak fast seconds among a link's usual 250 ms (it logged 25, 40 and
    /// 47 ms among 200-500) made the usual look like queueing and pinned the view at the floor.
    @Test func aFewFreakFastSecondsDontPinTheLinkAtTheFloor() {
        var flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
        var frame = 1
        for _ in 0..<3 {
            run(&flow, seconds: 9, roundTrip: 250, from: &frame)
            run(&flow, seconds: 1, roundTrip: 30, from: &frame)
        }
        #expect(flow.kbps == 2000 && flow.fps == 30)
    }

    /// The first seconds have too few round trips to judge the link by, so they never cut.
    @Test func theFirstSecondsDontCut() {
        var flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
        var frame = 1
        run(&flow, seconds: 1, roundTrip: 20, from: &frame)
        run(&flow, seconds: 3, roundTrip: 400, from: &frame)
        #expect(flow.kbps == 2000)
    }

    @Test func inputArrivingSteadilyIsAppliedAsItArrives() {
        var timeline = InputTimeline()
        for i in 0..<10 {
            let stamp = Double(i) * 0.05
            #expect(abs(timeline.time(for: stamp, arrivedAt: 100 + stamp, keyEdge: false) - (100 + stamp)) < 1e-9)
        }
    }

    /// After a stall, a press and its release arrive together; they keep the 80 ms between them.
    @Test func inputBunchedByAStallKeepsItsGaps() {
        var timeline = InputTimeline()
        _ = timeline.time(for: 0, arrivedAt: 100, keyEdge: false)
        let down = timeline.time(for: 1.0, arrivedAt: 102, keyEdge: true)
        let up = timeline.time(for: 1.08, arrivedAt: 102, keyEdge: true)
        #expect(down == 102)
        #expect(abs((up - down) - (0.08 - InputTimeline.drain)) < 1e-9)
    }

    @Test func keyEdgesAreNeverCloserThanTheGuestTakes() {
        var timeline = InputTimeline()
        var last = -Double.infinity
        for i in 0..<20 {
            let at = timeline.time(for: 5, arrivedAt: 10 + Double(i) * 0.0001, keyEdge: true)
            #expect(at - last >= InputTimeline.keyGap - 1e-12)
            last = at
        }
    }

    @Test func eventsKeepTheirOrder() {
        var timeline = InputTimeline()
        var last = -Double.infinity
        for (stamp, now) in [(0.0, 10.0), (0.5, 10.1), (0.2, 10.2), (0.9, 10.2), (0.3, 10.3)] {
            let at = timeline.time(for: stamp, arrivedAt: now, keyEdge: false)
            #expect(at >= last && at >= now)
            last = at
        }
    }

    /// Frames, stamped by serve and arriving at the viewer, through a playout polled every ms, as
    /// the viewer's screen refreshes; returns when each came out, up to `poll` after it was due.
    func play(_ frames: [(stamp: Double, arrived: Double)], delay: Double) -> [Double] {
        var playout = Playout<Int>(delay: delay)
        var shown = [Double](repeating: .nan, count: frames.count)
        var next = 0
        for ms in 0..<Int((frames.last!.arrived + delay + 1) * 1000) {
            let now = Double(ms) / 1000
            while next < frames.count, frames[next].arrived <= now {
                playout.add(next, stamp: frames[next].stamp, arrivedAt: frames[next].arrived)
                next += 1
            }
            for frame in playout.due(at: now) { shown[frame] = now }
        }
        return shown
    }

    let poll = 0.0011  // a ms, and rounding

    @Test func aSteadyLinkPlaysEachFrameTheDelayAfterItArrives() {
        let frames = (0..<60).map { i in (stamp: 1000 + Double(i) / 30, arrived: 2 + Double(i) / 30) }  // clocks apart
        let shown = play(frames, delay: 0.4)
        for (frame, at) in zip(frames, shown) {
            #expect(abs(at - (frame.arrived + 0.4)) <= poll)
        }
    }

    /// The spike's hotspot: frames read at 30 a second come in clumps every 0.4 s. Past the first
    /// clump they play at the pace they were read, not 12 at once.
    @Test func aLinkThatClumpsPlaysEvenly() {
        let frames = (0..<180).map { i in
            let stamp = Double(i) / 30
            return (stamp: stamp, arrived: (stamp / 0.4 + 1e-9).rounded(.down) * 0.4 + 0.45)
        }
        let shown = play(frames, delay: 0.4)
        for i in 12..<frames.count {
            #expect(abs((shown[i] - shown[i - 1]) - 1.0 / 30) <= 0.0015)
        }
    }

    /// A view's playout: with no delay, every frame shows as it lands, clumps and all.
    @Test func withNoDelayFramesShowAsTheyLand() {
        let frames = (0..<90).map { i in (stamp: Double(i) / 30, arrived: Double(i / 12) * 0.4 + 0.45) }
        let shown = play(frames, delay: 0)
        for (frame, at) in zip(frames, shown) {
            #expect(abs(at - frame.arrived) <= poll)
        }
    }

    /// A link 0.95 s slower for good: frames show as they land until the quick ones leave the
    /// window, then the delay after they arrive again.
    @Test func aLinkThatGetsSlowerIsFollowed() {
        let frames = (0..<330).map { i in
            let stamp = Double(i) / 30
            return (stamp: stamp, arrived: stamp + (stamp < 3 ? 0.05 : 1.0))
        }
        let shown = play(frames, delay: 0.4)
        let lastQuick = frames.last { $0.stamp < 3 }!.arrived
        for (frame, at) in zip(frames, shown) where frame.stamp >= 3 {
            if frame.arrived < lastQuick + Playout<Int>.window - 0.01 {
                #expect(abs(at - frame.arrived) <= poll)
            } else if frame.arrived > lastQuick + Playout<Int>.window + 0.01 {
                #expect(abs(at - (frame.arrived + 0.4)) <= poll)
            }
        }
    }

    @Test func aGapWhileFramesFlowIsAFreeze() {
        var freezes = FreezeCount()
        let flowing = (0..<30).map { freezes.arrived(at: Double($0) / 30) }
        let short = freezes.arrived(at: 1.1)  // 133 ms after the last: under the gap
        let long = freezes.arrived(at: 1.3)   // 200 ms
        #expect(!flowing.contains(true) && !short && long)
    }

    /// A still screen sends no frames, so typing on one is a frame every few hundred ms.
    @Test func gapsOnAStillScreenArentFreezes() {
        var freezes = FreezeCount()
        var gaps = (0..<20).map { freezes.arrived(at: Double($0) * 0.3) }
        gaps += (0..<5).map { freezes.arrived(at: 10 + Double($0) * 0.12) }  // a quick burst of typing
        gaps.append(freezes.arrived(at: 12))
        #expect(!gaps.contains(true))
    }

    @Test func aLargeFrameGoesInPartsAndLinesStayUnderTheLinkCap() {
        let data = Data(repeating: 7, count: ViewMessage.partSize * 2 + 10)
        let parts = ViewMessage.parts(of: data, number: 4, key: true, at: 12.5)
        #expect(parts.count == 3 && parts.map(\.last) == [false, false, true] && parts.allSatisfy { $0.number == 4 && $0.key && $0.at == 12.5 })
        #expect(parts.reduce(Data()) { $0 + $1.data } == data)
        let line = ViewMessage.line(ViewMessage.Down(frame: parts[0]))
        #expect(line.utf8.count < 400_000)
        #expect(!line.contains("\\/"))
        let back = try? JSONDecoder().decode(ViewMessage.Down.self, from: Data(line.utf8))
        #expect(back?.frame == parts[0])
    }
}
