import ArgumentParser
import Darwin
import Foundation
import PaddockCore

struct Top: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch this Mac's VMs: its CPU, memory and disk, and each slot's VM and what it uses.",
        discussion: """
            Redraws every 2 s until Ctrl-C. Every number is measured on the Mac, never asked of the \
            guest: a VM's CPU and memory are those of its Virtualization.framework process. With \
            --json, or when the output isn't a terminal, prints one snapshot and exits.
            """)

    @OptionGroup var target: Target

    @Flag(help: "Print one snapshot as JSON and exit.")
    var json = false

    @MainActor
    func run() async throws {
        if !target.local, try PoolRoute.identity(local: false) != nil {
            throw PaddockError("paddock top on the pool comes next; use --local for this Mac's serve")
        }
        let live = !json && isatty(STDOUT_FILENO) == 1
        guard live else {
            let status = try await Self.fetch()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode([status]), as: UTF8.self))
            } else {
                print(TopView.lines(of: [status], from: "this Mac's serve", width: 1000).joined(separator: "\n"))
            }
            return
        }
        // The alternate screen, as top and htop use, so Ctrl-C leaves the terminal as it was.
        Self.write("\u{1B}[?1049h\u{1B}[?25l")
        let interrupt = onInterrupt {
            Self.write("\u{1B}[?25h\u{1B}[?1049l")
            Foundation.exit(0)
        }
        defer { withExtendedLifetime(interrupt) {} }
        while true {
            let lines: [String]
            do {
                lines = TopView.lines(of: [try await Self.fetch()], from: "this Mac's serve", width: Self.width())
            } catch {
                // serve may be restarting: keep watching and say why there's nothing to show.
                lines = ["paddock top · this Mac's serve", "", (error as? PaddockError)?.message ?? "\(error)"]
            }
            Self.write("\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\n"))
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// serve's status, from a thread of its own so Ctrl-C is handled while it answers.
    private static func fetch() async throws -> MacStatus {
        try await Task.detached {
            let response = try ServeClient.send(ServeRequest(op: "status"), local: true)
            guard let status = response.status else {
                throw PaddockError("this paddock serve doesn't report status; restart it with this paddock")
            }
            return status
        }.value
    }

    private static func width() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 120
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
