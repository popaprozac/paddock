import ArgumentParser
import CoreFoundation
import Darwin

struct Paddock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "macOS sandboxes on Apple silicon: install, run, clone and benchmark VMs.",
        version: "0.1.0",
        subcommands: [Install.self, Run.self, Clone.self, Bench.self]
    )
}

/// Process entry point.
///
/// Synchronous commands run straight on the main thread. `run` depends on that: AppKit's event
/// loop has to own the main thread, because started from inside a Swift task it would hold the
/// serial main queue that Virtualization.framework callbacks and signal handlers are delivered
/// on. Async commands run in a task while the main thread's run loop services the main queue.
/// That has to be `CFRunLoopRun()`, as Swift's own async entry point uses: `dispatchMain()`
/// drains the main queue on a worker thread, which fails main-actor isolation checks.
@main
enum Entry {
    @MainActor
    static func main() {
        // Line-buffer stdout so status lines and progress stay in order in files and pipes.
        setvbuf(stdout, nil, _IOLBF, 0)

        let parsed: any ParsableCommand
        do {
            parsed = try Paddock.parseAsRoot()
        } catch {
            Paddock.exit(withError: error)
        }

        guard let asyncCommand = parsed as? any AsyncParsableCommand else {
            var command = parsed
            do {
                try command.run()
            } catch {
                Paddock.exit(withError: error)
            }
            Paddock.exit()
        }

        Task.detached {
            var command = asyncCommand
            do {
                try await command.run()
            } catch {
                Paddock.exit(withError: error)
            }
            Paddock.exit()
        }
        CFRunLoopRun()
        Paddock.exit()
    }
}
