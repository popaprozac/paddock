import Foundation
import PaddockCore
import Virtualization

/// A VM that paddock drives without a window: start or restore it, wait for the guest to come
/// up on the network, save its state, and force it off.
///
/// The bundle stays locked for as long as this object lives. Virtualization.framework calls
/// back on the main queue, so this lives on the main actor.
@MainActor
final class HeadlessVM: NSObject {
    let bundle: VMBundle
    let config: VMConfig
    private let lock: BundleLock
    private let network: UserspaceNetwork?
    private let machine: VZVirtualMachine
    /// Set once the guest shuts down or the VM stops with an error; the waits below throw it.
    private(set) var failure: PaddockError?
    /// Called when `failure` is set, for a VM that nothing is waiting on.
    var onFailure: ((PaddockError) -> Void)?

    /// With `userspaceNetwork`, the VM's network is its own paddock-net process, which stops with
    /// this object, instead of macOS's shared NAT.
    init(bundle: VMBundle, config: VMConfig, userspaceNetwork: Bool = false) throws {
        lock = try BundleLock(bundle: bundle)
        network = userspaceNetwork ? try UserspaceNetwork(helper: Self.helperURL, macAddress: config.macAddress) : nil
        machine = VZVirtualMachine(configuration: try VMConfiguration.make(
            bundle: bundle, config: config, network: network?.attachment))
        self.bundle = bundle
        self.config = config
        super.init()
        machine.delegate = self
    }

    func start() async throws {
        try await perform("start the clone") { machine.start(completionHandler: $0) }
    }

    /// Loads the bundle's saved state. The VM is paused afterwards; `resume()` runs it.
    func restore() async throws {
        let url = bundle.savedStateURL
        try await perform("restore the saved state") { done in
            machine.restoreMachineStateFrom(url: url) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func resume() async throws {
        try await perform("resume the clone") { machine.resume(completionHandler: $0) }
    }

    /// Pauses the VM and writes its memory and device state to the bundle's saved-state file.
    func pauseAndSave() async throws {
        try await perform("pause the clone") { machine.pause(completionHandler: $0) }
        let url = bundle.savedStateURL
        try await perform("save the clone's state") { done in
            machine.saveMachineStateTo(url: url) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    /// Forces the VM off without letting the guest shut down.
    func stop() async {
        if machine.canStop {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                machine.stop { _ in continuation.resume() }
            }
        }
        network?.stop()
    }

    /// paddock-net, which build.sh puts next to the paddock binary.
    private static var helperURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("paddock-net")
    }

    /// Waits for the guest's DHCP lease on the NAT network and returns its address, or nil
    /// after `timeout`. Checks every 100 ms.
    func leasedAddress(within timeout: Duration) async throws -> String? {
        // paddock-net's DHCP always gives the guest the same address.
        if network != nil {
            return UserspaceNetwork.guestIP
        }
        let macAddress = config.macAddress
        return try await poll(every: .milliseconds(100), for: timeout) {
            DHCPLeases.ipAddress(for: macAddress)
        }
    }

    /// Waits for the guest agent to answer a health check over vsock and returns the version it
    /// reports, or nil after `timeout`. Checks every 100 ms. The answer only shows that
    /// something in the guest is listening; a hostile guest can say anything.
    func agentVersion(within timeout: Duration) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure { throw failure }
            if let version = await askAgentForHealth() { return version }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Waits until the guest says, through its agent, that it has an IPv4 address and an IPv4
    /// DNS server, or returns false after `timeout`. Checks every 100 ms. A restored guest
    /// renegotiates its network after it resumes, so its agent answers before it can reach
    /// anything; its IPv6 DNS server stays listed through the restore, so only IPv4 counts. The
    /// answer only decides when the guest is handed out, so a guest that lies hurts only itself.
    func networkReady(within timeout: Duration) async throws -> Bool {
        let check = "ipconfig getifaddr en0 >/dev/null && scutil --dns | grep -qE 'nameserver\\[[0-9]+\\] : [0-9.]+$'"
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure { throw failure }
            if (try? await runInGuest(check, output: { _ in })) == 0 { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Runs `command` in the guest through its agent over vsock, passing each output line to
    /// `output` as it arrives, and returns the command's exit status.
    func runInGuest(_ command: String, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withAgent { try GuestAgent.askToRun(command, over: $0, output: output) }
    }

    /// Copies the file at `url` into the guest agent's files folder as `name`.
    func putInGuest(_ url: URL, as name: String) async throws {
        try await withAgent { try GuestAgent.askToPut(url, as: name, over: $0) }
    }

    /// Copies `name` from the guest agent's files folder to `url`.
    func getFromGuest(_ name: String, to url: URL) async throws {
        try await withAgent { _ = try GuestAgent.askToGet(name, to: url, over: $0) }
    }

    /// Connects to the agent and runs `exchange` on a thread of its own: commands and file
    /// transfers can take a long time and would otherwise hold one of Swift concurrency's few
    /// threads.
    private func withAgent<T: Sendable>(_ exchange: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        guard let fd = await connectToAgent() else {
            throw PaddockError("can't reach the guest agent in '\(bundle.name)'")
        }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                defer { close(fd) }
                continuation.resume(with: Result { try exchange(fd) })
            }
        }
    }

    private func askAgentForHealth() async -> String? {
        guard let fd = await connectToAgent() else { return nil }
        return await Task.detached {
            defer { close(fd) }
            return try? GuestAgent.ask(GuestAgent.Request(op: "health"), over: fd).version
        }.value
    }

    /// Opens a vsock connection to the agent and returns a descriptor the caller owns, so the
    /// blocking exchange can run off the main actor. Nil if nothing in the guest is listening, or
    /// if Virtualization.framework hasn't called back within 2 s: now and then it never does.
    private func connectToAgent() async -> Int32? {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else { return nil }
        let once = Once()
        return await withCheckedContinuation { continuation in
            device.connect(toPort: GuestAgent.port) { result in
                MainActor.assumeIsolated {
                    var fd: Int32?
                    if case .success(let connection) = result {
                        let copy = dup(connection.fileDescriptor)
                        connection.close()
                        fd = copy >= 0 ? copy : nil
                    }
                    guard !once.done else {
                        if let fd { close(fd) }  // too late: the caller has moved on
                        return
                    }
                    once.done = true
                    continuation.resume(returning: fd)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Runs `probe` off the main actor until it returns a value, the VM stops, or time runs out.
    private func poll<T: Sendable>(
        every interval: Duration,
        for timeout: Duration,
        _ probe: @escaping @Sendable () -> T?
    ) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure { throw failure }
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
}

extension HeadlessVM: @preconcurrency VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let error = PaddockError("the guest in '\(bundle.name)' shut down")
        failure = error
        onFailure?(error)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let failure = PaddockError("'\(bundle.name)' stopped: \(error.localizedDescription)")
        self.failure = failure
        onFailure?(failure)
    }
}

/// Whether a continuation was resumed, for two callbacks that race to resume it on the main actor.
@MainActor
private final class Once {
    var done = false
}
