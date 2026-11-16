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
            """)

    @Argument(help: "VM to boot.")
    var name: String

    func validate() throws {
        try BundleName.validate(name)
    }

    /// Runs on the main thread before any run loop starts; see `Entry`.
    func run() throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        try MainActor.assumeIsolated { try VMWindow.show(bundle) }
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

    static func show(_ bundle: VMBundle) throws {
        let lock = try BundleLock(bundle: bundle)
        let configuration = try VMConfiguration.make(bundle: bundle, config: try bundle.readConfig())
        let controller = VMWindow(bundle: bundle, lock: lock, machine: VZVirtualMachine(configuration: configuration))

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()  // Never returns: the controller exits when the guest stops.
    }

    private init(bundle: VMBundle, lock: BundleLock, machine: VZVirtualMachine) {
        self.bundle = bundle
        self.lock = lock
        self.machine = machine
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

        machine.start { result in
            if case .failure(let error) = result {
                Self.exit(1, "Couldn't start '\(self.bundle.name)': \(error.localizedDescription)")
            }
        }
        print("Booted '\(bundle.name)'. Shut down from the Apple menu in the VM when you are done.")
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
