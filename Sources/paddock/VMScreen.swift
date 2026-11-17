import AppKit
import IOSurface
import PaddockCore
import Virtualization

/// A VM's screen, read on the host. A VZVirtualMachineView sits in a borderless window placed off
/// every display, and the framebuffer view inside it holds the latest frame as an IOSurface, which
/// paddock copies. It takes no permission, in the host or the guest, and opens no listener, but
/// it needs this process to reach the window server, so paddock must run in a logged-in session.
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

    func close() {
        window.orderOut(nil)
        view.virtualMachine = nil
        window.close()
    }
}
