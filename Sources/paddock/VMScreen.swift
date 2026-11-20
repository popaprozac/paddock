import AppKit
import Carbon.HIToolbox
import IOSurface
import PaddockCore
import Virtualization

/// A VM's screen, read and driven on the host. A VZVirtualMachineView sits in a borderless window
/// placed off every display, and the framebuffer view inside it holds the latest frame as an
/// IOSurface, which paddock copies. Mouse and keyboard events sent to the view reach the guest as
/// its virtual pointer and keyboard. Neither takes a permission, in the host or the guest, or opens
/// a listener, but this process must reach the window server, so paddock must run in a logged-in
/// session.
/// shortcut: Apple doesn't document that the framebuffer view keeps its frame as an IOSurface in
/// its layer; if a macOS release changes that, `capture` throws instead of returning a frame.
@MainActor
final class VMScreen: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let view: VZVirtualMachineView
    private let size: NSSize           // the guest's pixels, one view point each while off screen
    private var handBack: (() -> Void)?  // set while a person has the window on screen
    private static var shown: [VMScreen] = []  // on screen now: paddock shows in the Dock while any is
    private static var pump: Timer?            // hands AppKit's events to windows while any is on screen
    private static let dock = Dock()

    /// Where the window waits: off every display. The view only receives frames once it is in a
    /// window, visible or not.
    private static let offScreen = NSPoint(x: -20_000, y: -20_000)

    init(machine: VZVirtualMachine, display: VMConfig.Display) throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw PaddockError("this paddock can't reach the window server; start it from a logged-in session to read VM screens")
        }
        _ = NSApplication.shared  // AppKit needs it before any window; without a bundle it shows no Dock icon
        size = NSSize(width: display.widthInPixels, height: display.heightInPixels)
        view = VZVirtualMachineView(frame: NSRect(origin: .zero, size: size))
        view.virtualMachine = machine
        window = NSWindow(contentRect: NSRect(origin: Self.offScreen, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = view
        window.orderFrontRegardless()
    }

    /// Whether a person has the window on screen.
    var isShown: Bool { handBack != nil }

    /// Puts the window on this Mac's screen for a person: titled, resizable and taking the mouse
    /// and keyboard, with the guest's resolution kept, scaled down only to fit. `handBack` runs
    /// when they close the window, which hands the VM back instead of closing it.
    func show(title: String, handBack: @escaping () -> Void) {
        if !isShown {
            Self.shown.append(self)
            NSApplication.shared.setActivationPolicy(.regular)
            Self.startEvents()
        }
        self.handBack = handBack
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.collectionBehavior = []
        window.hasShadow = true  // a window made borderless starts without one
        window.delegate = self
        window.contentAspectRatio = size
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? size
        let scale = min(1, visible.width * 0.9 / size.width, visible.height * 0.9 / size.height)
        window.setContentSize(NSSize(width: size.width * scale, height: size.height * scale))
        window.center()
        view.capturesSystemKeys = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApplication.shared.activate()
    }

    /// Puts the window back off every display at the guest's size, where a guest pixel is a view
    /// point again for paddock's own input.
    func hide() {
        guard isShown else { return }
        handBack = nil
        Self.shown.removeAll { $0 === self }
        view.capturesSystemKeys = false
        window.delegate = nil
        window.styleMask = .borderless
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.hasShadow = false
        window.contentResizeIncrements = NSSize(width: 1, height: 1)  // clears the aspect ratio
        window.setFrame(NSRect(origin: Self.offScreen, size: size), display: false)
        window.orderFrontRegardless()
        if Self.shown.isEmpty {
            Self.pump?.invalidate()
            Self.pump = nil
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }

    /// serve's main thread runs a plain run loop, not AppKit's event loop, so a window on screen
    /// would get no clicks, keys or activation: hand AppKit's events on while any window is shown.
    private static func startEvents() {
        if NSApplication.shared.delegate == nil {
            NSApplication.shared.delegate = dock
            NSApplication.shared.finishLaunching()
        }
        guard pump == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                                 inMode: .default, dequeue: true) {
                    NSApplication.shared.sendEvent(event)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        handBack?()
        return false
    }

    /// paddock in the Dock, while a person has a window: clicking it brings the windows to the
    /// front, and Quit hands them all back instead of stopping serve and every slot with it.
    /// Logging out, restarting or shutting down still stop it; Force Quit can't be caught.
    private final class Dock: NSObject, NSApplicationDelegate {
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let event = NSAppleEventManager.shared().currentAppleEvent
            if let reason = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue,
               [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
                   .map({ OSType($0) }).contains(reason) {
                return .terminateNow
            }
            for screen in VMScreen.shown {
                screen.handBack?()
            }
            return .terminateCancel
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            for screen in VMScreen.shown {
                screen.window.makeKeyAndOrderFront(nil)
            }
            sender.activate()
            return false
        }
    }

    /// The latest frame, copied, or nil until the first frame arrives.
    func capture() throws -> CGImage? {
        guard let surface = try frameSurface() else { return nil }
        return try FrameImage.image(from: surface)
    }

    /// The guest's framebuffer itself, not a copy, or nil until the first frame arrives: what a
    /// view's video encoder reads.
    func frameSurface() throws -> IOSurfaceRef? {
        guard let framebuffer = view.subviews.first(where: { String(describing: type(of: $0)) == "_VZFramebufferView" }) else {
            throw PaddockError("VZVirtualMachineView has no framebuffer view on this macOS, so paddock can't read VM screens")
        }
        guard let contents = framebuffer.layer?.contents else {
            return nil
        }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            throw PaddockError("the VM's framebuffer isn't an IOSurface on this macOS, so paddock can't read VM screens")
        }
        return (contents as! IOSurfaceRef)
    }

    /// The guest's screen in pixels.
    var pixelSize: (width: Int, height: Int) { (Int(size.width), Int(size.height)) }

    /// A view's pointer: where it is in the guest's pixels and which buttons are down. Moves,
    /// presses, drags and releases follow from the change.
    func pointer(x: Int, y: Int, left: Bool, right: Bool) {
        let point = NSPoint(x: Double(min(max(x, 0), Int(size.width) - 1)) + 0.5,
                            y: size.height - Double(min(max(y, 0), Int(size.height) - 1)) - 0.5)
        if left != pointerLeft {
            send(left ? .leftMouseDown : .leftMouseUp, at: point, clickCount: 1)
        }
        if right != pointerRight {
            send(right ? .rightMouseDown : .rightMouseUp, at: point, clickCount: 1)
        }
        if left == pointerLeft, right == pointerRight {
            send(left ? .leftMouseDragged : right ? .rightMouseDragged : .mouseMoved, at: point, clickCount: 0)
        }
        pointerLeft = left
        pointerRight = right
    }

    /// A view's key going down or up, by Mac virtual key code; a modifier key changes the held
    /// modifiers, which every later key carries.
    func key(code: Int, down: Bool) {
        if let modifier = KeyInput.modifier(forKeyCode: code) {
            if down { heldFlags.insert(Self.flag(modifier)) } else { heldFlags.remove(Self.flag(modifier)) }
            sendFlags(Self.keyCode(modifier), heldFlags)
            return
        }
        guard let event = NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: heldFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code)) else { return }
        down ? view.keyDown(with: event) : view.keyUp(with: event)
    }

    /// Lets go of everything a view held, as when it ends with a button or key down.
    func releaseView() {
        pointer(x: Int(size.width) / 2, y: Int(size.height) / 2, left: false, right: false)
        for modifier in KeyStroke.Modifier.allCases where heldFlags.contains(Self.flag(modifier)) {
            heldFlags.remove(Self.flag(modifier))
            sendFlags(Self.keyCode(modifier), heldFlags)
        }
    }

    private var pointerLeft = false, pointerRight = false
    private var heldFlags: NSEvent.ModifierFlags = []

    enum MouseButton: String {
        case left, right
    }

    /// Clicks at `x`, `y` in the guest's screen pixels from the top left, `count` times in a row.
    func click(x: Int, y: Int, button: MouseButton, count: Int) throws {
        let point = try viewPoint(x: x, y: y)
        send(.mouseMoved, at: point, clickCount: 0)
        for click in 1...max(1, count) {
            send(button == .left ? .leftMouseDown : .rightMouseDown, at: point, clickCount: click)
            send(button == .left ? .leftMouseUp : .rightMouseUp, at: point, clickCount: click)
        }
    }

    /// Presses each key stroke in turn, holding its modifiers down around it as a person would,
    /// with a pause after each key goes down or up.
    func press(_ strokes: [KeyStroke]) async {
        for stroke in strokes {
            let held = KeyStroke.Modifier.allCases.filter(stroke.modifiers.contains)
            var flags: NSEvent.ModifierFlags = []
            for modifier in held {
                flags.insert(Self.flag(modifier))
                sendFlags(Self.keyCode(modifier), flags)
                await pause()
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: stroke.keyCode) else { continue }
                type == .keyDown ? view.keyDown(with: event) : view.keyUp(with: event)
                await pause()
            }
            for modifier in held.reversed() {
                flags.remove(Self.flag(modifier))
                sendFlags(Self.keyCode(modifier), flags)
                await pause()
            }
        }
    }

    /// The guest drops keys that go down and up too quickly: of 500 typed without a pause, 163
    /// arrived; with 1 ms, 494; with 2 ms, all of them. 3 ms leaves a margin, at about 100
    /// characters a second.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(3))
    }

    /// Scrolls by about `down` and `right` lines at `x`, `y`: positive `down` toward the end of the
    /// content, positive `right` toward its right edge.
    /// shortcut: VM wheel input reaches the guest as a mouse's, which the guest turns around when
    /// it uses natural scrolling, as macOS does by default; in a golden image that turns natural
    /// scrolling off, scrolls go the other way. Read the setting in the guest if that matters.
    func scroll(x: Int, y: Int, down: Int, right: Int) throws {
        let point = try viewPoint(x: x, y: y)
        send(.mouseMoved, at: point, clickCount: 0)
        // A scroll event made from scratch has no window and sits at the host's own pointer, off
        // the view; one made from a mouse event at the point has both right.
        guard let cgEvent = mouseEvent(.mouseMoved, at: point, clickCount: 0)?.cgEvent else { return }
        cgEvent.type = .scrollWheel
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(down))
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(right))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        view.scrollWheel(with: event)
    }

    /// A point in the view for guest screen pixels, which run from the top left.
    private func viewPoint(x: Int, y: Int) throws -> NSPoint {
        let size = view.bounds.size
        guard (0..<Int(size.width)).contains(x), (0..<Int(size.height)).contains(y) else {
            throw PaddockError("\(x), \(y) is off the guest's \(Int(size.width))x\(Int(size.height)) screen")
        }
        return NSPoint(x: Double(x) + 0.5, y: size.height - Double(y) - 0.5)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) {
        guard let event = mouseEvent(type, at: point, clickCount: clickCount) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        default: view.rightMouseUp(with: event)
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) -> NSEvent? {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .rightMouseDragged].contains(type) ? 1 : 0) else { return nil }
        guard [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type), let cgEvent = event.cgEvent else { return event }
        // AppKit gives every mouse event it makes button 0, the left one, and VZ goes by the button.
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
        return NSEvent(cgEvent: cgEvent)
    }

    /// Presses or releases a modifier key: AppKit reports both as a change of the held flags.
    private func sendFlags(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return }
        cgEvent.type = .flagsChanged
        cgEvent.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        view.flagsChanged(with: event)
    }

    /// A modifier's flag, with the bit for its left-hand key (IOLLEvent.h's NX_DEVICEL*KEYMASK):
    /// VZ reads which modifier keys are down from those bits, not from the flags AppKit names.
    private static func flag(_ modifier: KeyStroke.Modifier) -> NSEvent.ModifierFlags {
        switch modifier {
        case .shift: [.shift, NSEvent.ModifierFlags(rawValue: 0x2)]
        case .control: [.control, NSEvent.ModifierFlags(rawValue: 0x1)]
        case .option: [.option, NSEvent.ModifierFlags(rawValue: 0x20)]
        case .command: [.command, NSEvent.ModifierFlags(rawValue: 0x8)]
        }
    }

    private static func keyCode(_ modifier: KeyStroke.Modifier) -> Int {
        switch modifier {
        case .shift: kVK_Shift
        case .control: kVK_Control
        case .option: kVK_Option
        case .command: kVK_Command
        }
    }

    func close() {
        hide()
        window.orderOut(nil)
        view.virtualMachine = nil
        window.close()
    }
}
