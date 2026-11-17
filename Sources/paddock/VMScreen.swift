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
final class VMScreen {
    private let window: NSWindow
    private let view: VZVirtualMachineView

    init(machine: VZVirtualMachine, display: VMConfig.Display) throws {
        guard CGSessionCopyCurrentDictionary() != nil else {
            throw PaddockError("this paddock can't reach the window server; start it from a logged-in session to read VM screens")
        }
        _ = NSApplication.shared  // AppKit needs it before any window; without a bundle it shows no Dock icon
        let size = NSSize(width: display.widthInPixels, height: display.heightInPixels)
        view = VZVirtualMachineView(frame: NSRect(origin: .zero, size: size))
        view.virtualMachine = machine
        // Off every display: the view only receives frames once it is in a window, visible or not.
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = view
        window.orderFrontRegardless()
    }

    /// The latest frame, copied, or nil until the first frame arrives.
    func capture() throws -> CGImage? {
        guard let framebuffer = view.subviews.first(where: { String(describing: type(of: $0)) == "_VZFramebufferView" }) else {
            throw PaddockError("VZVirtualMachineView has no framebuffer view on this macOS, so paddock can't read VM screens")
        }
        guard let contents = framebuffer.layer?.contents else {
            return nil
        }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            throw PaddockError("the VM's framebuffer isn't an IOSurface on this macOS, so paddock can't read VM screens")
        }
        return try FrameImage.image(from: contents as! IOSurfaceRef)
    }

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
        case .rightMouseDown: view.rightMouseDown(with: event)
        default: view.rightMouseUp(with: event)
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) -> NSEvent? {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { return nil }
        guard type == .rightMouseDown || type == .rightMouseUp, let cgEvent = event.cgEvent else { return event }
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
        window.orderOut(nil)
        view.virtualMachine = nil
        window.close()
    }
}
