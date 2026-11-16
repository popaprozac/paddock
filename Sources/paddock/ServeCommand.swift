import ArgumentParser
import Foundation
import PaddockCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep a warm clone of a VM running headless, ready to hand out.",
        discussion: """
            serve clones the source into one slot with its own machine identifier and MAC
            address, boots it until SSH answers and saves its state. It then restores a fresh
            clone of that saved state and keeps it running. If the warm VM stops, serve
            restores another. Press Ctrl-C to stop it and delete the slot's VMs.
            """)

    @Argument(help: "VM to clone, usually the golden image. Needs Remote Login turned on.")
    var source: String

    func validate() throws {
        try BundleName.validate(source)
    }

    func run() async throws {
        try await WarmPool.serve(source: source)
    }
}

/// One slot that always holds a warm VM: a clone restored from the slot's own saved state.
///
/// A saved state only restores with the machine identifier and MAC address it was saved with,
/// so the slot keeps one identity, and its VMs run one at a time.
@MainActor
final class WarmPool {
    private static let leaseTimeout: Duration = .seconds(300)
    private static let sshTimeout: Duration = .seconds(60)

    private let home = PaddockHome.fromEnvironment()
    private let slotName: String
    private var saved: VMBundle?    // the slot's paused VM, cloned for every refill
    private var current: VMBundle?  // the clone that is booting, restoring or warm
    private var vm: HeadlessVM?
    private var interrupt: (any DispatchSourceSignal)?
    private var stopping = false

    static func serve(source: String) async throws {
        let pool = WarmPool(source: source)
        defer { withExtendedLifetime(pool) {} }
        try await pool.run(source: source)
    }

    private init(source: String) {
        slotName = "\(source.prefix(40))-slot1-\(Self.shortID())"
    }

    /// Prepares the slot, fills it and serves until Ctrl-C, which exits the process.
    private func run(source name: String) async throws {
        let source = try home.bundle(named: name)
        interrupt = onInterrupt { [weak self] in self?.shutDown() }
        do {
            print("Preparing slot 1 from '\(source.name)': boot a clone once and save its state")
            try await saveBootedClone(of: source)
            try await refill()
        } catch {
            await discardCurrent()
            removeSaved()
            throw error
        }
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Boots a clone of `source` with a fresh identity until SSH answers, then saves its state.
    private func saveBootedClone(of source: VMBundle) async throws {
        let started = ContinuousClock.now
        let bundle = try home.bundle(named: "\(slotName)-saved")
        current = bundle
        let config = try VMClone.clone(source, to: bundle)
        let vm = try HeadlessVM(bundle: bundle, config: config)
        self.vm = vm
        try await vm.start()
        let ip = try await waitUntilReady(vm)
        let booted = ContinuousClock.now - started
        try await vm.pauseAndSave()
        await vm.stop()
        self.vm = nil
        current = nil
        saved = bundle
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.savedStateURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        print("  booted at \(ip) in \(DurationFormat.short(booted)), "
            + "saved \(ByteFormat.gigabytes(size)) of state in \(DurationFormat.short(ContinuousClock.now - started - booted))")
    }

    /// Restores a fresh clone of the slot's saved state and waits until it answers SSH.
    private func refill() async throws {
        guard let saved else { return }
        let started = ContinuousClock.now
        let bundle = try home.bundle(named: "\(slotName)-\(Self.shortID())")
        current = bundle
        let config = try VMClone.clone(saved, to: bundle, keepingSavedState: true)
        let vm = try HeadlessVM(bundle: bundle, config: config)
        self.vm = vm
        try await vm.restore()
        try await vm.resume()
        let ip = try await waitUntilReady(vm)
        vm.onFailure = { [weak self] error in self?.replace(after: error) }
        print("Slot 1 warm: '\(bundle.name)' at \(ip), restored in \(DurationFormat.short(ContinuousClock.now - started))")
    }

    /// Waits for the guest's lease and SSH banner and returns its address. A restored guest
    /// still holds the lease it had when its state was saved, so its lease is found at once.
    private func waitUntilReady(_ vm: HeadlessVM) async throws -> String {
        guard let ip = try await vm.leasedAddress(within: Self.leaseTimeout) else {
            throw PaddockError("'\(vm.bundle.name)' got no DHCP lease within \(DurationFormat.short(Self.leaseTimeout))")
        }
        guard try await vm.sshAnswers(at: ip, within: Self.sshTimeout) else {
            throw PaddockError("'\(vm.bundle.name)' never answered SSH at \(ip); turn on Remote Login in the golden image")
        }
        return ip
    }

    /// The warm VM stopped on its own: throw it away and restore another.
    private func replace(after error: PaddockError) {
        print("Slot 1: \(error.message); restoring a fresh clone")
        Task {
            await discardCurrent()
            do {
                try await refill()
            } catch {
                await discardCurrent()
                print("Slot 1 is empty: \(error.localizedDescription)")
            }
        }
    }

    /// Forces the current VM off and deletes its clone.
    private func discardCurrent() async {
        await vm?.stop()
        vm = nil
        if let current {
            try? FileManager.default.removeItem(at: current.url)
        }
        current = nil
    }

    private func removeSaved() {
        if let saved {
            try? FileManager.default.removeItem(at: saved.url)
        }
        saved = nil
    }

    private func shutDown() {
        guard !stopping else { Darwin.exit(130) }
        stopping = true
        print("\nStopping; deleting slot 1's VMs. Press Ctrl-C again to quit now.")
        Task {
            await discardCurrent()
            removeSaved()
            Darwin.exit(0)
        }
    }

    private static func shortID() -> String {
        UUID().uuidString.prefix(6).lowercased()
    }
}
