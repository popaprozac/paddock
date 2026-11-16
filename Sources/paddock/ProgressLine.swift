import Foundation

/// Shows progress as one updating line in a terminal, or a line per 10% when output is piped.
final class ProgressLine: @unchecked Sendable {
    private let label: String
    private let interactive = isatty(STDOUT_FILENO) == 1
    private let lock = NSLock()
    private var lastPercent = -1

    init(_ label: String) {
        self.label = label
    }

    func update(fraction: Double, detail: String = "") {
        let percent = min(max(Int(fraction * 100), 0), 100)
        lock.withLock {
            guard percent != lastPercent else { return }
            let suffix = detail.isEmpty ? "" : "  \(detail)"
            if interactive {
                write("\r\(label) \(percent)%\(suffix)\u{1B}[K")
            } else if lastPercent < 0 || percent / 10 != lastPercent / 10 {
                write("\(label) \(percent)%\(suffix)\n")
            }
            lastPercent = percent
        }
    }

    func finish() {
        lock.withLock {
            if interactive && lastPercent >= 0 { write("\n") }
        }
    }

    /// Goes through stdio, like `print`, so progress and status lines never interleave out of order.
    private func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }
}
