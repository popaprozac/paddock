import ArgumentParser
import CoreFoundation
import Darwin
import Foundation

struct Paddock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paddock",
        abstract: "Sandbox VMs of macOS, Linux and Windows on Apple silicon: build, run, clone, benchmark and serve them.",
        version: "0.2.0",
        subcommands: [Install.self, Run.self, Clone.self, Bench.self, Serve.self, Acquire.self, Exec.self, RunTask.self, Copy.self, Screenshot.self, AXTreeCommand.self, Click.self, TypeText.self, Key.self, Scroll.self, Release.self, Show.self, Hide.self, View.self, MCPCommand.self, Init.self, Build.self, GrantCommand.self, Login.self, Logout.self, Join.self, Leave.self, Hosts.self, Top.self, Askpass.self]
    )

    /// This binary, which scripts/build.sh puts paddock-net and the guest folder next to. Not from
    /// argv[0], which is only "paddock" when a shell found it on PATH.
    static let binary = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
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
        // The command ends the process when it's done. AppKit stops this run loop once a window
        // takes events, as serve's on paddock show, so run it again rather than end the command.
        while true {
            if CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false) == .finished {
                usleep(10_000)  // nothing to run yet: don't spin
            }
        }
    }
}
