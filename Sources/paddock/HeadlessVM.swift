import Foundation
import os
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
    /// this object, instead of macOS's shared NAT. `sharing` mounts a host folder read-only in the
    /// guest at /Volumes/My Shared Files. `seed` attaches a disk image read-only, as a Linux build's
    /// cloud-init seed.
    init(bundle: VMBundle, config: VMConfig, userspaceNetwork: Bool = false, sharing: URL? = nil, seed: URL? = nil) throws {
        lock = try BundleLock(bundle: bundle)
        network = userspaceNetwork
            ? try UserspaceNetwork(helper: Self.helperURL, macAddress: config.macAddress,
                                   controlPath: bundle.url.appendingPathComponent("net.sock").path)
            : nil
        machine = VZVirtualMachine(configuration: try VMConfiguration.make(
            bundle: bundle, config: config, sharing: sharing, network: network?.attachment, seed: seed))
        self.bundle = bundle
        self.config = config
        super.init()
        machine.delegate = self
    }

    /// A VM for `bundle`, started by `start`. Started right after `install` in the same process,
    /// the VM that installed macOS may not have let go of the bundle's auxiliary storage yet, and
    /// Virtualization says nothing when it does, so this tries again with a fresh VM for up to 15 s.
    /// shortcut: a retry on that one error; a completion signal from Virtualization would replace it.
    static func started(bundle: VMBundle, sharing: URL?,
                        start: (HeadlessVM) async throws -> Void) async throws -> HeadlessVM {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let vm = try HeadlessVM(bundle: bundle, config: try bundle.readConfig(), sharing: sharing)
            // Attached before the first frame, so there is a screen to read and to save on failure.
            try? vm.attachScreen()
            do {
                try await start(vm)
                return vm
            } catch let error as PaddockError where error.message.contains("lock auxiliary storage")
                && ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    func start() async throws {
        try await perform("start the clone") { machine.start(completionHandler: $0) }
    }

    /// Starts a VM that has never booted, with guest provisioning: see Provisioning.
    @available(macOS 27, *)
    func start(provisioning: VZMacGuestProvisioningOptions) async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        try await perform("start the VM") { done in
            machine.start(options: options) { error in done(error.map { .failure($0) } ?? .success(())) }
        }
    }

    /// Starts the VM in macOS Recovery.
    func startInRecovery() async throws {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        try await perform("start the VM in macOS Recovery") { done in
            machine.start(options: options) { error in done(error.map { .failure($0) } ?? .success(())) }
        }
    }

    /// Waits for the guest to shut itself down; false if it is still running after `timeout`.
    func waitUntilStopped(within timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if machine.state == .stopped { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return machine.state == .stopped
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

    private var screen: VMScreen?

    /// Puts the VM's display in an off-screen window now, so screenshots have frames to read. The
    /// guest only sends a frame when its screen changes: a view attached to a guest that has gone
    /// still shows nothing, so attach before a restored VM resumes and redraws.
    func attachScreen() throws {
        guard config.hasScreen else {
            throw PaddockError("'\(bundle.name)' is a Linux VM without a desktop, so it has no screen or input in paddock; "
                + "run commands in it instead")
        }
        if screen == nil {
            screen = try VMScreen(machine: machine, display: config.display)
        }
    }

    /// Clicks in the guest through its virtual pointer, at its screen pixels from the top left.
    func click(x: Int, y: Int, button: VMScreen.MouseButton, count: Int) throws {
        try drivenScreen().click(x: x, y: y, button: button, count: count)
    }

    /// Presses keys on the guest's virtual keyboard.
    func press(_ strokes: [KeyStroke]) async throws {
        try await drivenScreen().press(strokes)
    }

    /// Scrolls in the guest by lines at its screen pixels from the top left.
    func scroll(x: Int, y: Int, down: Int, right: Int) throws {
        try drivenScreen().scroll(x: x, y: y, down: down, right: right)
    }

    /// Puts the VM's window on this Mac's screen for a person; `handBack` runs when they close it.
    func show(title: String, handBack: @escaping () -> Void) throws {
        try drivenScreen().show(title: title, handBack: handBack)
    }

    /// Puts the VM's window back off screen, if a person has it.
    func hide() {
        screen?.hide()
    }

    /// Whether a person has the VM's window on screen.
    var isShown: Bool {
        screen?.isShown ?? false
    }

    /// Whether a person is viewing and driving the VM with `paddock view`, from this Mac or another.
    var isViewed = false

    /// How many people are following the VM with `paddock view --watch`, which takes no input.
    var watchers = 0

    /// The screen a view reads and drives, attaching the display first if nothing has.
    func viewScreen() throws -> VMScreen {
        try drivenScreen()
    }

    private func drivenScreen() throws -> VMScreen {
        if let failure { throw failure }
        try attachScreen()
        guard let screen else { throw PaddockError("'\(bundle.name)' has no screen") }
        return screen
    }

    /// The guest's screen as it is now, attaching the display first if nothing has; then it
    /// waits up to 5 s for the first frame.
    func screenshot() async throws -> CGImage {
        if let failure { throw failure }
        try attachScreen()
        guard let screen else { throw PaddockError("'\(bundle.name)' has no screen") }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let image = try screen.capture() { return image }
            guard ContinuousClock.now < deadline else {
                throw PaddockError("'\(bundle.name)' showed no frame within 5 s")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Forces the VM off without letting the guest shut down.
    func stop() async {
        screen?.close()
        screen = nil
        if machine.canStop {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                machine.stop { _ in continuation.resume() }
            }
        }
        network?.stop()
    }

    /// Lets the guest reach only `names`, on the userspace network.
    func allow(_ names: [String]) throws {
        guard let network else {
            throw PaddockError("'\(bundle.name)' is on the NAT network, which has no allowlist")
        }
        try network.allow(names)
    }

    /// paddock-net, which build.sh puts next to the paddock binary.
    private static var helperURL: URL {
        Paddock.binary.deletingLastPathComponent().appendingPathComponent("paddock-net")
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
        try await version(at: GuestAgent.port, within: timeout)
    }

    /// Whether the guest has paddock-session installed, asked through its agent.
    func hasSessionHelper() async -> Bool {
        if let state = await state() {
            return state.contains("session-helper")
        }
        return (try? await runInGuest("test -x \(SessionHelper.installedPath)", output: { _ in })) == 0
    }

    /// Waits for paddock-session to answer a health check over vsock and returns its version, or
    /// nil after `timeout`. It starts when its user logs in to the desktop, so an answer means the
    /// desktop session is up. Like the agent's, the answer can't be trusted beyond that.
    func sessionHelperVersion(within timeout: Duration) async throws -> String? {
        try await version(at: SessionHelper.port, within: timeout)
    }

    /// Waits until paddock-session says loginwindow has finished the login, so the desktop takes
    /// clicks and keys, or returns false after `timeout`. Checks every 100 ms. A helper before
    /// 0.2.0 can't say, so for one the wait ends at once, as it did before. In a Linux VM, the
    /// guest agent says so instead, once the account's desktop is up and drawn.
    func desktopReady(within timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure { throw failure }
            if config.isLinux {
                if await state()?.contains("desktop") == true { return true }
            } else if let state = await state(at: SessionHelper.port, name: "paddock-session") {
                if state.contains("desktop") { return true }
            } else if withoutState.contains(SessionHelper.port) {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Asks the listener on `port` for its version every 100 ms until it answers or `timeout` passes.
    private func version(at port: UInt32, within timeout: Duration) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let failure { throw failure }
            if let version = await askForHealth(port: port) { return version }
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
            if let state = await state() {
                if state.contains("network") { return true }
            } else if (try? await runInGuest(check, output: { _ in })) == 0 {
                return true  // an agent before 0.4.0, checked through a command
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Ports whose listener refused `state`: an agent before 0.4.0, a session helper before 0.2.0.
    private var withoutState: Set<UInt32> = []

    /// What the agent, or the listener on `port`, says holds in the guest, or nil if it can't
    /// say: it is unreachable, or older than the `state` request. An agent that old costs a sudo
    /// and a login shell per check instead.
    private func state(at port: UInt32 = GuestAgent.port, name: String = "the guest agent") async -> Set<String>? {
        guard !withoutState.contains(port) else { return nil }
        do {
            let lines = try await withAgent(port: port, name: name) { fd in
                var lines: [String] = []
                _ = try GuestAgent.askStreaming(GuestAgent.Request(op: "state"), over: fd) { lines.append($0) }
                return lines
            }
            return Set(lines)
        } catch let error as PaddockError where error.message.contains("unknown request") {
            withoutState.insert(port)
            return nil
        } catch {
            return nil
        }
    }

    /// Runs `command` in the guest through its agent over vsock, passing each output line to
    /// `output` as it arrives, and returns the command's exit status.
    func runInGuest(_ command: String, asRoot: Bool = false, output: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try await withAgent { try GuestAgent.askToRun(command, asRoot: asRoot, over: $0, output: output) }
    }

    /// Sets a Linux guest's clock to this Mac's. A restored guest resumes at the time its state was
    /// saved, and Linux, unlike macOS, doesn't notice the jump.
    func setGuestClock() async throws {
        try await withAgent { try GuestAgent.askToSetClock(to: Date(), over: $0) }
    }

    /// Copies the file at `url` into the guest agent's files folder as `name`.
    func putInGuest(_ url: URL, as name: String) async throws {
        try await withAgent { try GuestAgent.askToPut(url, as: name, over: $0) }
    }

    /// Copies `name` from the guest agent's files folder to `url`.
    func getFromGuest(_ name: String, to url: URL) async throws {
        try await withAgent { _ = try GuestAgent.askToGet(name, to: url, over: $0) }
    }

    /// Asks for the focused app's accessibility tree, passing each line of its JSON to `output`:
    /// from paddock-session, in the guest's desktop session, on macOS; from the guest agent, which
    /// reads AT-SPI, on a Linux desktop.
    func accessibilityTree(output: @escaping @Sendable (String) -> Void) async throws {
        guard config.isLinux else {
            return try await withAgent(port: SessionHelper.port, name: "paddock-session") {
                try SessionHelper.askForTree(over: $0, output: output)
            }
        }
        guard config.hasScreen else {
            throw PaddockError("'\(bundle.name)' is a Linux VM without a desktop, so it has no accessibility tree")
        }
        do {
            try await withAgent { try SessionHelper.askForTree(over: $0, output: output) }
        } catch let error as PaddockError where error.message.contains("unknown request") {
            throw PaddockError("the guest agent in '\(bundle.name)' predates Linux accessibility trees; rebuild the image")
        }
    }

    /// What in the image this VM booted from breaks VMs that nobody watches: SourceCheck's
    /// settings and, with `sessionHelper`, whether paddock-session has Accessibility. Nil if the
    /// check couldn't run. serve warns with it; build reports it.
    func imageProblems(sessionHelper: Bool) async -> [String]? {
        // The checks are macOS's settings: a Linux image's setup is paddock's own build.
        guard !config.isLinux else { return [] }
        let output = OSAllocatedUnfairLock(initialState: [String]())
        guard (try? await runInGuest(SourceCheck.command) { line in output.withLock { $0.append(line) } }) == 0 else {
            return nil
        }
        var problems = SourceCheck.problems(in: output.withLock { $0 })
        if sessionHelper {
            do {
                try await accessibilityTree { _ in }
            } catch let error as PaddockError where error.message.contains("Accessibility") {
                problems.append("paddock-session lacks Accessibility, so axtree fails: allow it in System Settings > "
                    + "Privacy & Security > Accessibility")
            } catch {}
        }
        return problems
    }

    /// Connects to the agent, or with `port` to another listener in the guest, and runs
    /// `exchange` on a thread of its own: commands and file transfers can take a long time and
    /// would otherwise hold one of Swift concurrency's few threads.
    private func withAgent<T: Sendable>(
        port: UInt32 = GuestAgent.port, name: String = "the guest agent",
        _ exchange: @escaping @Sendable (Int32) throws -> T
    ) async throws -> T {
        guard let fd = await connectToAgent(port: port) else {
            throw PaddockError("can't reach \(name) in '\(bundle.name)'")
        }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                defer { close(fd) }
                continuation.resume(with: Result { try exchange(fd) })
            }
        }
    }

    private func askForHealth(port: UInt32) async -> String? {
        guard let fd = await connectToAgent(port: port) else { return nil }
        return await Task.detached {
            defer { close(fd) }
            return try? GuestAgent.ask(GuestAgent.Request(op: "health"), over: fd).version
        }.value
    }

    /// Opens a vsock connection to the agent, or to `port`, and returns a descriptor the caller
    /// owns, so the blocking exchange can run off the main actor. Nil if nothing in the guest is
    /// listening, or if Virtualization.framework hasn't called back within 2 s: now and then it
    /// never does.
    private func connectToAgent(port: UInt32 = GuestAgent.port) async -> Int32? {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else { return nil }
        let once = Once()
        return await withCheckedContinuation { continuation in
            device.connect(toPort: port) { result in
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
        } catch let error as VZError where error.code == .virtualMachineLimitExceeded {
            throw PaddockError("couldn't \(action): macOS runs at most two VMs at once, and two are running "
                + "already, such as another serve slot, paddock run, Tart or UTM: stop one, or use 'paddock serve --slots 1'")
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
