import Foundation
import os
import PaddockCore

/// Run on Studio inside the guest: a git bundle goes in, a command runs on its branch, and the
/// new commits come back as a bundle. Git never needs the network or credentials in the guest.
extension HeadlessVM {
    struct TaskOutcome: Sendable {
        var status: Int32  // the command's exit status
        var changed: Bool  // whether the result bundle holds new commits
    }

    /// Clones the branch in `bundle` inside the guest, runs `command` in the clone, commits
    /// what it changed and, if the branch gained commits, saves them as a bundle at `result`.
    /// The command's output streams to `output`; it is committed whether or not it succeeds.
    func runTask(
        _ command: String, bundle: URL, result: URL, output: @escaping @Sendable (String) -> Void
    ) async throws -> TaskOutcome {
        let windows = config.isWindows
        try await putInGuest(bundle, as: "in.bundle")
        let cloned = try await runStep(TaskScripts.clone(windows: windows), "clone the bundle")
        // The guest reports the commit to compare against, and it goes back into a command,
        // so it has to look like a commit hash.
        guard let base = cloned.last, base.count >= 40, base.allSatisfy(\.isHexDigit) else {
            throw PaddockError("the guest reported an unreadable commit for the bundle's branch")
        }

        let status = try await runInGuest(TaskScripts.run(command, windows: windows), output: output)

        let saved = try await runStep(TaskScripts.save(since: base, windows: windows), "commit and bundle the result")
        let changed = saved.last == "changed"
        if changed {
            try await getFromGuest("out.bundle", to: result)
        }
        return TaskOutcome(status: status, changed: changed)
    }

    /// Runs one of the task's own steps in the guest and returns the last 5 lines of its output,
    /// or throws with them. Only those are kept: the workload can make its login shell print
    /// without end, and serve holds every VM on this Mac.
    private func runStep(_ script: String, _ what: String) async throws -> [String] {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let status = try await runInGuest(script) { line in
            lines.withLock {
                $0.append(line)
                if $0.count > 5 { $0.removeFirst() }
            }
        }
        let output = lines.withLock { $0 }
        guard status == 0 else {
            throw PaddockError("couldn't \(what) in the guest (exit \(status)): \(output.suffix(5).joined(separator: " / "))")
        }
        return output
    }
}

/// The guest commands of a task: POSIX shell in macOS and Linux guests, and cmd.exe in a Windows
/// guest, whose agent runs commands through it. Both work in the account's paddock folder, where
/// put and get keep files, and author commits as paddock.
private enum TaskScripts {
    static let identity =
        "export GIT_AUTHOR_NAME=paddock GIT_AUTHOR_EMAIL=paddock@localhost GIT_COMMITTER_NAME=paddock GIT_COMMITTER_EMAIL=paddock@localhost"
    static let windowsIdentity = #"set "GIT_AUTHOR_NAME=paddock" && set "GIT_AUTHOR_EMAIL=paddock@localhost" && "#
        + #"set "GIT_COMMITTER_NAME=paddock" && set "GIT_COMMITTER_EMAIL=paddock@localhost""#
    static let windowsWork = #""%USERPROFILE%\paddock\work""#

    /// Clones the bundle that put stored and prints the branch's commit. A Windows clone keeps the
    /// bundle's line endings, rather than Git for Windows' CRLF, so a command that changes nothing
    /// commits nothing.
    static func clone(windows: Bool) -> String {
        if windows {
            // cmd.exe binds && tighter than ||, so the check for git goes in parentheses.
            return #"(where git >nul 2>nul || (echo the guest has no git; install it in the golden image& exit 127)) && "#
                + #"(if exist \#(windowsWork) rd /s /q \#(windowsWork)) && "#
                + #"git clone -q -c core.autocrlf=false "%USERPROFILE%\paddock\in.bundle" \#(windowsWork) && "#
                + #"git -C \#(windowsWork) rev-parse HEAD"#
        }
        return "command -v git >/dev/null || { echo \"the guest has no git; install it in the golden image\"; exit 127; } && "
            + "rm -rf ~/paddock/work && git clone -q ~/paddock/in.bundle ~/paddock/work && git -C ~/paddock/work rev-parse HEAD"
    }

    /// Runs `command` in the clone, in the guest's shell.
    static func run(_ command: String, windows: Bool) -> String {
        windows ? "cd /d \(windowsWork) && \(windowsIdentity) && \(command)" : "cd ~/paddock/work && \(identity) && \(command)"
    }

    /// Commits what changed and, if the branch has commits since `base`, bundles them as
    /// out.bundle and prints "changed".
    static func save(since base: String, windows: Bool) -> String {
        if windows {
            return "cd /d \(windowsWork) && \(windowsIdentity) && git add -A && "
                + #"(git diff --cached --quiet || git commit -q -m "Changes from a paddock task") && "#
                + #"(if exist "%USERPROFILE%\paddock\out.bundle" del /f /q "%USERPROFILE%\paddock\out.bundle") && "#
                + "for /f %n in ('git rev-list --count \(base)..HEAD') do @if %n gtr 0 "
                + #"(git bundle create -q "%USERPROFILE%\paddock\out.bundle" \#(base)..HEAD && echo changed)"#
        }
        return """
            cd ~/paddock/work && \(identity) && git add -A && \
            { git diff --cached --quiet || git commit -q -m 'Changes from a paddock task'; } && \
            rm -f ~/paddock/out.bundle && \
            if [ "$(git rev-list --count \(base)..HEAD)" -gt 0 ]; then \
            git bundle create -q ~/paddock/out.bundle \(base)..HEAD && echo changed; fi
            """
    }
}
