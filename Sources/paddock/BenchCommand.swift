import ArgumentParser
import Foundation
import PaddockCore
import Virtualization

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone a VM, boot the clone headless and time each step.",
        discussion: """
            Each run times these steps, then stops and deletes the clone:
              clone    APFS clone with a fresh machine identifier and MAC address
              start    until Virtualization.framework reports the VM running
              running  until the guest holds a DHCP lease on the NAT network
              ssh      until the guest's SSH server answers; needs Remote Login
            start, running and ssh count from when paddock begins configuring the clone.

            With --restore, paddock first boots one clone until SSH answers, then
            pauses it and saves its state. Each run clones that saved VM, keeping its
            identity, and times these steps in place of start and running:
              restore  until the saved state is loaded into the paused clone
              resume   until the VM is running again
            """)

    @Argument(help: "VM to clone and boot, usually the golden image.")
    var source: String

    @Option(help: "Number of runs.")
    var runs: Int = 1

    @Option(help: "Seconds to wait for the guest's DHCP lease.")
    var timeout: Int = 300

    @Option(name: .customLong("ssh-timeout"), help: "Seconds to wait for SSH once the guest has a lease.")
    var sshTimeout: Int = 60

    @Flag(help: "Restore a saved state in each run instead of cold booting.")
    var restore = false

    @Flag(help: "Keep each clone, and the saved VM with --restore, instead of deleting them.")
    var keep = false

    func validate() throws {
        try BundleName.validate(source)
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1") }
        guard timeout > 0, sshTimeout > 0 else { throw ValidationError("timeouts must be at least 1 second") }
    }

    func run() async throws {
        try await BenchRunner.run(.init(
            source: source, runs: runs, leaseTimeout: timeout, sshTimeout: sshTimeout,
            restore: restore, keep: keep))
    }
}

@MainActor
final class BenchRunner: NSObject {
    struct Settings: Sendable {
        var source: String
        var runs: Int
        var leaseTimeout: Int
        var sshTimeout: Int
        var restore: Bool
        var keep: Bool
    }

    struct Sample {
        var clone: Duration
        var restore: Duration?  // restores only
        var start: Duration     // until the VM runs: started, or resumed after a restore
        var running: Duration?  // cold boots only
        var ssh: Duration?
    }

    private let settings: Settings
    private let home = PaddockHome.fromEnvironment()
    private var clone: VMBundle?
    private var saved: VMBundle?  // with --restore, the paused VM every run is cloned from
    private var lock: BundleLock?
    private var machine: VZVirtualMachine?
    private var machineFailure: PaddockError?
    private var interrupt: (any DispatchSourceSignal)?
    private var aborting = false

    static func run(_ settings: Settings) async throws {
        let runner = BenchRunner(settings: settings)
        defer { withExtendedLifetime(runner) {} }
        try await runner.run()
    }

    private init(settings: Settings) {
        self.settings = settings
    }

    private func run() async throws {
        let source = try home.bundle(named: settings.source)
        let config = try source.readConfig()
        let os = config.os.map { "macOS \($0.version) (\($0.build))" } ?? "macOS"
        print("""
            Benchmarking \(settings.restore ? "restores of " : "")'\(source.name)': \(os), \(config.cpuCount) CPUs, \(config.memorySize >> 30) GB memory, \
            \(settings.runs) run\(settings.runs == 1 ? "" : "s")
            """)
        interrupt = onInterrupt { [weak self] in self?.abort() }

        var samples: [Sample] = []
        do {
            var template = source
            if settings.restore {
                print("\nSaving a booted clone, not counted in the summary")
                template = try await saveBootedClone(of: source)
            }
            for index in 1...settings.runs {
                print("\nRun \(index) of \(settings.runs)")
                samples.append(try await runOnce(source: template))
            }
        } catch {
            removeSaved()
            throw error
        }
        removeSaved()
        if samples.count > 1 {
            printSummary(samples)
        }
        // A cold boot without a lease failed; a restore shows no sign of life other than SSH.
        if samples.contains(where: { settings.restore ? $0.ssh == nil : $0.running == nil }) {
            throw ExitCode.failure
        }
    }

    private func runOnce(source: VMBundle) async throws -> Sample {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-bench-\(Self.shortID())")
        clone = bundle
        machineFailure = nil
        do {
            let sample = try await measure(source: source, into: bundle, restoring: settings.restore)
            await tearDown()
            return sample
        } catch {
            await tearDown()
            throw error
        }
    }

    /// Cold-boots a clone of `source` until SSH answers, then pauses it and saves its state
    /// into the clone's bundle, which every restore run is cloned from.
    private func saveBootedClone(of source: VMBundle) async throws -> VMBundle {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-saved-\(Self.shortID())")
        clone = bundle
        machineFailure = nil
        do {
            let sample = try await measure(source: source, into: bundle, restoring: false)
            guard sample.ssh != nil, let machine else {
                throw PaddockError("the clone never answered SSH, so there is no ready state to save")
            }
            let saveStarted = ContinuousClock.now
            try await perform("pause the clone") { machine.pause(completionHandler: $0) }
            try await perform("save the clone's state") { done in
                machine.saveMachineStateTo(url: bundle.savedStateURL) { error in
                    done(error.map { .failure($0) } ?? .success(()))
                }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.savedStateURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            report("save", ContinuousClock.now - saveStarted, "paused and wrote \(ByteFormat.gigabytes(size)) of state")
        } catch {
            await tearDown()
            throw error
        }
        await stopMachine()
        clone = nil
        saved = bundle
        return bundle
    }

    private func measure(source: VMBundle, into bundle: VMBundle, restoring: Bool) async throws -> Sample {
        let cloneStarted = ContinuousClock.now
        let config = try VMClone.clone(source, to: bundle, keepingSavedState: restoring)
        let cloneTime = ContinuousClock.now - cloneStarted
        report("clone", cloneTime, "APFS clone '\(bundle.name)', MAC \(config.macAddress)")

        lock = try BundleLock(bundle: bundle)
        let bootStarted = ContinuousClock.now
        let machine = VZVirtualMachine(configuration: try VMConfiguration.make(bundle: bundle, config: config))
        machine.delegate = self
        self.machine = machine
        var restoreTime: Duration?
        if restoring {
            try await perform("restore the saved state") { done in
                machine.restoreMachineStateFrom(url: bundle.savedStateURL) { error in
                    done(error.map { .failure($0) } ?? .success(()))
                }
            }
            restoreTime = ContinuousClock.now - bootStarted
            report("restore", restoreTime, "saved state loaded, VM paused")
            try await perform("resume the clone") { machine.resume(completionHandler: $0) }
        } else {
            try await perform("start the clone") { machine.start(completionHandler: $0) }
        }
        var sample = Sample(clone: cloneTime, restore: restoreTime, start: ContinuousClock.now - bootStarted)
        if restoring {
            report("resume", sample.start, "VM running again, headless")
        } else {
            report("start", sample.start, "VM configured and running, headless")
        }

        let macAddress = config.macAddress
        let ip: String
        if restoring {
            // The restored guest still holds the lease it had when its state was saved.
            guard let leased = DHCPLeases.ipAddress(for: macAddress) else {
                throw PaddockError("no DHCP lease for the saved guest's MAC address \(macAddress)")
            }
            ip = leased
        } else {
            guard let leased = try await poll(every: .milliseconds(100), for: .seconds(settings.leaseTimeout), {
                DHCPLeases.ipAddress(for: macAddress)
            }) else {
                report("running", nil, "no DHCP lease within \(settings.leaseTimeout) s")
                return sample
            }
            ip = leased
            sample.running = ContinuousClock.now - bootStarted
            report("running", sample.running, "guest leased \(ip)")
        }

        if try await poll(every: .milliseconds(250), for: .seconds(settings.sshTimeout), {
            SSHProbe.banner(host: ip, timeout: .seconds(1))
        }) != nil {
            sample.ssh = ContinuousClock.now - bootStarted
            report("ssh", sample.ssh, "sshd answered")
        } else {
            report("ssh", nil, "no SSH banner within \(settings.sshTimeout) s; turn on Remote Login in '\(source.name)'")
        }

        if let running = sample.running {
            print("  clone to running: \(DurationFormat.short(sample.clone + running))")
        }
        return sample
    }

    /// Runs `probe` off the main actor until it returns a value, the VM stops, or time runs out.
    private func poll<T: Sendable>(
        every interval: Duration,
        for timeout: Duration,
        _ probe: @escaping @Sendable () -> T?
    ) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let machineFailure { throw machineFailure }
            if let value = await Task.detached(operation: probe).value { return value }
            try await Task.sleep(for: interval)
        }
        return nil
    }

    /// Awaits one Virtualization.framework call that reports back through a completion handler.
    private func perform(
        _ action: String,
        _ call: (@escaping @Sendable (Result<Void, any Error>) -> Void) -> Void
    ) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                call { continuation.resume(with: $0) }
            }
        } catch {
            throw PaddockError("couldn't \(action): \(error.localizedDescription)")
        }
    }

    /// Forces the VM off and releases its bundle.
    private func stopMachine() async {
        if let machine, machine.canStop {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                machine.stop { _ in continuation.resume() }
            }
        }
        machine = nil
        lock = nil
    }

    /// Forces the clone off, releases it and deletes it unless --keep was given.
    private func tearDown() async {
        await stopMachine()
        if let clone {
            remove(clone)
        }
        clone = nil
    }

    private func removeSaved() {
        if let saved {
            remove(saved)
        }
        saved = nil
    }

    private func remove(_ bundle: VMBundle) {
        if settings.keep {
            print("  kept \(bundle.url.path)")
        } else {
            try? FileManager.default.removeItem(at: bundle.url)
        }
    }

    private static func shortID() -> String {
        UUID().uuidString.prefix(6).lowercased()
    }

    private func abort() {
        guard !aborting else { Darwin.exit(130) }
        aborting = true
        print("\nInterrupted; stopping and deleting the clone. Press Ctrl-C again to quit now.")
        Task {
            await tearDown()
            removeSaved()
            Darwin.exit(130)
        }
    }

    private func report(_ step: String, _ duration: Duration?, _ note: String) {
        let time = duration.map(DurationFormat.short) ?? "-"
        print("  \(step.padding(toLength: 8, withPad: " ", startingAt: 0))\(String(repeating: " ", count: max(0, 8 - time.count)))\(time)   \(note)")
    }

    private func printSummary(_ samples: [Sample]) {
        print("\nMedian of \(samples.count) runs, fastest to slowest in brackets")
        var rows: [(String, [Duration])] = [("clone", samples.map(\.clone))]
        if settings.restore {
            rows += [("restore", samples.compactMap(\.restore)), ("resume", samples.map(\.start))]
        } else {
            rows += [("start", samples.map(\.start)), ("running", samples.compactMap(\.running))]
        }
        rows.append(("ssh", samples.compactMap(\.ssh)))
        for (step, values) in rows {
            guard let summary = TimingSummary(values) else {
                report(step, nil, "no successful runs")
                continue
            }
            let counted = values.count == samples.count ? "" : ", \(values.count) of \(samples.count) runs"
            report(step, summary.median,
                   "[\(DurationFormat.short(summary.minimum)) to \(DurationFormat.short(summary.maximum))\(counted)]")
        }
    }
}

extension BenchRunner: @preconcurrency VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        machineFailure = PaddockError("the guest shut down during the benchmark")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        machineFailure = PaddockError("the VM stopped: \(error.localizedDescription)")
    }
}
