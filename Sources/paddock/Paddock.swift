import ArgumentParser
import Darwin

@main
struct Paddock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "macOS sandboxes on Apple silicon: install, run, clone and benchmark VMs.",
        version: "0.1.0",
        subcommands: [Install.self, Run.self, Clone.self, Bench.self]
    )

    /// ArgumentParser's async entry point, plus line-buffered stdout so status lines and progress
    /// stay in order when output goes to a file or a pipe.
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var command = try parseAsRoot()
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
