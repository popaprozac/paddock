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
            """)

    @Argument(help: "VM to boot.")
    var name: String

    @Option(help: "Host folder to mount read-only in the guest.")
    var share: String?

    @Option(help: "Short name of the account to create on the VM's first boot.")
    var provision: String?

    @Option(help: "Full name of that account; defaults to its short name.")
    var fullName: String?

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
        if let provision {
            do { try Provisioning.validate(account: provision) } catch let error as PaddockError { throw ValidationError(error.message) }
        }
    }

    /// Runs on the main thread before any run loop starts; see `Entry`.
    func run() throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let sharing = share.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        var provisioning: NSObject?
        if let provision {
            guard #available(macOS 27, *) else { throw PaddockError("--provision needs macOS 27 on this Mac") }
            let password = try Provisioning.readPassword(for: provision)
            provisioning = try Provisioning.options(account: provision, fullName: fullName ?? provision, password: password)
        }
        try MainActor.assumeIsolated { [provisioning] in try VMWindow.show(bundle, sharing: sharing, provisioning: provisioning) }
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

    private let provisioning: NSObject?  // VZMacGuestProvisioningOptions, which needs macOS 27

    static func show(_ bundle: VMBundle, sharing: URL?, provisioning: NSObject? = nil) throws {
        let lock = try BundleLock(bundle: bundle)
        let configuration = try VMConfiguration.make(bundle: bundle, config: try bundle.readConfig(), sharing: sharing)
        let controller = VMWindow(bundle: bundle, lock: lock, machine: VZVirtualMachine(configuration: configuration),
                                  provisioning: provisioning)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()  // Never returns: the controller exits when the guest stops.
    }

    private init(bundle: VMBundle, lock: BundleLock, machine: VZVirtualMachine, provisioning: NSObject?) {
        self.bundle = bundle
        self.lock = lock
        self.machine = machine
        self.provisioning = provisioning
        super.init()
        machine.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true

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

        let options = VZMacOSVirtualMachineStartOptions()
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
