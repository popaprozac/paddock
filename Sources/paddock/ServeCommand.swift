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

    @Flag(help: "Give the slot's VMs their own userspace network (paddock-net) instead of the shared NAT.")
    var userspace = false

    func validate() throws {
        try BundleName.validate(source)
    }

    func run() async throws {
        try await WarmPool.serve(source: source, userspaceNetwork: userspace)
    }
}

/// One slot that always holds a warm VM: a clone restored from the slot's own saved state.
///
/// A saved state only restores with the machine identifier and MAC address it was saved with,
/// so the slot keeps one identity, and its VMs run one at a time.
@MainActor
final class WarmPool {
    private static let timeout: Duration = .seconds(300)
    private static let sessionTimeout: Duration = .seconds(120)

    private let home = PaddockHome.fromEnvironment()
    private let slotName: String
    private var saved: VMBundle?    // the slot's paused VM, cloned for every refill
    private var current: VMBundle?  // the clone that is booting, restoring or warm
    private var vm: HeadlessVM?
    private var warmAddress: String?  // set once the current VM's agent answers
    private var assigned = false      // the current VM has been handed out
    private var waiting: [(responder: Responder, allow: [String])] = []  // acquires that came in before a VM was warm
    private var emptyReason: String?  // why the slot holds no VM, after a refill failed
    private var server: LineServer?
    private var interrupt: (any DispatchSourceSignal)?
    private var stopping = false
    private var sessionHelper: Bool?  // whether the source has paddock-session, asked once

    static func serve(source: String, userspaceNetwork: Bool) async throws {
        let pool = WarmPool(source: source, userspaceNetwork: userspaceNetwork)
        defer { withExtendedLifetime(pool) {} }
        try await pool.run(source: source)
    }

    private let userspaceNetwork: Bool

    private init(source: String, userspaceNetwork: Bool) {
        slotName = "\(source.prefix(40))-slot1-\(Self.shortID())"
        self.userspaceNetwork = userspaceNetwork
    }

    /// Prepares the slot, fills it and serves until Ctrl-C, which exits the process.
    private func run(source name: String) async throws {
        let source = try home.bundle(named: name)
        // Listen before booting anything: a second serve fails here, and an acquire made
        // during startup waits for the first warm VM.
        server = try LineServer(path: home.socketURL.path, queue: .main) { [weak self] line, responder in
            MainActor.assumeIsolated { self?.handle(line, responder) }
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
        let vm = try HeadlessVM(bundle: bundle, config: config, userspaceNetwork: userspaceNetwork)
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
        let vm = try HeadlessVM(bundle: bundle, config: config, userspaceNetwork: userspaceNetwork)
        self.vm = vm
        try await vm.restore()
        // Attached before the guest resumes, the display catches the frames it draws then; a
        // serve that can't reach the window server just refuses screenshots later.
        try? vm.attachScreen()
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

    private func handle(_ line: String, _ responder: Responder) {
        let request = try? JSONDecoder().decode(ServeRequest.self, from: Data(line.utf8))
        switch request?.op {
        case "acquire":
            if let emptyReason {
                return responder.finish(ServeResponse(error: "slot 1 is empty: \(emptyReason)").line)
            }
            let allow = request?.allow ?? []
            if !allow.isEmpty && !userspaceNetwork {
                return responder.finish(ServeResponse(error: "--allow needs 'paddock serve --userspace'; the NAT network has no allowlist").line)
            }
            waiting.append((responder, allow))
            handOut()
        case "release":
            release(request?.vm, responder)
        case "exec":
            exec(request?.command, in: request?.vm, responder)
        case "task":
            task(request, responder)
        case "screenshot":
            screenshot(request, responder)
        case "axtree":
            accessibilityTree(of: request?.vm, responder)
        case "input":
            input(request, responder)
        default:
            responder.finish(ServeResponse(error: "unknown request: \(line.prefix(200))").line)
        }
    }

    /// Gives the warm VM to the acquire that has waited longest, once there are both, with that
    /// acquire's list in force on the userspace network. Until then the VM reaches nothing there.
    private func handOut() {
        guard !assigned, let warmAddress, let current, let vm, !waiting.isEmpty else { return }
        let (responder, allow) = waiting.removeFirst()
        if !allow.isEmpty {
            do {
                try vm.allow(allow)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
                return handOut()
            }
        }
        assigned = true
        print("Slot 1 assigned: '\(current.name)' at \(warmAddress)"
            + (allow.isEmpty ? "" : ", allowing \(allow.joined(separator: ", "))"))
        responder.finish(ServeResponse(vm: current.name, ip: warmAddress).line)
    }

    /// Runs a command in a VM this serve handed out, streaming its output to the caller.
    private func exec(_ command: String?, in name: String?, _ responder: Responder) {
        guard assigned, let vm, let current, name == current.name else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        guard let command, !command.isEmpty else {
            return responder.finish(ServeResponse(error: "exec needs a command").line)
        }
        print("Slot 1: running a command in '\(current.name)'")
        Task {
            do {
                let status = try await vm.runInGuest(command) { responder.send(ServeResponse(output: $0).line) }
                responder.finish(ServeResponse(exit: status).line)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
            }
        }
    }

    /// Runs a task on a git bundle in a VM this serve handed out; see `HeadlessVM.runTask`.
    private func task(_ request: ServeRequest?, _ responder: Responder) {
        guard assigned, let vm, let current, let request, request.vm == current.name else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        guard let command = request.command, !command.isEmpty,
              let bundle = request.bundle, bundle.hasPrefix("/"), let result = request.result, result.hasPrefix("/") else {
            return responder.finish(ServeResponse(error: "task needs a command and absolute bundle and result paths").line)
        }
        print("Slot 1: running a task in '\(current.name)'")
        Task {
            do {
                let outcome = try await vm.runTask(
                    command, bundle: URL(fileURLWithPath: bundle), result: URL(fileURLWithPath: result)
                ) { responder.send(ServeResponse(output: $0).line) }
                responder.finish(ServeResponse(exit: outcome.status, result: outcome.changed ? result : nil).line)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
            }
        }
    }

    /// Streams the accessibility tree of the focused app in a VM this serve handed out.
    private func accessibilityTree(of name: String?, _ responder: Responder) {
        guard assigned, let vm, let current, name == current.name else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        print("Slot 1: reading the accessibility tree of '\(current.name)'")
        Task {
            do {
                try await vm.accessibilityTree { responder.send(ServeResponse(output: $0).line) }
                responder.finish(ServeResponse(exit: 0).line)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
            }
        }
    }

    /// Sends a click, text, key combinations or a scroll to a VM this serve handed out, through
    /// its virtual pointer and keyboard. Answers once the input is sent, before the guest has acted
    /// on it.
    private func input(_ request: ServeRequest?, _ responder: Responder) {
        guard assigned, let vm, let current, let request, request.vm == current.name else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        Task {
            do {
                guard let action = request.input else { throw PaddockError("input needs an action") }
                switch action.kind {
                case "click":
                    guard let x = action.x, let y = action.y else { throw PaddockError("click needs x and y") }
                    guard let button = VMScreen.MouseButton(rawValue: action.button ?? "left") else {
                        throw PaddockError("click's button is left or right")
                    }
                    let count = action.count ?? 1
                    guard (1...3).contains(count) else { throw PaddockError("click's count is 1 to 3") }
                    try vm.click(x: x, y: y, button: button, count: count)
                case "type":
                    guard let text = action.text, (1...10_000).contains(text.count) else {
                        throw PaddockError("type needs text of 1 to 10,000 characters")
                    }
                    try await vm.press(KeyInput.strokes(typing: text))
                case "key":
                    guard let keys = action.keys, (1...100).contains(keys.count) else {
                        throw PaddockError("key needs 1 to 100 key combinations")
                    }
                    try await vm.press(keys.map(KeyInput.stroke))
                case "scroll":
                    guard let x = action.x, let y = action.y else { throw PaddockError("scroll needs x and y") }
                    let down = action.down ?? 0, right = action.right ?? 0
                    guard abs(down) <= 1000, abs(right) <= 1000 else { throw PaddockError("scroll is at most 1,000 lines") }
                    try vm.scroll(x: x, y: y, down: down, right: right)
                default:
                    throw PaddockError("input is click, type, key or scroll")
                }
                responder.finish(ServeResponse(exit: 0).line)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
            }
        }
    }

    /// Saves the screen of a VM this serve handed out as a PNG at the request's result path.
    private func screenshot(_ request: ServeRequest?, _ responder: Responder) {
        guard assigned, let vm, let current, let request, request.vm == current.name else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        guard let path = request.result, path.hasPrefix("/") else {
            return responder.finish(ServeResponse(error: "screenshot needs an absolute path to save the PNG at").line)
        }
        print("Slot 1: saving the screen of '\(current.name)'")
        Task {
            do {
                let image = try await vm.screenshot()
                // Encoding takes about 70 ms; keep it off the main actor.
                try await Task.detached { try FrameImage.writePNG(image, to: URL(fileURLWithPath: path)) }.value
                responder.finish(ServeResponse(result: path).line)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
            }
        }
    }

    private func release(_ name: String?, _ responder: Responder) {
        guard assigned, let current, name == current.name else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        responder.finish(ServeResponse(vm: current.name).line)
        print("Slot 1 released: '\(current.name)'; wiping it and restoring a fresh clone")
        replaceCurrent()
    }

    /// Waits for the guest agent to answer over vsock and for the guest's network, and, if the
    /// source has paddock-session, for the helper to answer and loginwindow to finish the login,
    /// so the desktop takes input; then returns the guest's address for the workload. Saving the
    /// slot's state any earlier would hand out every restore mid-login. A restored guest still holds the lease it had when its state was
    /// saved, so its lease is found at once, but its network comes back about 1.5 s after its agent.
    private func waitUntilReady(_ vm: HeadlessVM) async throws -> String {
        guard try await vm.agentVersion(within: Self.timeout) != nil else {
            throw PaddockError("'\(vm.bundle.name)' never answered over vsock; install the guest agent in the golden image")
        }
        guard try await vm.networkReady(within: Self.timeout) else {
            throw PaddockError("'\(vm.bundle.name)' had no IPv4 address and DNS server within \(DurationFormat.short(Self.timeout))")
        }
        if sessionHelper == nil {
            sessionHelper = await vm.hasSessionHelper()
        }
        if sessionHelper == true {
            guard try await vm.sessionHelperVersion(within: Self.sessionTimeout) != nil else {
                throw PaddockError("'\(vm.bundle.name)' has paddock-session installed, but it didn't answer within "
                    + "\(DurationFormat.short(Self.sessionTimeout)); turn on automatic login in the golden image")
            }
            guard try await vm.desktopReady(within: Self.sessionTimeout) else {
                throw PaddockError("loginwindow in '\(vm.bundle.name)' still covered the screen after "
                    + "\(DurationFormat.short(Self.sessionTimeout)); turn off the screen lock in the golden image")
            }
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
        for (responder, _) in waiting {
            responder.finish(ServeResponse(error: error).line)
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
