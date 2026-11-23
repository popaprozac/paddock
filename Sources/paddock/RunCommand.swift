import AppKit
import ArgumentParser
import PaddockCore
import Virtualization

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a VM in a window, for example to finish Setup Assistant on the golden image.",
        discussion: """
            Shut down from the Apple menu inside the VM when you are done. Closing the window or \
            pressing Ctrl-C asks the guest to shut down; doing it a second time forces the VM off.

            --share mounts a host folder read-only in the guest at /Volumes/My Shared Files, \
            for example the 'guest' folder build.sh stages with the guest agent's installer.

            --provision creates the user account on the VM's first boot after 'paddock install', \
            in place of Setup Assistant, with automatic login and Remote Login on. It asks for the \
            account's password on the terminal and keeps it nowhere. It needs macOS 27 on this \
            Mac and in the VM, and macOS ignores it on any later boot.

            --recovery starts the VM in macOS Recovery instead, where Terminal (in the Utilities \
            menu) can run csrutil.

            A Linux VM with a desktop opens in a window too, at its image's screen size, and shuts \
            down from its desktop. A Linux VM without one has no screen, so run connects this \
            terminal to its console instead, logged in as its account. Ctrl-] asks the guest to \
            shut down, and a second Ctrl-] forces it off; so does shutting down in the guest. For a \
            Linux VM, --share is a folder to mount in the guest with: \
            sudo mount -t virtiofs paddock-share /mnt/share
            """)

    @Argument(help: "VM to boot.")
    var name: String

    @Option(help: "Host folder to mount read-only in the guest.")
    var share: String?

    @Option(help: "Short name of the account to create on the VM's first boot.")
    var provision: String?

    @Option(help: "Full name of that account; defaults to its short name.")
    var fullName: String?

    @Flag(help: "Start in macOS Recovery.")
    var recovery = false

    func validate() throws {
        try BundleName.validate(name)
        if let share {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: share, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("--share needs an existing folder: \(share)")
            }
        }
        if fullName != nil && provision == nil {
            throw ValidationError("--full-name goes with --provision")
        }
        if recovery && provision != nil {
            throw ValidationError("--provision needs a normal first boot, not --recovery")
        }
        if let provision {
            do { try Provisioning.validate(account: provision) } catch let error as PaddockError { throw ValidationError(error.message) }
        }
    }

    /// Runs on the main thread before any run loop starts; see `Entry`.
    func run() throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let sharing = share.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let config = try bundle.readConfig()
        if !config.isMac {
            guard provision == nil, !recovery else {
                throw PaddockError("--provision and --recovery are for macOS VMs, and '\(name)' is a \(config.isWindows ? "Windows" : "Linux") VM")
            }
            guard config.hasScreen else {
                try MainActor.assumeIsolated { try VMConsole.run(bundle, sharing: sharing) }
            }
            try MainActor.assumeIsolated { try VMWindow.show(bundle, sharing: sharing) }
        }
        var provisioning: NSObject?
        if let provision {
            guard #available(macOS 27, *) else { throw PaddockError("--provision needs macOS 27 on this Mac") }
            // An older guest ignores provisioning and shows Setup Assistant in full, as on macOS 26.6.
            if let version = try bundle.readConfig().os?.version, let major = GuestSupport.major(version),
               major < GuestSupport.provisioning {
                throw PaddockError("'\(name)' has macOS \(version), and only macOS \(GuestSupport.provisioning) and later "
                    + "guests take provisioning; run it without --provision and go through Setup Assistant")
            }
            let password = try Provisioning.readPassword(for: provision)
            provisioning = try Provisioning.options(account: provision, fullName: fullName ?? provision, password: password)
        }
        try MainActor.assumeIsolated { [provisioning] in
            try VMWindow.show(bundle, sharing: sharing, provisioning: provisioning, recovery: recovery)
        }
    }
}

/// One VM in one window. The process exits when the guest stops.
@MainActor
final class VMWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let bundle: VMBundle
    private let lock: BundleLock
    private let machine: VZVirtualMachine
    private var window: NSWindow?
    private var interrupt: (any DispatchSourceSignal)?
    private var shutdownRequested = false

    private let mac: Bool  // a macOS VM; Linux and Windows VMs take none of macOS's start options
    private let provisioning: NSObject?  // VZMacGuestProvisioningOptions, which needs macOS 27
    private let recovery: Bool

    static func show(_ bundle: VMBundle, sharing: URL?, provisioning: NSObject? = nil, recovery: Bool = false) throws -> Never {
        let lock = try BundleLock(bundle: bundle)
        let config = try bundle.readConfig()
        let configuration = try VMConfiguration.make(bundle: bundle, config: config, sharing: sharing)
        let controller = VMWindow(bundle: bundle, lock: lock, machine: VZVirtualMachine(configuration: configuration),
                                  mac: config.isMac, provisioning: provisioning, recovery: recovery)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()  // Never returns: the controller exits when the guest stops.
        fatalError("NSApplication.run returned")
    }

    private init(bundle: VMBundle, lock: BundleLock, machine: VZVirtualMachine, mac: Bool, provisioning: NSObject?,
                 recovery: Bool) {
        self.bundle = bundle
        self.lock = lock
        self.machine = machine
        self.mac = mac
        self.provisioning = provisioning
        self.recovery = recovery
        super.init()
        machine.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        // A Linux desktop would keep a size the window gave it in the golden image, and Windows'
        // display driver refuses sizes above the framebuffer it sized at boot (the VM's display
        // size), so both stay at the image's size and the window scales it.
        view.automaticallyReconfiguresDisplay = mac

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "paddock: \(bundle.name)"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate()

        interrupt = onInterrupt { [weak self] in self?.requestShutdown() }

        if !mac {
            machine.start { result in
                if case let .failure(error) = result {
                    Self.exit(1, "Couldn't start '\(self.bundle.name)': \(error.localizedDescription)")
                }
            }
            print("Booted '\(bundle.name)'. Shut down from its desktop when you are done.")
            return
        }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        if #available(macOS 27, *), let provisioning = provisioning as? VZMacGuestProvisioningOptions {
            do {
                try options.setGuestProvisioning(provisioning)
            } catch {
                Self.exit(1, "Couldn't provision '\(bundle.name)': \(error.localizedDescription)")
            }
        }
        machine.start(options: options) { error in
            if let error {
                Self.exit(1, "Couldn't start '\(self.bundle.name)': \(error.localizedDescription)")
            }
        }
        print("Booted '\(bundle.name)'" + (provisioning == nil ? "" : ", creating its account")
            + (recovery ? " in macOS Recovery" : "")
            + ". Shut down from the Apple menu in the VM when you are done.")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestShutdown()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestShutdown()
        return .terminateCancel
    }

    /// First call asks the guest to shut down cleanly; a second call forces the VM off.
    private func requestShutdown() {
        if !shutdownRequested, machine.canRequestStop, (try? machine.requestStop()) != nil {
            shutdownRequested = true
            print("Asked the guest to shut down. Close the window or press Ctrl-C again to force it off.")
            return
        }
        print("Forcing '\(bundle.name)' off.")
        machine.stop { _ in Self.exit(0) }
    }

    private static func exit(_ status: Int32, _ message: String? = nil) -> Never {
        if let message { print(message) }
        Darwin.exit(status)
    }
}

extension VMWindow: @preconcurrency VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Self.exit(0, "'\(bundle.name)' shut down.")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Self.exit(1, "'\(bundle.name)' stopped with an error: \(error.localizedDescription)")
    }
}

/// A Linux VM on this terminal: its console in place of a window, since a Linux VM has no screen.
/// The terminal is raw while the VM runs, so Ctrl-C and the like go to the guest; Ctrl-] is
/// paddock's. The process exits when the guest stops.
@MainActor
final class VMConsole: NSObject {
    nonisolated private static let detach: UInt8 = 0x1D  // Ctrl-], read on the stdin thread
    private static var terminal: termios?  // as it was, put back on exit

    private let bundle: VMBundle
    private let lock: BundleLock
    private let machine: VZVirtualMachine
    private let keys: FileHandle  // what the guest reads as typed on its console
    private var interrupts: [any DispatchSourceSignal] = []
    private var shutdownRequested = false

    static func run(_ bundle: VMBundle, sharing: URL?) throws -> Never {
        let lock = try BundleLock(bundle: bundle)
        let input = Pipe()
        let attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: input.fileHandleForReading,
                                                          fileHandleForWriting: .standardOutput)
        let configuration = try VMConfiguration.make(bundle: bundle, config: try bundle.readConfig(), sharing: sharing,
                                                     console: attachment)
        let console = VMConsole(bundle: bundle, lock: lock, machine: VZVirtualMachine(configuration: configuration),
                                keys: input.fileHandleForWriting)
        console.start(sharing: sharing != nil)
        // The main thread's run loop serves the main queue, where Virtualization calls back and
        // signals and Ctrl-] arrive. With no source of its own it returns at once, serving nothing,
        // so it gets a port that never fires.
        RunLoop.main.add(NSMachPort(), forMode: .default)
        while true {
            RunLoop.main.run()
        }
    }

    private init(bundle: VMBundle, lock: BundleLock, machine: VZVirtualMachine, keys: FileHandle) {
        self.bundle = bundle
        self.lock = lock
        self.machine = machine
        self.keys = keys
        super.init()
        machine.delegate = self
    }

    private func start(sharing: Bool) {
        print("Booting '\(bundle.name)' on this terminal. Ctrl-] asks it to shut down; a second Ctrl-] forces it off.")
        if sharing {
            print("Mount the shared folder in the guest with: sudo mount -t virtiofs paddock-share /mnt/share")
        }
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 {
            // A serial console can't tell the guest how big the window is.
            print("For this window's size in the guest: stty rows \(size.ws_row) cols \(size.ws_col)")
        }
        Self.makeTerminalRaw()
        interrupts = [SIGINT, SIGTERM, SIGHUP].map { number in onInterrupt(number) { [weak self] in self?.requestShutdown() } }
        let keys = keys
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0, errno == EAGAIN || errno == EINTR {
                    // Virtualization makes stdout non-blocking, and on a terminal stdin shares its
                    // open file, so wait until there's something to read.
                    var ready = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    _ = poll(&ready, 1, -1)
                    continue
                }
                guard count > 0 else { break }
                var typed = buffer[..<count]
                while let index = typed.firstIndex(of: Self.detach) {
                    try? keys.write(contentsOf: Data(typed[..<index]))
                    typed = typed[(index + 1)...]
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestShutdown() } }
                }
                try? keys.write(contentsOf: Data(typed))
            }
        }
        machine.start { [bundle] result in
            if case let .failure(error) = result {
                Self.exit(1, "Couldn't start '\(bundle.name)': \(error.localizedDescription)")
            }
        }
    }

    /// First call asks the guest to shut down cleanly; a second call forces the VM off.
    private func requestShutdown() {
        if !shutdownRequested, machine.canRequestStop, (try? machine.requestStop()) != nil {
            shutdownRequested = true
            Self.say("asked the guest to shut down; Ctrl-] again forces it off")
            return
        }
        // Forced off, the image skips the shutdown that empties its machine-id.
        Self.say("forcing '\(bundle.name)' off; it keeps this boot's machine-id until it next shuts down cleanly")
        machine.stop { _ in Self.exit(0) }
    }

    private static func makeTerminalRaw() {
        var settings = termios()
        guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &settings) == 0 else { return }
        terminal = settings
        cfmakeraw(&settings)
        tcsetattr(STDIN_FILENO, TCSANOW, &settings)
    }

    /// A line of paddock's own while the terminal is raw, which turns no newline into a return.
    private static func say(_ message: String) {
        FileHandle.standardError.write(Data("\r\npaddock: \(message)\r\n".utf8))
    }

    fileprivate static func exit(_ status: Int32, _ message: String? = nil) -> Never {
        if var settings = terminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &settings)
        }
        if let message { print("\n" + message) }
        Darwin.exit(status)
    }
}

extension VMConsole: @preconcurrency VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Self.exit(0, "'\(bundle.name)' shut down.")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Self.exit(1, "'\(bundle.name)' stopped with an error: \(error.localizedDescription)")
    }
}
