public enum DurationFormat {
    /// "0.4 ms", "12 ms", "18.4 s" or "14m 32s": precise for fast steps, readable for slow ones.
    /// Each unit takes over where the smaller one would round up to it, so 0.99 ms reads "1 ms".
    public static func short(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        switch seconds {
        case ..<0.000_95:
            return "\((seconds * 10_000).rounded() / 10) ms"
        case ..<0.999_5:
            return "\(Int((seconds * 1000).rounded())) ms"
        case ..<59.95:
            return "\((seconds * 10).rounded() / 10) s"
        default:
            let total = Int(seconds.rounded())
            return "\(total / 60)m \(total % 60)s"
        }
    }
}
