import ArgumentParser
import Foundation
import PaddockCore
import Virtualization

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone a VM, boot the clone headless and time each step.",
        discussion: """
            Each run times these steps, then stops and deletes the clone:

              clone    APFS clone of the source with a fresh machine identifier and MAC
              start    build the VM configuration and start it, until Virtualization.framework \
            reports it running
              running  until the guest holds a DHCP lease on the NAT network
              ssh      until the guest's SSH server answers; needs Remote Login on in the source

            start, running and ssh all count from the moment the clone is asked to start.
            """)

    @Argument(help: "VM to clone and boot, usually the golden image.")
    var source: String

    @Option(help: "Number of runs.")
    var runs: Int = 1

    @Option(help: "Seconds to wait for the guest's DHCP lease.")
    var timeout: Int = 300

    @Option(name: .customLong("ssh-timeout"), help: "Seconds to wait for SSH once the guest has a lease.")
    var sshTimeout: Int = 60

    @Flag(help: "Keep each clone on disk after its run instead of deleting it.")
    var keep = false

    func validate() throws {
        try BundleName.validate(source)
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1") }
        guard timeout > 0, sshTimeout > 0 else { throw ValidationError("timeouts must be at least 1 second") }
    }

    func run() async throws {
        try await BenchRunner.run(.init(
            source: source, runs: runs, leaseTimeout: timeout, sshTimeout: sshTimeout, keep: keep))
    }
}

@MainActor
final class BenchRunner: NSObject {
    struct Settings: Sendable {
        var source: String
        var runs: Int
        var leaseTimeout: Int
        var sshTimeout: Int
        var keep: Bool
    }

    struct Sample {
        var clone: Duration
        var start: Duration
        var running: Duration?
        var ssh: Duration?
    }

    private let settings: Settings
    private let home = PaddockHome.fromEnvironment()
    private var clone: VMBundle?
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
            Benchmarking '\(source.name)': \(os), \(config.cpuCount) CPUs, \(config.memorySize >> 30) GB memory, \
            \(settings.runs) run\(settings.runs == 1 ? "" : "s")
            """)
        interrupt = onInterrupt { [weak self] in self?.abort() }

        var samples: [Sample] = []
        for index in 1...settings.runs {
            print("\nRun \(index) of \(settings.runs)")
            samples.append(try await runOnce(source: source))
        }
        if samples.count > 1 {
            printSummary(samples)
        }
        if samples.contains(where: { $0.running == nil }) {
            throw ExitCode.failure
        }
    }

    private func runOnce(source: VMBundle) async throws -> Sample {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-bench-\(UUID().uuidString.prefix(6).lowercased())")
        clone = bundle
        machineFailure = nil
        do {
            let sample = try await measure(source: source, into: bundle)
            await tearDown()
            return sample
        } catch {
            await tearDown()
            throw error
        }
    }

    private func measure(source: VMBundle, into bundle: VMBundle) async throws -> Sample {
        let cloneStarted = ContinuousClock.now
        let config = try VMClone.clone(source, to: bundle)
        let cloneTime = ContinuousClock.now - cloneStarted
        report("clone", cloneTime, "APFS clone '\(bundle.name)', MAC \(config.macAddress)")

        lock = try BundleLock(bundle: bundle)
        let bootStarted = ContinuousClock.now
        let machine = VZVirtualMachine(configuration: try VMConfiguration.make(bundle: bundle, config: config))
        machine.delegate = self
        self.machine = machine
        try await start(machine)
        var sample = Sample(clone: cloneTime, start: ContinuousClock.now - bootStarted)
        report("start", sample.start, "VM configured and running, headless")

        let macAddress = config.macAddress
        guard let ip = try await poll(every: .milliseconds(100), for: .seconds(settings.leaseTimeout), {
            DHCPLeases.ipAddress(for: macAddress)
        }) else {
            report("running", nil, "no DHCP lease within \(settings.leaseTimeout) s")
            return sample
        }
        sample.running = ContinuousClock.now - bootStarted
        report("running", sample.running, "guest leased \(ip)")

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

    private func start(_ machine: VZVirtualMachine) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                machine.start { continuation.resume(with: $0) }
            }
        } catch {
            throw PaddockError("couldn't start the clone: \(error.localizedDescription)")
        }
    }

    /// Forces the clone off, releases it and deletes it unless --keep was given.
    private func tearDown() async {
        if let machine, machine.canStop {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                machine.stop { _ in continuation.resume() }
            }
        }
        machine = nil
        lock = nil
        if let clone, !settings.keep {
            try? FileManager.default.removeItem(at: clone.url)
        } else if let clone {
            print("  kept \(clone.url.path)")
        }
        clone = nil
    }

    private func abort() {
        guard !aborting else { Darwin.exit(130) }
        aborting = true
        print("\nInterrupted; stopping and deleting the clone. Press Ctrl-C again to quit now.")
        Task {
            await tearDown()
            Darwin.exit(130)
        }
    }

    private func report(_ step: String, _ duration: Duration?, _ note: String) {
        let time = duration.map(DurationFormat.short) ?? "-"
        print("  \(step.padding(toLength: 8, withPad: " ", startingAt: 0))\(String(repeating: " ", count: max(0, 8 - time.count)))\(time)   \(note)")
    }

    private func printSummary(_ samples: [Sample]) {
        print("\nMedian of \(samples.count) runs, fastest to slowest in brackets")
        let rows: [(String, [Duration])] = [
            ("clone", samples.map(\.clone)),
            ("start", samples.map(\.start)),
            ("running", samples.compactMap(\.running)),
            ("ssh", samples.compactMap(\.ssh)),
        ]
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
