/// Median and range of repeated measurements of one step.
public struct TimingSummary: Equatable, Sendable {
    public let median: Duration
    public let minimum: Duration
    public let maximum: Duration
    public let count: Int

    public init?(_ samples: [Duration]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        count = sorted.count
    }
}
