import ArgumentParser
import Foundation
import PaddockCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep a warm clone of a VM running headless, ready to hand out.",
        discussion: """
            serve clones the source into one slot with its own machine identifier and MAC
            address, boots it until its guest agent answers and saves its state. It then restores a fresh
            clone of that saved state and keeps it running. If the warm VM stops, serve
            restores another. 'paddock acquire' takes the warm VM and 'paddock release'
            hands it back to be wiped and replaced; they reach serve through a socket in
            the paddock home that only you can open. Press Ctrl-C to stop serve and delete
            the slot's VMs.
            """)

    @Argument(help: "VM to clone, usually the golden image, with the guest agent installed.")
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
    private static let timeout: Duration = .seconds(300)

    private let home = PaddockHome.fromEnvironment()
    private let slotName: String
    private var saved: VMBundle?    // the slot's paused VM, cloned for every refill
    private var current: VMBundle?  // the clone that is booting, restoring or warm
    private var vm: HeadlessVM?
    private var warmAddress: String?  // set once the current VM's agent answers
    private var assigned = false      // the current VM has been handed out
    private var waiting: [LineServer.Reply] = []  // acquires that came in before a VM was warm
    private var emptyReason: String?  // why the slot holds no VM, after a refill failed
    private var server: LineServer?
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
        // Listen before booting anything: a second serve fails here, and an acquire made
        // during startup waits for the first warm VM.
        server = try LineServer(path: home.socketURL.path, queue: .main) { [weak self] line, reply in
            MainActor.assumeIsolated { self?.handle(line, reply) }
        }
        interrupt = onInterrupt { [weak self] in self?.shutDown() }
        do {
            print("Preparing slot 1 from '\(source.name)': boot a clone once and save its state")
            try await saveBootedClone(of: source)
            try await refill()
        } catch {
            server?.stop()
            await discardCurrent()
            removeSaved()
            throw error
        }
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Boots a clone of `source` with a fresh identity until its agent answers, then saves its state.
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

    /// Restores a fresh clone of the slot's saved state and waits until its agent answers.
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
        vm.onFailure = { [weak self] error in
            print("Slot 1: \(error.message); restoring a fresh clone")
            self?.replaceCurrent()
        }
        warmAddress = ip
        print("Slot 1 warm: '\(bundle.name)' at \(ip), restored in \(DurationFormat.short(ContinuousClock.now - started))")
        handOut()
    }

    private func handle(_ line: String, _ reply: @escaping LineServer.Reply) {
        let request = try? JSONDecoder().decode(ServeRequest.self, from: Data(line.utf8))
        switch request?.op {
        case "acquire":
            if let emptyReason {
                return reply(ServeResponse(error: "slot 1 is empty: \(emptyReason)").line)
            }
            waiting.append(reply)
            handOut()
        case "release":
            release(request?.vm, reply)
        default:
            reply(ServeResponse(error: "unknown request: \(line.prefix(200))").line)
        }
    }

    /// Gives the warm VM to the acquire that has waited longest, once there are both.
    private func handOut() {
        guard !assigned, let warmAddress, let current, !waiting.isEmpty else { return }
        assigned = true
        print("Slot 1 assigned: '\(current.name)' at \(warmAddress)")
        waiting.removeFirst()(ServeResponse(vm: current.name, ip: warmAddress).line)
    }

    private func release(_ name: String?, _ reply: LineServer.Reply) {
        guard assigned, let current, name == current.name else {
            return reply(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        reply(ServeResponse(vm: current.name).line)
        print("Slot 1 released: '\(current.name)'; wiping it and restoring a fresh clone")
        replaceCurrent()
    }

    /// Waits for the guest agent to answer over vsock, then returns the guest's address on the
    /// NAT network for the workload. A restored guest still holds the lease it had when its
    /// state was saved, so its lease is found at once.
    private func waitUntilReady(_ vm: HeadlessVM) async throws -> String {
        guard try await vm.agentVersion(within: Self.timeout) != nil else {
            throw PaddockError("'\(vm.bundle.name)' never answered over vsock; install the guest agent in the golden image")
        }
        guard let ip = try await vm.leasedAddress(within: Self.timeout) else {
            throw PaddockError("'\(vm.bundle.name)' got no DHCP lease within \(DurationFormat.short(Self.timeout))")
        }
        return ip
    }

    /// Throws the current VM away, with everything its user did, and restores a fresh clone.
    private func replaceCurrent() {
        warmAddress = nil
        assigned = false
        Task {
            await discardCurrent()
            do {
                try await refill()
            } catch {
                await discardCurrent()
                emptyReason = error.localizedDescription
                print("Slot 1 is empty: \(error.localizedDescription)")
                answerWaiting(with: "slot 1 is empty: \(error.localizedDescription)")
            }
        }
    }

    private func answerWaiting(with error: String) {
        for reply in waiting {
            reply(ServeResponse(error: error).line)
        }
        waiting.removeAll()
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
        server?.stop()
        answerWaiting(with: "paddock serve stopped")
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
