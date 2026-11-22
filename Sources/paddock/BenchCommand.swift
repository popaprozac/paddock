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
              network  until the guest says, through its agent, it has an IPv4 address and
                       DNS server
              session  until paddock-session answers in the guest's desktop session, if the
                       source has it installed
              desktop  until paddock-session says loginwindow has finished the login, so the
                       desktop takes input
            start, running, agent, network, session and desktop count from when paddock
            begins configuring the clone.

            With --restore, paddock first boots one clone until it is ready, the last step
            above, then pauses it and saves its state. Each run clones that saved VM, keeping its
            identity, and times these steps in place of start and running:
              restore  until the saved state is loaded into the paused clone
              resume   until the VM is running again
            """)

    @Argument(help: "VM to clone and boot, usually the golden image.")
    var source: String

    @Option(help: "Number of runs.")
    var runs: Int = 1

    @Option(help: "Seconds to wait for each of the guest's DHCP lease, its agent, its network and its session helper.")
    var timeout: Int = 300

    @Flag(help: "Restore a saved state in each run instead of cold booting.")
    var restore = false

    @Flag(help: "Give each VM its own userspace network (paddock-net) instead of the shared NAT.")
    var userspace = false

    @Flag(help: "Keep each clone, and the saved VM with --restore, instead of deleting them.")
    var keep = false

    func validate() throws {
        try BundleName.validate(source)
        guard runs >= 1 else { throw ValidationError("--runs must be at least 1") }
        guard timeout > 0 else { throw ValidationError("--timeout must be at least 1 second") }
    }

    func run() async throws {
        try await BenchRunner.run(.init(
            source: source, runs: runs, timeout: timeout, restore: restore, userspace: userspace, keep: keep))
    }
}

@MainActor
final class BenchRunner: NSObject {
    struct Settings: Sendable {
        var source: String
        var runs: Int
        var timeout: Int
        var restore: Bool
        var userspace: Bool
        var keep: Bool
    }

    struct Sample {
        var clone: Duration
        var restore: Duration?  // restores only
        var start: Duration     // until the VM runs: started, or resumed after a restore
        var running: Duration?  // cold boots only
        var agent: Duration?    // until the guest agent answers over vsock
        var network: Duration?  // until the guest has an IPv4 address and DNS server
        var session: Duration?  // until paddock-session answers, when the source has it
        var desktop: Duration?  // until loginwindow has finished the login, when the source has it
        var expectsSession = false

        /// The last step a guest needs: the desktop if it has the session helper, else the network.
        var ready: Duration? { expectsSession ? desktop : network }
    }

    private let settings: Settings
    private let home = PaddockHome.fromEnvironment()
    private var clone: VMBundle?
    private var saved: VMBundle?  // with --restore, the paused VM every run is cloned from
    private var vm: HeadlessVM?
    private var interrupt: (any DispatchSourceSignal)?
    private var aborting = false
    private var sessionHelper: Bool?  // whether the source has paddock-session, asked once

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
        let os = config.isLinux ? "Linux" : config.isWindows ? "Windows" : config.os.map { "macOS \($0.version) (\($0.build))" } ?? "macOS"
        print("""
            Benchmarking \(settings.restore ? "restores of " : "")'\(source.name)'\(settings.userspace ? " on userspace networks" : ""): \(os), \(config.cpuCount) CPUs, \(config.memorySize >> 30) GB memory, \
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
        // A guest that never got to its last step isn't ready, whatever else it did.
        if samples.contains(where: { $0.ready == nil }) {
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

    /// Cold-boots a clone of `source` until it is ready, then pauses it and saves its state into
    /// the clone's bundle, which every restore run is cloned from.
    private func saveBootedClone(of source: VMBundle) async throws -> VMBundle {
        let bundle = try home.bundle(named: "\(source.name.prefix(40))-saved-\(Self.shortID())")
        clone = bundle
        do {
            let sample = try await measure(source: source, into: bundle, restoring: false)
            guard sample.ready != nil, let vm else {
                throw PaddockError("the clone never became ready, so there is no ready state to save")
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
        let vm = try HeadlessVM(bundle: bundle, config: config, userspaceNetwork: settings.userspace)
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
        if !restoring && !settings.userspace {
            // A restored guest keeps the lease it held when it was saved, so only cold boots wait;
            // paddock-net's DHCP runs inside it, out of sight of the host's lease file.
            let ip = try await vm.leasedAddress(within: timeout)
            sample.running = ip.map { _ in ContinuousClock.now - bootStarted }
            report("running", sample.running, ip.map { "guest leased \($0)" } ?? "no DHCP lease within \(settings.timeout) s")
        }
        let (version, agentTime) = try await agentAnswer
        if let version {
            sample.agent = agentTime
            report("agent", agentTime, "guest agent \(version) answered over vsock")
            if try await vm.networkReady(within: timeout) {
                let networkTime = ContinuousClock.now - bootStarted
                sample.network = networkTime
                report("network", networkTime, "guest has an IPv4 address and DNS server")
                if sessionHelper == nil {
                    sessionHelper = await vm.hasSessionHelper()
                }
                if sessionHelper == true {
                    sample.expectsSession = true
                    if try await vm.sessionHelperVersion(within: timeout) != nil {
                        sample.session = ContinuousClock.now - bootStarted
                        report("session", sample.session, "paddock-session answered: the desktop session is up")
                        if try await vm.desktopReady(within: timeout) {
                            sample.desktop = ContinuousClock.now - bootStarted
                            report("desktop", sample.desktop, "loginwindow has finished the login")
                        } else {
                            report("desktop", nil, "loginwindow still covered the screen after \(settings.timeout) s")
                        }
                    } else {
                        report("session", nil, "paddock-session didn't answer within \(settings.timeout) s; turn on automatic login in '\(source.name)', and boot it once to finish Setup Assistant")
                    }
                }
                if let ready = sample.ready {
                    print("  clone to ready: \(DurationFormat.short(sample.clone + ready))")
                }
            } else {
                report("network", nil, "no IPv4 address and DNS server within \(settings.timeout) s")
            }
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
            rows.append(("start", samples.map(\.start)))
            if !settings.userspace {
                rows.append(("running", samples.compactMap(\.running)))
            }
        }
        rows += [("agent", samples.compactMap(\.agent)), ("network", samples.compactMap(\.network))]
        if samples.contains(where: \.expectsSession) {
            rows += [("session", samples.compactMap(\.session)), ("desktop", samples.compactMap(\.desktop))]
        }
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
