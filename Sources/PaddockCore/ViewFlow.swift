import Foundation

/// How many of a view's frames may be in flight, and the bitrate and frame rate the link takes,
/// from the round trips of the frames the viewer acknowledges. From the remote-viewing spike: a
/// window shorter than a round trip freezes once a round trip, and judging the link by its
/// fastest round trip pins a link that swings at the floor.
public struct ViewFlow: Sendable {
    public let maxKbps: Int
    public let maxFPS: Int
    public private(set) var kbps: Int
    public private(set) var fps: Int
    private var sentAt: [Int: Double] = [:]  // frames not yet acknowledged, and when they went (seconds)
    private var thisSecond: [Double] = []    // round trips since the last adapt, in ms
    private var seconds: [Double] = []       // each second's median, the last 30
    private var slowSeconds = 0

    public static let minKbps = 300
    public static let minFPS = 10

    public init(maxKbps: Int, maxFPS: Int) {
        self.maxKbps = maxKbps
        self.maxFPS = maxFPS
        kbps = maxKbps
        fps = maxFPS
    }

    public var inFlight: Int { sentAt.count }

    /// The link's usual round trip in ms: a low percentile of recent seconds, not the lowest,
    /// since a link that swings has the odd freak second far below what it usually does.
    public var usualRoundTrip: Double? {
        guard !seconds.isEmpty else { return nil }
        return seconds.sorted()[seconds.count / 5]
    }

    /// Frames that may be in flight: enough for a round trip and a half at the frame rate, so
    /// serve never sits waiting for acknowledgments that are on their way.
    public var window: Int {
        let roundTrip = (usualRoundTrip ?? 100) / 1000
        return min(32, max(4, Int((Double(fps) * roundTrip * 1.5).rounded(.up)) + 2))
    }

    public var canSend: Bool { inFlight < window }

    public mutating func sent(_ frame: Int, at time: Double) {
        sentAt[frame] = time
    }

    public mutating func acknowledged(_ frame: Int, at time: Double) {
        guard let sent = sentAt.removeValue(forKey: frame) else { return }
        thisSecond.append((time - sent) * 1000)
    }

    /// Call once a second: cuts bitrate and frame rate after two slow seconds in a row (the
    /// round trip well past the usual: the link is queueing), and creeps back up while it stays
    /// near the usual. Returns whether either changed.
    public mutating func adapt() -> Bool {
        guard !thisSecond.isEmpty else { return false }
        let median = thisSecond.sorted()[thisSecond.count / 2]
        thisSecond = []
        seconds = Array((seconds + [median]).suffix(30))
        guard let usual = usualRoundTrip else { return false }
        let before = (kbps, fps)
        // Not before 5 seconds: until then the percentile is just the lowest second.
        slowSeconds = seconds.count >= 5 && median > usual + max(100, usual / 2) ? slowSeconds + 1 : 0
        if slowSeconds >= 2 {
            kbps = max(Self.minKbps, kbps * 3 / 4)
            fps = max(Self.minFPS, fps * 4 / 5)
        } else if median < usual + max(40, usual / 5) {
            kbps = min(maxKbps, kbps * 11 / 10 + 1)
            fps = min(maxFPS, fps + 2)
        }
        return before != (kbps, fps)
    }
}

/// When to apply each of a viewer's input events: with the gaps the viewer had between them, not
/// the bunching a stalled link adds. Bunched, a key could stay down long enough for the guest to
/// repeat it, or go down and up too fast for the guest, which drops a key whose press and release
/// come within about 2 ms. Times are seconds; the viewer's clock and this Mac's never compare
/// directly, only the gaps.
public struct InputTimeline: Sendable {
    private var lag: Double?  // how far this Mac's clock runs ahead of the viewer's stamps, latency included
    private var lastAt = -Double.infinity
    private var lastKeyEdge = -Double.infinity

    /// The least time between key edges the guest takes.
    public static let keyGap = 0.003
    /// How fast added lag drains once the link catches up again, per event.
    static let drain = 0.01

    public init() {}

    /// When to apply an event stamped `stamp` by the viewer that arrived `now`: never before
    /// `now`, never before the event ahead of it, and for a key edge, `keyGap` after the last.
    public mutating func time(for stamp: Double, arrivedAt now: Double, keyEdge: Bool) -> Double {
        // A late arrival (a stall) raises the lag, so what came bunched behind it keeps its gaps;
        // otherwise the lag drains back toward what the link has now.
        let lag = max(now - stamp, (self.lag ?? (now - stamp)) - Self.drain)
        self.lag = lag
        var at = max(stamp + lag, now, lastAt)
        if keyEdge {
            at = max(at, lastKeyEdge + Self.keyGap)
            lastKeyEdge = at
        }
        lastAt = at
        return at
    }
}

/// A watcher's playout buffer: each frame held `delay` past when the link brought frames at its
/// quickest in the last few seconds, then shown with the gaps serve read them off the screen with.
/// A link that delivers in clumps then plays evenly, a stall shorter than `delay` included. Stamps
/// are serve's clock and arrivals the viewer's, in seconds; they never compare directly, only the gaps.
public struct Playout<Frame> {
    public let delay: Double
    private var held: [(frame: Frame, due: Double)] = []  // oldest first, due times never falling
    private var transits: [(arrived: Double, transit: Double)] = []  // the last `window` seconds' frames
    private var lastDue = -Double.infinity

    /// How long the quickest frame sets the pace: a link that gets slower for good is followed after it.
    public static var window: Double { 5 }

    public init(delay: Double) {
        self.delay = delay
    }

    public mutating func add(_ frame: Frame, stamp: Double, arrivedAt now: Double) {
        transits.removeAll { $0.arrived < now - Self.window }
        transits.append((now, now - stamp))
        let lead = transits.map(\.transit).min()!  // how far arrivals run ahead of stamps, at the quickest
        lastDue = max(stamp + lead + delay, lastDue)
        held.append((frame, lastDue))
    }

    /// The frames due by `now`, oldest first: decode them all and show the newest.
    public mutating func due(at now: Double) -> [Frame] {
        let count = held.prefix { $0.due <= now }.count
        defer { held.removeFirst(count) }
        return held.prefix(count).map(\.frame)
    }
}

/// Which gaps between a view's frames are freezes: 150 ms or more while frames were flowing, 10
/// or more in the second before the gap. A still screen sends no frames, so a gap after a quiet
/// second is the screen holding still, not the link stalling.
/// shortcut: a gap after motion stops, until the screen next changes, still counts once; look at
/// the second after the gap too if that skews the numbers.
public struct FreezeCount: Sendable {
    private var recent: [Double] = []  // arrivals, the last within a second of the latest

    public static let gap = 0.15
    public static let flowing = 10

    public init() {}

    /// Notes a frame arriving `now`, in seconds; returns whether the gap before it was a freeze.
    public mutating func arrived(at now: Double) -> Bool {
        defer { recent.append(now) }
        guard let last = recent.last else { return false }
        recent.removeAll { $0 <= last - 1 }
        return now - last >= Self.gap && recent.count >= Self.flowing
    }
}
