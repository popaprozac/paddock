import Foundation
import os
import PaddockCore

/// The last boot of `paddock build <file>`: runs the image file's steps through the guest agent,
/// checks the image as serve does, and has the guest shut itself down, so what the steps wrote
/// is on disk.
@MainActor
enum ImageSteps {
    /// The first guest agent that can run a step as root; an older one would run it as the
    /// account instead.
    static let agentVersion = "0.6.0"

    struct Outcome {
        /// The image check's problems, or nil if the check couldn't run.
        var problems: [String]?
        /// A Linux image's enabled display manager, set to log the account in.
        var displayManager: String?
    }

    /// Boots `name` headless with `share` mounted, runs `steps` in order, then the image check.
    /// Throws at the first step that fails, after stopping the VM.
    /// A Linux image's share is at /mnt/share. After its steps, its display manager, if it has
    /// one, is set to log the account in (see `LinuxSeed.desktopSetupScript`), and the image is
    /// sealed (see `LinuxSeed.sealScript`).
    static func run(name: String, steps: [ImageFile.Step], share: URL?) async throws -> Outcome {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let config = try bundle.readConfig()
        let vm = try HeadlessVM(bundle: bundle, config: config, sharing: share)
        print("Booting '\(name)' to run \(steps.count) step\(steps.count == 1 ? "" : "s") and "
            + (config.isLinux ? "seal the image" : "check the image"))
        try await vm.start()
        do {
            guard let version = try await vm.agentVersion(within: .seconds(180)) else {
                throw PaddockError("the guest agent in '\(name)' didn't answer within 180 s")
            }
            // Linux's agent has run steps as root from its first version.
            guard config.isLinux || version.compare(agentVersion, options: .numeric) != .orderedAscending else {
                throw PaddockError("'\(name)' has paddock-guestd \(version); steps need \(agentVersion) or later")
            }
            if config.isLinux {
                try await vm.setGuestClock()
                if share != nil {
                    guard try await vm.runInGuest(LinuxSeed.mountShare, asRoot: true, output: { print("    \($0)") }) == 0 else {
                        throw PaddockError("can't mount the shared folder at /mnt/share in '\(name)'")
                    }
                }
            }
            for (index, step) in steps.enumerated() {
                print("  step \(index + 1) of \(steps.count): \(step.name)\(step.user == .root ? ", as root" : "")")
                // As in CI runners: the first command that fails ends the step.
                let status = try await vm.runInGuest("set -e -o pipefail\n" + step.run, asRoot: step.user == .root) {
                    print("    \($0)")
                }
                guard status == 0 else {
                    throw PaddockError("step '\(step.name)' failed with exit status \(status)")
                }
            }
            var displayManager: String?
            if config.isLinux {
                let lines = OSAllocatedUnfairLock(initialState: [String]())
                let status = try await vm.runInGuest(LinuxSeed.desktopSetupScript, asRoot: true) { line in
                    lines.withLock { $0.append(line) }
                }
                for line in lines.withLock({ $0 }) {
                    if let name = line.split(separator: " ").dropFirst().first, line.hasPrefix("display-manager ") {
                        displayManager = String(name)
                        print("  setting \(name), its display manager, to log the account in")
                    } else {
                        print("    \(line)")
                    }
                }
                guard status == 0 else { throw PaddockError("setting up the desktop of '\(name)' failed") }
                print("  sealing the image")
                guard try await vm.runInGuest(LinuxSeed.sealScript, asRoot: true, output: { print("    \($0)") }) == 0 else {
                    throw PaddockError("sealing '\(name)' failed")
                }
            } else {
                print("  checking the image")
            }
            let problems = await vm.imageProblems(sessionHelper: await vm.hasSessionHelper())
            print("  shutting down")
            _ = try await vm.runInGuest("sync; (sleep 2; shutdown -h now) </dev/null >/dev/null 2>&1 &", asRoot: true) { _ in }
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(name)' didn't shut down within 120 s of its steps")
            }
            return Outcome(problems: problems, displayManager: displayManager)
        } catch {
            await vm.stop()
            throw error
        }
    }
}
