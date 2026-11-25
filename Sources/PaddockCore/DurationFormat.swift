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

    /// The seconds in a lease as a person gives one: "90s", "30m", "4h" or "2d". Nil for
    /// anything else, including zero.
    public static func seconds(in text: String) -> Int? {
        let units = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
        guard let unit = text.last.flatMap({ units[String($0)] }), let count = Int(text.dropLast()), count > 0 else {
            return nil
        }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: unit)
        return overflow ? nil : seconds
    }

    /// A lease as `seconds(in:)` reads one: "20s", "1h", "1h 30m" or "2d".
    public static func lease(_ seconds: Int) -> String {
        let parts = [(seconds / 86_400, "d"), (seconds % 86_400 / 3600, "h"), (seconds % 3600 / 60, "m"), (seconds % 60, "s")]
        let shown = parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
        return shown.isEmpty ? "0s" : shown.joined(separator: " ")
    }
}
