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

    /// Commits made in the guest, by the command or for it, are authored as paddock.
    private static let identity =
        "export GIT_AUTHOR_NAME=paddock GIT_AUTHOR_EMAIL=paddock@localhost GIT_COMMITTER_NAME=paddock GIT_COMMITTER_EMAIL=paddock@localhost"

    /// Clones the branch in `bundle` inside the guest, runs `command` in the clone, commits
    /// what it changed and, if the branch gained commits, saves them as a bundle at `result`.
    /// The command's output streams to `output`; it is committed whether or not it succeeds.
    func runTask(
        _ command: String, bundle: URL, result: URL, output: @escaping @Sendable (String) -> Void
    ) async throws -> TaskOutcome {
        try await putInGuest(bundle, as: "in.bundle")
        let cloned = try await runStep(
            "command -v git >/dev/null || { echo \"the guest has no git; install it in the golden image\"; exit 127; } && "
                + "rm -rf ~/paddock/work && git clone -q ~/paddock/in.bundle ~/paddock/work && git -C ~/paddock/work rev-parse HEAD",
            "clone the bundle")
        // The guest reports the commit to compare against, and it goes back into a command,
        // so it has to look like a commit hash.
        guard let base = cloned.last, base.count >= 40, base.allSatisfy(\.isHexDigit) else {
            throw PaddockError("the guest reported an unreadable commit for the bundle's branch")
        }

        let status = try await runInGuest("cd ~/paddock/work && \(Self.identity) && \(command)", output: output)

        let saved = try await runStep("""
            cd ~/paddock/work && \(Self.identity) && git add -A && \
            { git diff --cached --quiet || git commit -q -m 'Changes from a paddock task'; } && \
            rm -f ~/paddock/out.bundle && \
            if [ "$(git rev-list --count \(base)..HEAD)" -gt 0 ]; then \
            git bundle create -q ~/paddock/out.bundle \(base)..HEAD && echo changed; fi
            """, "commit and bundle the result")
        let changed = saved.last == "changed"
        if changed {
            try await getFromGuest("out.bundle", to: result)
        }
        return TaskOutcome(status: status, changed: changed)
    }

    /// Runs one of the task's own steps in the guest and returns its output, or throws with the
    /// end of that output.
    private func runStep(_ script: String, _ what: String) async throws -> [String] {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let status = try await runInGuest(script) { line in lines.withLock { $0.append(line) } }
        let output = lines.withLock { $0 }
        guard status == 0 else {
            throw PaddockError("couldn't \(what) in the guest (exit \(status)): \(output.suffix(5).joined(separator: " / "))")
        }
        return output
    }
}
