import Foundation
import PaddockCore

/// The last boot of `paddock build <file>`: runs the image file's steps through the guest agent,
/// checks the image as serve does, and has the guest shut itself down, so what the steps wrote
/// is on disk.
@MainActor
enum ImageSteps {
    /// The first guest agent that can run a step as root; an older one would run it as the
    /// account instead.
    static let agentVersion = "0.6.0"

    /// Boots `name` headless with `share` mounted, runs `steps` in order, then the image check.
    /// Returns the check's problems, or nil if the check couldn't run. Throws at the first step
    /// that fails, after stopping the VM.
    static func run(name: String, steps: [ImageFile.Step], share: URL?) async throws -> [String]? {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let vm = try HeadlessVM(bundle: bundle, config: try bundle.readConfig(), sharing: share)
        print("Booting '\(name)' to run \(steps.count) step\(steps.count == 1 ? "" : "s") and check the image")
        try await vm.start()
        do {
            guard let version = try await vm.agentVersion(within: .seconds(180)) else {
                throw PaddockError("the guest agent in '\(name)' didn't answer within 180 s")
            }
            guard version.compare(agentVersion, options: .numeric) != .orderedAscending else {
                throw PaddockError("'\(name)' has paddock-guestd \(version); steps need \(agentVersion) or later")
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
            print("  checking the image")
            let problems = await vm.imageProblems(sessionHelper: await vm.hasSessionHelper())
            print("  shutting down")
            _ = try await vm.runInGuest("sync; (sleep 2; shutdown -h now) </dev/null >/dev/null 2>&1 &", asRoot: true) { _ in }
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(name)' didn't shut down within 120 s of its steps")
            }
            return problems
        } catch {
            await vm.stop()
            throw error
        }
    }
}
