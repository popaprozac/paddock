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
    private let machine: VZVirtualMachine
    /// Set once the guest shuts down or the VM stops with an error; the waits below throw it.
    private(set) var failure: PaddockError?

    init(bundle: VMBundle, config: VMConfig) throws {
        lock = try BundleLock(bundle: bundle)
        machine = VZVirtualMachine(configuration: try VMConfiguration.make(bundle: bundle, config: config))
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
        guard machine.canStop else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            machine.stop { _ in continuation.resume() }
        }
    }

    /// Waits for the guest's DHCP lease on the NAT network and returns its address, or nil
    /// after `timeout`. Checks every 100 ms.
    func leasedAddress(within timeout: Duration) async throws -> String? {
        let macAddress = config.macAddress
        return try await poll(every: .milliseconds(100), for: timeout) {
            DHCPLeases.ipAddress(for: macAddress)
        }
    }

    /// Waits for the guest's SSH server to send its banner; false after `timeout`. Checks
    /// every 250 ms.
    func sshAnswers(at ip: String, within timeout: Duration) async throws -> Bool {
        let banner = try await poll(every: .milliseconds(250), for: timeout) {
            SSHProbe.banner(host: ip, timeout: .seconds(1))
        }
        return banner != nil
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
        failure = PaddockError("the guest in '\(bundle.name)' shut down")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        failure = PaddockError("'\(bundle.name)' stopped: \(error.localizedDescription)")
    }
}
