public enum DurationFormat {
    /// "0.4 ms", "12 ms", "18.4 s" or "14m 32s": precise for fast steps, readable for slow ones.
    public static func short(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        switch seconds {
        case ..<0.001:
            return "\((seconds * 10_000).rounded() / 10) ms"
        case ..<1:
            return "\(Int((seconds * 1000).rounded())) ms"
        case ..<60:
            return "\((seconds * 10).rounded() / 10) s"
        default:
            let total = Int(seconds.rounded())
            return "\(total / 60)m \(total % 60)s"
        }
    }
}
