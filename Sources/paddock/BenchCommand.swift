import ArgumentParser
import Foundation
import PaddockCore

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone a VM, boot the clone headless and time each step.",
        discussion: """
            Each run times these steps, then stops and deletes the clone:
              clone    APFS clone with a fresh machine identifier and MAC address
              start    until Virtualization.framework reports the VM running
              running  until the guest holds a DHCP lease on the NAT network
              agent    until the guest agent answers a health check over vsock
            start, running and agent count from when paddock begins configuring the clone.

            With --restore, paddock first boots one clone until its agent answers, then
            pauses it and saves its state. Each run clones that saved VM, keeping its
            identity, and times these steps in place of start and running:
              restore  until the saved state is loaded into the paused clone
              resume   until the VM is running again
            """)

    @Argument(help: "VM to clone and boot, usually the golden image.")
    var source: String

    @Option(help: "Number of runs.")
    var runs: Int = 1

    @Option(help: "Seconds to wait for the guest's DHCP lease and for its agent.")
    var timeout: Int = 300

    @Flag(help: "Restore a saved state in each run instead of cold booting.")
    var restore = false

    @Flag(help: "Keep each clone, and the saved VM with --restore, instead of deleting them.")
    var keep = false

    func validate() throws {
        try BundleName.validate(source)
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1") }
        guard timeout > 0 else { throw ValidationError("--timeout must be at least 1 second") }
    }

    func run() async throws {
        try await BenchRunner.run(.init(
            source: source, runs: runs, timeout: timeout, restore: restore, keep: keep))
    }
}

@MainActor
final class BenchRunner: NSObject {
    struct Settings: Sendable {
        var source: String
        var runs: Int
        var timeout: Int
        var restore: Bool
        var keep: Bool
    }

    struct Sample {
        var clone: Duration
        var restore: Duration?  // restores only
        var start: Duration     // until the VM runs: started, or resumed after a restore
        var running: Duration?  // cold boots only
        var agent: Duration?    // until the guest agent answers over vsock
    }

    private let settings: Settings
    private let home = PaddockHome.fromEnvironment()
    private var clone: VMBundle?
    private var saved: VMBundle?  // with --restore, the paused VM every run is cloned from
    private var vm: HeadlessVM?
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
        // A guest whose agent never answered isn't ready, whatever else it did.
        if samples.contains(where: { $0.agent == nil }) {
            throw ExitCode.failure
        }
    }

    private func runOnce(source: VMBundle) async throws -> Sample {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-bench-\(Self.shortID())")
        clone = bundle
        do {
            let sample = try await measure(source: source, into: bundle, restoring: settings.restore)
            await tearDown()
            return sample
        } catch {
            await tearDown()
            throw error
        }
    }

    /// Cold-boots a clone of `source` until its agent answers, then pauses it and saves its state
    /// into the clone's bundle, which every restore run is cloned from.
    private func saveBootedClone(of source: VMBundle) async throws -> VMBundle {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-saved-\(Self.shortID())")
        clone = bundle
        do {
            let sample = try await measure(source: source, into: bundle, restoring: false)
            guard sample.agent != nil, let vm else {
                throw PaddockError("the clone's agent never answered, so there is no ready state to save")
            }
            let saveStarted = ContinuousClock.now
            try await vm.pauseAndSave()
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

        let bootStarted = ContinuousClock.now
        let vm = try HeadlessVM(bundle: bundle, config: config)
        self.vm = vm
        var restoreTime: Duration?
        if restoring {
            try await vm.restore()
            restoreTime = ContinuousClock.now - bootStarted
            report("restore", restoreTime, "saved state loaded, VM paused")
            try await vm.resume()
        } else {
            try await vm.start()
        }
        var sample = Sample(clone: cloneTime, restore: restoreTime, start: ContinuousClock.now - bootStarted)
        if restoring {
            report("resume", sample.start, "VM running again, headless")
        } else {
            report("start", sample.start, "VM configured and running, headless")
        }

        // The agent and the lease don't depend on each other, so wait for both at once.
        let timeout = Duration.seconds(settings.timeout)
        async let agentAnswer: (String?, Duration) = {
            let version = try await vm.agentVersion(within: timeout)
            return (version, ContinuousClock.now - bootStarted)
        }()
        if !restoring {
            // A restored guest keeps the lease it held when it was saved, so only cold boots wait.
            let ip = try await vm.leasedAddress(within: timeout)
            sample.running = ip.map { _ in ContinuousClock.now - bootStarted }
            report("running", sample.running, ip.map { "guest leased \($0)" } ?? "no DHCP lease within \(settings.timeout) s")
        }
        let (version, agentTime) = try await agentAnswer
        if let version {
            sample.agent = agentTime
            report("agent", agentTime, "guest agent \(version) answered over vsock")
            print("  clone to ready: \(DurationFormat.short(sample.clone + agentTime))")
        } else {
            report("agent", nil, "no answer over vsock within \(settings.timeout) s; install the guest agent in '\(source.name)'")
        }
        return sample
    }

    /// Forces the VM off and releases its bundle.
    private func stopMachine() async {
        await vm?.stop()
        vm = nil
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
        rows.append(("agent", samples.compactMap(\.agent)))
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
