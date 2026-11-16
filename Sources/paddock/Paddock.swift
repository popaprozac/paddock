import ArgumentParser

@main
struct Paddock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "macOS sandboxes on Apple silicon: install, run, clone and benchmark VMs.",
        version: "0.1.0",
        subcommands: [Install.self]
    )
}
