import ArgumentParser
import Foundation
import PaddockCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keep warm clones of a VM running headless, ready to hand out.",
        discussion: """
            serve keeps a warm VM in each of its slots, two by default, which is as many VMs as \
            macOS runs at once; a Linux image can have more. It clones the source into each slot \
            with the slot's own machine identifier and MAC address, boots it until its guest agent \
            answers and saves its state, all the slots at the same time. Each slot then restores a fresh clone of its \
            saved state and keeps it running; if that VM stops, the slot restores another. A state that \
            won't restore, as while the Mac's screen is locked, gets a fresh clone booted instead. \
            'paddock acquire' takes a warm VM and 'paddock release' hands it back to be wiped \
            and replaced; they reach serve through a socket in the paddock home that only you \
            can open. A slot that can't start stays empty, with the reason, and the others keep \
            serving. Press Ctrl-C, or send SIGTERM as launchd does, to stop serve and delete \
            the slots' VMs.

            With --control, serve also links this Mac to paddock-control, the control plane, and \
            reports its slots there. The first time, add --join with a token from \
            'paddock-control join-token': serve makes this Mac a key, which never leaves it, and \
            trusts only the control plane's CA that the token names. The link goes out from this \
            Mac, so it needs no open port, and serve goes on handing out VMs here while the \
            control plane is down, linking again when it's back.
            """)

    @Argument(help: "VM to clone, usually the golden image, with the guest agent installed.")
    var source: String

    @Option(help: "Warm VMs to keep: 1 or 2 of a macOS image, as many as macOS runs at once, or 1 on a Mac that also runs another VM; any number of a Linux image, as memory allows.")
    var slots = 2

    @Flag(help: "Give each VM its own userspace network (paddock-net) instead of the shared NAT.")
    var userspace = false

    @Option(help: "The control plane to link this Mac to, such as https://studio.local:7443.")
    var control: String?

    @Option(help: "A join token from 'paddock-control join-token', the first time this Mac links to --control.")
    var join: String?

    func validate() throws {
        try BundleName.validate(source)
        guard slots >= 1 else {
            throw ValidationError("--slots is at least 1")
        }
        if join != nil, control == nil {
            throw ValidationError("--join needs --control, the control plane's URL")
        }
    }

    func run() async throws {
        if slots > 2, try PaddockHome.fromEnvironment().bundle(named: source).readConfig().isMac {
            throw PaddockError("--slots is 1 or 2 for a macOS image: macOS runs at most two macOS VMs at once")
        }
        // Joined before any VM boots, so a bad token or URL fails in seconds.
        var identity: ControlIdentity?
        if let control {
            identity = try await ControlEnrollment.identity(control: try ControlEnrollment.url(control), join: join,
                                                            home: .fromEnvironment())
        }
        try await WarmPool.serve(source: source, slots: slots, userspaceNetwork: userspace, control: identity)
    }
}

/// A slot that always holds a warm VM: a clone restored from the slot's own saved state.
///
/// A saved state only restores with the machine identifier and MAC address it was saved with,
/// so the slot keeps one identity, and its VMs run one at a time.
@MainActor
final class Slot {
    let number: Int
    let name: String
    var saved: VMBundle?    // the slot's paused VM, cloned for every refill
    var current: VMBundle? { didSet { noteState() } }  // the clone that is booting, restoring or warm
    var vm: HeadlessVM?
    var warmAddress: String? { didSet { noteState() } }  // set once the current VM's agent answers
    var assigned = false { didSet { noteState() } }      // the current VM has been handed out
    var emptyReason: String? { didSet { noteState() } }  // why the slot holds no VM, after a refill failed
    private(set) var stateSince = ContinuousClock.now
    private var lastState = "preparing"

    init(number: Int, source: String) {
        self.number = number
        name = "\(source.prefix(40))-slot\(number)-\(WarmPool.shortID())"
    }

    /// What the slot reports: its state, and its VM's name while it has one.
    var report: ControlLink.SlotReport {
        ControlLink.SlotReport(number: number, emptyReason: emptyReason, assigned: assigned,
                               warm: warmAddress != nil, vm: current?.name)
    }

    private func noteState() {
        let state = report.state
        guard state != lastState else { return }
        lastState = state
        stateSince = .now
    }

    /// The VM this slot handed out as `name`, if it did.
    func handedOut(_ name: String?) -> (vm: HeadlessVM, bundle: VMBundle)? {
        guard assigned, let vm, let current, name == current.name else { return nil }
        return (vm, current)
    }
}

/// Serves warm VMs from its slots to `paddock acquire` and the requests that follow, through a
/// socket in the paddock home.
@MainActor
final class WarmPool {
    private static let timeout: Duration = .seconds(300)
    private static let sessionTimeout: Duration = .seconds(120)
    private static let maxWatchers = 2  // per VM, with paddock view --watch: each has its own encoder session

    private let home = PaddockHome.fromEnvironment()
    private let slots: [Slot]
    private var waiting: [(responder: Responder, allow: [String])] = []  // acquires that came in before a VM was warm
    private var server: LineServer?
    private var interrupts: [any DispatchSourceSignal] = []
    private var awake: (any NSObjectProtocol)?
    private var stopping = false
    private var sessionHelper: Bool?  // whether the source has paddock-session, asked once
    private var checkedSource = false  // the first slot to boot checks the source for both
    private var controlClient: ControlClient?

    static func serve(source: String, slots: Int, userspaceNetwork: Bool, control: ControlIdentity? = nil) async throws {
        let pool = WarmPool(source: source, slots: slots, userspaceNetwork: userspaceNetwork, control: control)
        defer { withExtendedLifetime(pool) {} }
        try await pool.run(source: source)
    }

    private let userspaceNetwork: Bool
    private let control: ControlIdentity?

    private let image: String
    private let sampler = UsageSampler()
    private var usage: (mac: MacUsage, vms: [String: VMUsage])?
    private var pressureWarned = 0  // the highest pressure level serve has warned about

    private init(source: String, slots: Int, userspaceNetwork: Bool, control: ControlIdentity?) {
        self.slots = (1...slots).map { Slot(number: $0, source: source) }
        self.userspaceNetwork = userspaceNetwork
        self.control = control
        image = source
    }

    /// Deletes the slot bundles of `source` that a serve stopped without cleaning up left, as
    /// Force Quit does. Only one serve listens in a paddock home and this one listens now, so none
    /// of them is a slot's; one that something else holds, such as paddock run, is left alone.
    private func deleteLeftoverSlots(of source: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.vmsDirectory.path)) ?? []
        for name in names.sorted() where BundleName.isSlotBundle(name, of: source) {
            guard let bundle = try? home.bundle(named: name), let lock = try? BundleLock(bundle: bundle) else { continue }
            do {
                try FileManager.default.removeItem(at: bundle.url)
                print("Deleted '\(name)', which a serve stopped without cleaning up left behind")
            } catch {
                print("  warning: can't delete '\(name)', left by an earlier serve: \(error.localizedDescription)")
            }
            withExtendedLifetime(lock) {}
        }
    }

    /// Samples this Mac's usage and its VMs' every 2 s, off the main actor, for `status`.
    private func sampleUsage() {
        let sampler = sampler, folder = home.vmsDirectory
        Task.detached { [weak self] in
            while let pool = self {
                let disk = await pool.freeDisk()
                await pool.keep(sampler.sample(vms: folder, diskFree: disk))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func keep(_ sample: (mac: MacUsage, vms: [String: VMUsage])) {
        usage = sample
        warnAboutPressure(sample)
    }

    /// Warns when macOS's memory pressure rises past what it already warned about: once at warn
    /// and once at critical, with what the Mac and its VMs use, measured.
    private func warnAboutPressure(_ sample: (mac: MacUsage, vms: [String: VMUsage])) {
        guard sample.mac.pressureLevel > pressureWarned else { return }
        pressureWarned = sample.mac.pressureLevel
        let vms = sample.vms.values.reduce(0) { $0 + $1.memory }
        print("  warning: memory pressure is \(sample.mac.pressure): this Mac uses "
            + "\(ByteFormat.memory(sample.mac.memoryUsed)) of its \(ByteFormat.memory(sample.mac.memoryTotal)), "
            + "\(ByteFormat.memory(vms)) of it for \(sample.vms.count == 1 ? "1 VM" : "\(sample.vms.count) VMs"); "
            + "the VMs and the Mac slow down from here, so use fewer slots or give the image less memory")
    }

    /// This Mac and its slots as `paddock top` shows them, from the last sample.
    private func status() -> MacStatus {
        let now = ContinuousClock.now
        return MacStatus(name: ControlClient.computerName, image: image, online: true, usage: usage?.mac,
                         slots: slots.map { slot in
                             var report = slot.report
                             report.age = Int((now - slot.stateSince).components.seconds)
                             report.usage = slot.current.flatMap { usage?.vms[$0.name] }
                             return report
                         })
    }

    /// Prepares the slots at the same time, fills them and serves until Ctrl-C or SIGTERM, which
    /// exit the process. Fails only if no slot could start.
    private func run(source name: String) async throws {
        let source = try home.bundle(named: name)
        warnAboutMemory(source)
        // Listen before booting anything: a second serve fails here, and an acquire made
        // during startup waits for the first warm VM.
        server = try LineServer(path: home.socketURL.path, queue: .main) { [weak self] line, responder in
            MainActor.assumeIsolated { self?.handle(line, responder) }
        }
        // SIGTERM is how launchd stops a job, and how shutdown and logout stop everything.
        interrupts = [SIGINT, SIGTERM].map { number in onInterrupt(number) { [weak self] in self?.shutDown() } }
        // Neither serve nor macOS's VM service otherwise keeps a host with a sleep timer from
        // idle sleep, which would stop every slot. Lid close and Sleep from the menu still work.
        awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                      reason: "paddock serve keeps its slots' VMs running")
        deleteLeftoverSlots(of: name)
        sampleUsage()
        if let control {
            controlClient = ControlClient(identity: control, image: name,
                                          slots: { [weak self] in self?.slotReports() ?? [] },
                                          diskFree: { [weak self] in self?.freeDisk() },
                                          status: { [weak self] in self?.status() },
                                          onRequest: { [weak self] line, responder in self?.handle(line, responder) })
            controlClient?.start()
        }
        await withTaskGroup(of: Void.self) { group in
            for slot in slots {
                group.addTask { await self.prepare(slot, from: source) }
            }
        }
        let reasons = slots.compactMap { slot in slot.emptyReason.map { "slot \(slot.number): \($0)" } }
        if reasons.count == slots.count {
            server?.stop()
            throw PaddockError(reasons.joined(separator: "; "))
        }
        for slot in slots where slot.emptyReason != nil {
            Task { await keepFilling(slot) }
        }
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Boots and saves the slot's clone of `source`, then fills the slot. A slot that can't start
    /// is empty with the reason, and `run` keeps trying to fill it while the others serve on.
    private func prepare(_ slot: Slot, from source: VMBundle) async {
        do {
            print("Preparing slot \(slot.number) from '\(source.name)': boot a clone once and save its state")
            try await saveBootedClone(of: source, in: slot)
            try await refill(slot)
        } catch {
            await discardCurrent(of: slot)
            removeSaved(of: slot)
            slot.emptyReason = error.localizedDescription
            print("Slot \(slot.number) is empty: \(error.localizedDescription)")
            if slots.allSatisfy({ $0.emptyReason != nil }) {
                answerWaiting(with: "no slot could start: \(error.localizedDescription)")
            }
        }
    }

    /// The slots as the control plane sees them.
    private func slotReports() -> [ControlLink.SlotReport] {
        slots.map(\.report)
    }

    /// Free space on the paddock home's volume, where clones go.
    private func freeDisk() -> UInt64? {
        let values = try? home.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    /// Warns when the slots' VMs together would leave this Mac little memory of its own.
    private func warnAboutMemory(_ source: VMBundle) {
        guard let config = try? source.readConfig() else { return }
        let memory = config.memorySize
        let total = ProcessInfo.processInfo.physicalMemory
        let wanted = UInt64(slots.count)
            * VMSizing.hostMemory(for: memory, linux: !config.isMac, desktop: config.hasScreen)
        // shortcut: 10 GB for macOS and its apps, from the Studio, whose pressure reached warn with two
        // 8 GB VMs on 36 GB; tune once hosts run other workloads.
        guard wanted + (10 << 30) > total else { return }
        print("  warning: \(slots.count) VMs of \(memory >> 30) GB take about \(ByteFormat.memory(wanted)) of this Mac's "
            + "\(ByteFormat.memory(total)), since a VM costs its Mac more than its own memory; use fewer slots or give "
            + "'\(source.name)' less memory if the Mac slows down")
    }

    /// Boots a clone of `source` with the slot's fresh identity until its agent answers, then
    /// saves its state.
    private func saveBootedClone(of source: VMBundle, in slot: Slot) async throws {
        let started = ContinuousClock.now
        let bundle = try home.bundle(named: "\(slot.name)-saved")
        slot.current = bundle
        let config = try VMClone.clone(source, to: bundle)
        let vm = try HeadlessVM(bundle: bundle, config: config, userspaceNetwork: userspaceNetwork)
        slot.vm = vm
        try await vm.start()
        let ip = try await waitUntilReady(vm)
        let booted = ContinuousClock.now - started
        if !checkedSource {
            checkedSource = true
            await warnAboutSource(vm, source)
        }
        let saveStarted = ContinuousClock.now
        try await vm.pauseAndSave()
        await vm.stop()
        slot.vm = nil
        slot.current = nil
        slot.saved = bundle
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.savedStateURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        print("  slot \(slot.number) booted at \(ip) in \(DurationFormat.short(booted)), "
            + "saved \(ByteFormat.gigabytes(size)) of state in \(DurationFormat.short(ContinuousClock.now - saveStarted))")
    }

    /// Prints what in `source` breaks VMs that nobody watches, found in its freshly booted clone:
    /// see SourceCheck. serve carries on, since the VMs still work until the setting bites.
    private func warnAboutSource(_ vm: HeadlessVM, _ source: VMBundle) async {
        guard let problems = await vm.imageProblems(sessionHelper: sessionHelper == true) else {
            return print("  warning: couldn't check '\(source.name)' for settings that break unattended VMs")
        }
        guard !problems.isEmpty else { return }
        print("  warning: '\(source.name)' isn't set up for VMs that nobody watches; change it in the golden image:")
        for problem in problems {
            print("    - \(problem)")
        }
    }

    /// Restores a fresh clone of the slot's saved state and waits until its agent answers. When
    /// the state won't restore, as while the Mac's screen is locked, which keeps its key from
    /// paddock, the slot boots a fresh clone of the source instead, and tries its state again next time.
    private func refill(_ slot: Slot) async throws {
        guard let saved = slot.saved else { return }
        let started = ContinuousClock.now
        var how = "restored"
        let vm: HeadlessVM
        do {
            vm = try await startClone(of: saved, in: slot, restoring: true)
        } catch {
            print("Slot \(slot.number) boots a fresh clone of '\(image)' instead: \(error.localizedDescription)")
            await discardCurrent(of: slot)
            vm = try await startClone(of: try home.bundle(named: image), in: slot, restoring: false)
            how = "booted"
        }
        let bundle = vm.bundle
        let ip = try await waitUntilReady(vm)
        if !vm.config.isMac {
            // A restored guest runs at the time its state was saved, and a booted Linux one starts at
            // 1970 until its network time arrives; macOS corrects that itself, Linux and Windows don't.
            do { try await vm.setGuestClock() } catch {
                print("  warning: couldn't set the clock of '\(bundle.name)': \(error.localizedDescription)")
            }
        }
        if let failure = vm.failure { throw failure }  // it stopped while its clock was set
        vm.onFailure = { [weak self, weak vm] error in
            // A VM the slot already threw away is no longer its VM, and must not refill it twice.
            guard let self, let vm, slot.vm === vm else { return }
            print("Slot \(slot.number): \(error.message); restoring a fresh clone")
            self.replaceCurrent(of: slot)
        }
        slot.warmAddress = ip
        slot.emptyReason = nil
        print("Slot \(slot.number) warm: '\(bundle.name)' at \(ip), \(how) in \(DurationFormat.short(ContinuousClock.now - started))")
        handOut()
    }

    /// Clones `source` into the slot and starts the clone: from the saved state it keeps when
    /// `restoring`, otherwise with a cold boot under a fresh identity.
    private func startClone(of source: VMBundle, in slot: Slot, restoring: Bool) async throws -> HeadlessVM {
        let bundle = try home.bundle(named: "\(slot.name)-\(Self.shortID())")
        slot.current = bundle
        let config = try VMClone.clone(source, to: bundle, keepingSavedState: restoring)
        let vm = try HeadlessVM(bundle: bundle, config: config, userspaceNetwork: userspaceNetwork)
        slot.vm = vm
        // Attached before the guest runs, the display catches the frames it draws then; a serve
        // that can't reach the window server just refuses screenshots later.
        if restoring {
            try await vm.restore()
            try? vm.attachScreen()
            try await vm.resume()
        } else {
            try? vm.attachScreen()
            try await vm.start()
        }
        return vm
    }

    private func handle(_ line: String, _ responder: Responder) {
        let request = try? JSONDecoder().decode(ServeRequest.self, from: Data(line.utf8))
        switch request?.op {
        case "acquire":
            let reasons = slots.compactMap { slot in slot.emptyReason.map { "slot \(slot.number) is empty: \($0)" } }
            if reasons.count == slots.count {
                return responder.finish(ServeResponse(error: reasons.joined(separator: "; ")).line)
            }
            let allow = request?.allow ?? []
            if !allow.isEmpty && !userspaceNetwork {
                return responder.finish(ServeResponse(error: "--allow needs 'paddock serve --userspace'; the NAT network has no allowlist").line)
            }
            if request?.wait == false && !(waiting.isEmpty && freeSlot != nil) {
                return responder.finish(ServeResponse(error: "no warm VM is free on this Mac", busy: true).line)
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
        case "status":
            responder.finish(ServeResponse(status: status()).line)
        case "show":
            show(request?.vm, responder)
        case "hide":
            hide(request?.vm, responder)
        case "view":
            view(request?.vm, watch: request?.watch == true, responder)
        default:
            responder.finish(ServeResponse(error: "unknown request: \(line.prefix(200))").line)
        }
    }

    /// A slot with a warm VM nobody has been given.
    private var freeSlot: Slot? {
        slots.first { !$0.assigned && $0.warmAddress != nil && $0.vm != nil }
    }

    /// Gives a warm VM to the acquire that has waited longest, once there are both, with that
    /// acquire's list in force on the userspace network. Until then the VM reaches nothing there.
    private func handOut() {
        guard !waiting.isEmpty, let slot = freeSlot,
              let warmAddress = slot.warmAddress, let current = slot.current, let vm = slot.vm else { return }
        let (responder, allow) = waiting.removeFirst()
        // An acquire stopped while it waited gets nothing: the VM stays warm for the next.
        if responder.clientHungUp {
            return handOut()
        }
        if !allow.isEmpty {
            do {
                try vm.allow(allow)
            } catch {
                responder.finish(ServeResponse(error: error.localizedDescription).line)
                return handOut()
            }
        }
        slot.assigned = true
        print("Slot \(slot.number) assigned: '\(current.name)' at \(warmAddress)"
            + (allow.isEmpty ? "" : ", allowing \(allow.joined(separator: ", "))"))
        responder.finish(ServeResponse(vm: current.name, ip: warmAddress).line)
    }

    /// Runs a command in a VM this serve handed out, streaming its output to the caller.
    private func exec(_ command: String?, in name: String?, _ responder: Responder) {
        guard let (slot, vm, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        guard let command, !command.isEmpty else {
            return responder.finish(ServeResponse(error: "exec needs a command").line)
        }
        print("Slot \(slot.number): running a command in '\(current.name)'")
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
        guard let request, let (slot, vm, current) = handedOut(request.vm) else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        guard let command = request.command, !command.isEmpty,
              let bundle = request.bundle, bundle.hasPrefix("/"), let result = request.result, result.hasPrefix("/") else {
            return responder.finish(ServeResponse(error: "task needs a command and absolute bundle and result paths").line)
        }
        print("Slot \(slot.number): running a task in '\(current.name)'")
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
        guard let (slot, vm, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        print("Slot \(slot.number): reading the accessibility tree of '\(current.name)'")
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
        guard let request, let (_, vm, current) = handedOut(request.vm) else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        // A person and an agent sharing one pointer and keyboard would undo each other.
        guard !vm.isShown else {
            return responder.finish(ServeResponse(error: "a person has '\(current.name)' on this Mac's screen, so input "
                + "waits until they hand it back, with paddock hide or by closing its window").line)
        }
        guard !vm.isViewed else {
            return responder.finish(ServeResponse(error: "a person is driving '\(current.name)' with paddock view, so input "
                + "waits until they close the view").line)
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
                    // A range, not abs(): abs of Int.min traps, which would end serve and every VM in it.
                    guard (-1000...1000).contains(down), (-1000...1000).contains(right) else {
                        throw PaddockError("scroll is at most 1,000 lines")
                    }
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
        guard let request, let (slot, vm, current) = handedOut(request.vm) else {
            return responder.finish(ServeResponse(error: "'\(request?.vm ?? "")' is not a VM this serve has handed out").line)
        }
        guard let path = request.result, path.hasPrefix("/") else {
            return responder.finish(ServeResponse(error: "screenshot needs an absolute path to save the PNG at").line)
        }
        print("Slot \(slot.number): saving the screen of '\(current.name)'")
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
        guard let (slot, _, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        responder.finish(ServeResponse(vm: current.name).line)
        print("Slot \(slot.number) released: '\(current.name)'; wiping it and restoring a fresh clone")
        replaceCurrent(of: slot)
    }

    /// The slot that handed out the VM named `name`, with that VM, if one did.
    /// Puts a VM this serve handed out on this Mac's screen for a person. Screenshots, the
    /// accessibility tree and commands go on; input from agents and the CLI waits for the hand-back.
    private func show(_ name: String?, _ responder: Responder) {
        guard let (slot, vm, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        guard !vm.isViewed else {
            return responder.finish(ServeResponse(error: "a person is driving '\(current.name)' with paddock view; it goes on "
                + "screen here once they close the view").line)
        }
        let wasShown = vm.isShown
        do {
            try vm.show(title: "\(current.name): handed to you; close this window to hand it back") { [weak self] in
                self?.handBack(slot, vm, current)
            }
        } catch {
            return responder.finish(ServeResponse(error: error.localizedDescription).line)
        }
        if !wasShown {
            print("Slot \(slot.number): '\(current.name)' is on screen; input from agents waits until it's handed back")
        }
        responder.finish(ServeResponse(vm: current.name).line)
    }

    private func hide(_ name: String?, _ responder: Responder) {
        guard let (slot, vm, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        handBack(slot, vm, current)
        responder.finish(ServeResponse(vm: current.name).line)
    }

    /// Streams a VM this serve handed out to a person's viewer, here or on another Mac through the
    /// pool, and takes their pointer and keyboard back (see ViewSession). Screenshots, the
    /// accessibility tree and commands go on; input from agents and the CLI waits for the view to close.
    /// A watch takes no input, so agents keep driving, and goes alongside a show or a view.
    private func view(_ name: String?, watch: Bool, _ responder: Responder) {
        guard let (slot, vm, current) = handedOut(name) else {
            return responder.finish(ServeResponse(error: "'\(name ?? "")' is not a VM this serve has handed out").line)
        }
        if watch {
            guard vm.watchers < Self.maxWatchers else {
                return responder.finish(ServeResponse(error: "\(Self.maxWatchers) people are already watching '\(current.name)'").line)
            }
        } else {
            guard !vm.isShown else {
                return responder.finish(ServeResponse(error: "a person has '\(current.name)' on this Mac's screen; hand it "
                    + "back with paddock hide first").line)
            }
            guard !vm.isViewed else {
                return responder.finish(ServeResponse(error: "someone is already viewing '\(current.name)'").line)
            }
        }
        let screen: VMScreen
        do {
            screen = try vm.viewScreen()
        } catch {
            return responder.finish(ServeResponse(error: error.localizedDescription).line)
        }
        if watch {
            vm.watchers += 1
            print("Slot \(slot.number): someone is watching '\(current.name)'; input from agents goes on")
        } else {
            vm.isViewed = true
            print("Slot \(slot.number): '\(current.name)' is being viewed; input from agents waits until the view closes")
        }
        let session = ViewSession(screen: screen, responder: responder, watch: watch, stillHandedOut: { [weak self, weak vm] in
            guard let self, let vm else { return false }
            return self.handedOut(current.name)?.1 === vm
        }, onEnd: { [weak vm] reason in
            if watch {
                vm?.watchers -= 1
                print("Slot \(slot.number): a watch of '\(current.name)' closed (\(reason))")
            } else {
                vm?.isViewed = false
                print("Slot \(slot.number): the view of '\(current.name)' closed (\(reason)); input from agents goes through")
            }
        })
        session.start()
    }

    private func handBack(_ slot: Slot, _ vm: HeadlessVM, _ current: VMBundle) {
        guard vm.isShown else { return }
        vm.hide()
        print("Slot \(slot.number): '\(current.name)' is off screen again; input from agents goes through")
    }

    private func handedOut(_ name: String?) -> (Slot, HeadlessVM, VMBundle)? {
        for slot in slots {
            if let (vm, bundle) = slot.handedOut(name) { return (slot, vm, bundle) }
        }
        return nil
    }

    /// Waits for the guest agent to answer over vsock and for the guest's network, and, if the
    /// source has paddock-session, for the helper to answer and loginwindow to finish the login,
    /// so the desktop takes input, or for a desktop Linux VM's agent to say its desktop is up; then returns the guest's address for the workload. Saving the
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
                    + "\(DurationFormat.short(Self.sessionTimeout)); turn on automatic login in the golden image, and boot it once to finish Setup Assistant")
            }
            guard try await vm.desktopReady(within: Self.sessionTimeout) else {
                throw PaddockError("loginwindow in '\(vm.bundle.name)' still covered the screen after "
                    + "\(DurationFormat.short(Self.sessionTimeout)); turn off the screen lock in the golden image")
            }
        }
        if !vm.config.isMac, vm.config.hasScreen {
            guard try await vm.desktopReady(within: Self.sessionTimeout) else {
                throw PaddockError("'\(vm.bundle.name)' showed no desktop within \(DurationFormat.short(Self.sessionTimeout)); "
                    + "the golden image must log its account in to a desktop by itself, on a kernel that drives the screen "
                    + "and USB input, and not lock it")
            }
        }
        guard let ip = try await vm.leasedAddress(within: Self.timeout) else {
            throw PaddockError("'\(vm.bundle.name)' got no DHCP lease within \(DurationFormat.short(Self.timeout))")
        }
        return ip
    }

    /// Throws the slot's current VM away, with everything its user did, and restores a fresh clone.
    private func replaceCurrent(of slot: Slot) {
        slot.warmAddress = nil
        slot.assigned = false
        Task {
            await discardCurrent(of: slot)
            await keepFilling(slot)
        }
    }

    /// Fills the slot, booting and saving a clone first if it has no saved state. While that
    /// fails, it tries again after a wait that doubles from 5 s up to 5 minutes, since most
    /// failures pass, as a full disk, a Mac that slept or a slow boot do. An empty slot waits first.
    private func keepFilling(_ slot: Slot) async {
        var wait = Duration.seconds(5)
        while true {
            if slot.emptyReason != nil {
                print("Slot \(slot.number) tries again in \(DurationFormat.short(wait))")
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, .seconds(300))
            }
            guard !stopping else { return }
            do {
                if slot.saved == nil {
                    print("Slot \(slot.number): boot a clone of '\(image)' and save its state")
                    try await saveBootedClone(of: try home.bundle(named: image), in: slot)
                }
                try await refill(slot)
                return
            } catch {
                await discardCurrent(of: slot)
                slot.emptyReason = error.localizedDescription
                print("Slot \(slot.number) is empty: \(error.localizedDescription)")
                // Waiting acquires wait on for another slot, unless every slot is empty.
                if slots.allSatisfy({ $0.emptyReason != nil }) {
                    answerWaiting(with: "slot \(slot.number) is empty: \(error.localizedDescription)")
                }
            }
        }
    }

    private func answerWaiting(with error: String) {
        for (responder, _) in waiting {
            responder.finish(ServeResponse(error: error).line)
        }
        waiting.removeAll()
    }

    /// Forces the slot's current VM off and deletes its clone.
    private func discardCurrent(of slot: Slot) async {
        await slot.vm?.stop()
        slot.vm = nil
        if let current = slot.current {
            try? FileManager.default.removeItem(at: current.url)
        }
        slot.current = nil
    }

    private func removeSaved(of slot: Slot) {
        if let saved = slot.saved {
            try? FileManager.default.removeItem(at: saved.url)
        }
        slot.saved = nil
    }

    private func shutDown() {
        guard !stopping else { Darwin.exit(130) }
        stopping = true
        print("\nStopping; deleting \(slots.count == 1 ? "slot 1's" : "the slots'") VMs. Press Ctrl-C again to quit now.")
        server?.stop()
        controlClient?.stop()
        answerWaiting(with: "paddock serve stopped")
        Task {
            for slot in slots {
                await discardCurrent(of: slot)
                removeSaved(of: slot)
            }
            Darwin.exit(0)
        }
    }

    static func shortID() -> String {
        UUID().uuidString.prefix(6).lowercased()
    }
}
