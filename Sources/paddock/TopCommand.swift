import ArgumentParser
import Darwin
import Foundation
import PaddockCore

struct Top: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch the pool's Macs, or this Mac's: CPU, memory and disk, and each slot's VM and what it uses.",
        discussion: """
            On a Mac logged in to a control plane, shows every Mac in its pool and who holds each \
            VM; with --local, or with no login, this Mac's serve. Redraws every 2 s until Ctrl-C. \
            Every number is measured on the Macs, never asked of a guest: a VM's CPU and memory are \
            those of its Virtualization.framework process. With --json, or when the output isn't a \
            terminal, prints one snapshot and exits.
            """)

    @OptionGroup var target: Target

    @Flag(help: "Print one snapshot as JSON and exit.")
    var json = false

    @MainActor
    func run() async throws {
        let watcher = Watcher(pool: try PoolRoute.identity(local: target.local))
        let live = !json && isatty(STDOUT_FILENO) == 1
        guard live else {
            let snapshot = try await watcher.fetch()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(snapshot.macs), as: UTF8.self))
            } else {
                let lines = TopView.lines(of: snapshot.macs, from: watcher.source, waiting: snapshot.waiting, width: 1000)
                print(lines.joined(separator: "\n"))
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
                let snapshot = try await watcher.fetch()
                lines = TopView.lines(of: snapshot.macs, from: watcher.source, waiting: snapshot.waiting, width: Self.width())
            } catch {
                // serve or the control plane may be restarting: keep watching and say why.
                lines = ["paddock top · \(watcher.source)", "", (error as? PaddockError)?.message ?? "\(error)"]
            }
            Self.write("\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\n"))
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func width() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 120
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

/// Where `top` reads from: the pool, over one link it keeps open and opens again if it drops, or
/// this Mac's serve.
@MainActor
private final class Watcher {
    private let pool: ControlIdentity?
    private var connection: PoolConnection?

    init(pool: ControlIdentity?) {
        self.pool = pool
    }

    var source: String {
        guard let pool else { return "this Mac's serve" }
        let port = pool.url.port.map { ":\($0)" } ?? ""
        return "the pool at \(pool.url.host() ?? pool.url.absoluteString)\(port)"
    }

    func fetch() async throws -> (macs: [MacStatus], waiting: Int?) {
        guard let pool else { return ([try await Self.local()], nil) }
        do {
            let connection: PoolConnection
            if let open = self.connection {
                connection = open
            } else {
                connection = try await PoolConnection.open(pool)
                self.connection = connection
            }
            let reply = try await connection.ask(ControlLink.Message(type: "request", op: "hosts")).last
            let macs = (reply?.hosts ?? []).sorted { $0.name < $1.name }.map {
                MacStatus(name: $0.name, image: $0.image, online: $0.online, usage: $0.usage, slots: $0.slots ?? [])
            }
            return (macs, reply?.waiting)
        } catch {
            connection?.close()
            connection = nil
            throw error
        }
    }

    /// This Mac's serve's status, from a thread of its own so Ctrl-C is handled while it answers.
    private static func local() async throws -> MacStatus {
        try await Task.detached {
            let response = try ServeClient.send(ServeRequest(op: "status"), local: true)
            guard let status = response.status else {
                throw PaddockError("this paddock serve doesn't report status; restart it with this paddock")
            }
            return status
        }.value
    }
}
