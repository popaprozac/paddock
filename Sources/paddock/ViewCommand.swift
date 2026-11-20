import AppKit
import ArgumentParser
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import Foundation
import PaddockCore

struct View: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a window onto a VM you acquired, from this Mac or another, and drive it.",
        discussion: """
            The VM's screen comes as video from the Mac running it, through the control plane when \
            this Mac is logged in to one, and your pointer and keyboard go back the same way; \
            nothing connects to that Mac or the VM directly. While the window is open, input from \
            agents and the CLI waits, as with paddock show; screenshots, the accessibility tree \
            and commands go on. Command shortcuts go to the VM. Close the window to hand the VM back.
            """
    )

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @OptionGroup var target: Target

    @Flag(help: "Print what arrives every 5 s: frames a second, bitrate and freezes.")
    var stats = false

    func run() throws {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["op": "view", "vm": vm]), as: UTF8.self)
        let link: ViewLink
        if let identity = try PoolRoute.identity(local: target.local) {
            link = PoolViewLink(request: line, identity: identity)
        } else {
            link = try LocalViewLink(request: line, path: PaddockHome.fromEnvironment().socketURL.path)
        }
        let viewer = Viewer(vm: vm, link: link, stats: stats)
        let app = NSApplication.shared
        app.delegate = viewer
        app.setActivationPolicy(.regular)
        app.run()  // never returns: the viewer exits when the view ends
    }
}

// MARK: The link

/// serve's lines in, the viewer's lines out, over this Mac's socket or the pool.
protocol ViewLink: AnyObject, Sendable {
    /// Starts reading: `onLine` for each of serve's lines on a reader thread, then `onEnd` once.
    func start(onLine: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Error?) -> Void)
    func send(_ line: String)
    func close()
}

final class LocalViewLink: ViewLink, @unchecked Sendable {
    private let connection: LineConnection

    init(request: String, path: String) throws {
        connection = try LineConnection(path: path)
        connection.send(request)
    }

    func start(onLine: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) {
        Thread.detachNewThread { [connection] in
            while let line = connection.readLine() {
                onLine(line)
            }
            onEnd(nil)
        }
    }

    func send(_ line: String) {
        connection.send(line)
    }

    func close() {
        connection.close()
    }
}

final class PoolViewLink: ViewLink, @unchecked Sendable {
    private let request: String
    private let identity: ControlIdentity
    private let (outgoing, continuation) = AsyncStream<Data>.makeStream()

    init(request: String, identity: ControlIdentity) {
        self.request = request
        self.identity = identity
    }

    func start(onLine: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Error?) -> Void) {
        Task.detached { [self] in
            do {
                let connection = try await SharedLink.shared.connection(for: identity)
                let asked = ControlLink.Message(type: "request", op: "view", serve: request)
                for try await answer in connection.request(asked, sending: outgoing) {
                    if let error = answer.error { throw PaddockError(error) }
                    if let line = answer.line, !line.isEmpty { onLine(line) }
                }
                onEnd(nil)
            } catch {
                onEnd(error)
            }
        }
    }

    func send(_ line: String) {
        continuation.yield(Data((line + "\n").utf8))
    }

    func close() {
        continuation.finish()
    }
}

// MARK: The window

/// The viewer: the window, the decoder, and the lines both ways.
final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    private let vm: String
    private let link: ViewLink
    private let stats: Bool
    private var window: NSWindow?
    private var screenView: ScreenView?
    private let decoder = FrameDecoder()  // the reader thread's
    private var part = Data()             // the reader thread's: a frame's pieces so far
    private let lock = NSLock()
    private var arrived: [CMSampleBuffer] = []  // decoded, waiting for the next screen refresh
    private var counts = (frames: 0, bytes: 0, freezes: 0, skipped: 0, displayFailures: 0)
    private var freezes = FreezeCount()

    init(vm: String, link: ViewLink, stats: Bool) {
        self.vm = vm
        self.link = link
        self.stats = stats
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        link.start(onLine: { [weak self] line in self?.take(line) }, onEnd: { [weak self] error in
            DispatchQueue.main.async { self?.finish(error.map { "paddock: \($0.localizedDescription)" }) }
        })
        // At each screen refresh, the frames that arrived since: all decoded, only the newest shown.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.display() }
        if stats {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.report() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowWillClose(_ notification: Notification) {
        link.close()
        exit(0)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// One of serve's lines, on the reader thread.
    private func take(_ line: String) {
        guard let down = try? JSONDecoder().decode(ViewMessage.Down.self, from: Data(line.utf8)) else { return }
        if let start = down.start {
            decoder.hevc = start.codec == "hevc"
            DispatchQueue.main.async { [self] in open(start) }
        }
        if let frame = down.frame {
            part.append(frame.data)
            guard frame.last else { return }
            let data = part
            part = Data()
            send(ViewMessage.Up(ack: frame.number, at: Self.now))  // room for one more frame
            let now = Self.now
            lock.withLock {
                if freezes.arrived(at: now) { counts.freezes += 1 }
                counts.frames += 1
                counts.bytes += line.utf8.count
            }
            if let sample = decoder.sample(from: data) {
                lock.withLock { arrived.append(sample) }
            }
        }
        if let reason = down.ended ?? down.error {
            DispatchQueue.main.async { [self] in finish("paddock: the view ended: \(reason)") }
        }
    }

    func send(_ up: ViewMessage.Up) {
        link.send(ViewMessage.line(up))
    }

    private func open(_ start: ViewMessage.Start) {
        guard window == nil else { return }
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = min(1, visible.width * 0.9 / CGFloat(start.width), visible.height * 0.9 / CGFloat(start.height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(start.width) * scale, height: CGFloat(start.height) * scale),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(vm): handed to you; close this window to hand it back"
        window.contentAspectRatio = NSSize(width: start.width, height: start.height)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = ScreenView(guest: (start.width, start.height)) { [weak self] up in self?.send(up) }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        screenView = view
    }

    private func display() {
        guard let renderer = screenView?.display.sampleBufferRenderer else { return }
        let batch = lock.withLock { () -> [CMSampleBuffer] in defer { arrived = [] }; return arrived }
        guard !batch.isEmpty else { return }
        if renderer.status == .failed {
            // A frame didn't decode: start again from a key frame.
            lock.withLock { counts.displayFailures += 1 }
            renderer.flush()
            send(ViewMessage.Up(keyFrame: true, at: Self.now))
        }
        lock.withLock { counts.skipped += batch.count - 1 }
        for (index, sample) in batch.enumerated() {
            FrameDecoder.mark(sample, show: index == batch.count - 1)
            renderer.enqueue(sample)
        }
    }

    private func report() {
        let c = lock.withLock { () -> (frames: Int, bytes: Int, freezes: Int, skipped: Int, displayFailures: Int) in
            defer { counts = (0, 0, 0, 0, counts.displayFailures) }
            return counts
        }
        FileHandle.standardError.write(Data(String(format: "%.1f frames/s, %.2f Mbit/s, %d freezes, %d skipped, display failed %d times\n",
                                                   Double(c.frames) / 5, Double(c.bytes) * 8 / 5e6, c.freezes, c.skipped, c.displayFailures).utf8))
    }

    private func finish(_ message: String?) {
        if let message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        link.close()
        exit(message == nil ? 0 : 1)
    }
}

/// The VM's screen, and the person's pointer and keyboard sent back as the guest's pixels and
/// Mac key codes, each stamped with this Mac's clock.
final class ScreenView: NSView {
    let display = AVSampleBufferDisplayLayer()
    private let guest: (width: Int, height: Int)
    private let send: (ViewMessage.Up) -> Void
    private var left = false, right = false
    private var scrolled = (down: 0.0, right: 0.0)

    init(guest: (Int, Int), send: @escaping (ViewMessage.Up) -> Void) {
        self.guest = guest
        self.send = send
        super.init(frame: .zero)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        layer?.addSublayer(display)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        display.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func guestPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let x = Int(p.x / max(bounds.width, 1) * CGFloat(guest.width))
        let y = Int((1 - p.y / max(bounds.height, 1)) * CGFloat(guest.height))
        return (min(max(x, 0), guest.width - 1), min(max(y, 0), guest.height - 1))
    }

    private func pointer(_ event: NSEvent) {
        let (x, y) = guestPoint(event)
        send(ViewMessage.Up(pointer: .init(x: x, y: y, left: left, right: right), at: now))
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { left = true; pointer(event) }
    override func mouseUp(with event: NSEvent) { left = false; pointer(event) }
    override func rightMouseDown(with event: NSEvent) { right = true; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { right = false; pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad's points come many to a line; a wheel's deltas are lines. Content directions,
        // as paddock scroll takes them: positive down is toward the end of the content.
        let per = event.hasPreciseScrollingDeltas ? 10.0 : 1.0
        scrolled.down -= event.scrollingDeltaY / per
        scrolled.right -= event.scrollingDeltaX / per
        let down = Int(scrolled.down), right = Int(scrolled.right)
        guard down != 0 || right != 0 else { return }
        scrolled.down -= Double(down)
        scrolled.right -= Double(right)
        let (x, y) = guestPoint(event)
        send(ViewMessage.Up(scroll: .init(x: x, y: y, down: down, right: right), at: now))
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }  // the guest repeats a held key itself
        send(ViewMessage.Up(key: .init(code: Int(event.keyCode), down: true), at: now))
    }

    override func keyUp(with event: NSEvent) {
        send(ViewMessage.Up(key: .init(code: Int(event.keyCode), down: false), at: now))
    }

    /// Command shortcuts go to the VM, not to this window. AppKit sends no key up for them, so
    /// one follows straight away; serve spaces them as the guest needs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if !event.isARepeat {
            send(ViewMessage.Up(key: .init(code: Int(event.keyCode), down: true), at: now))
            send(ViewMessage.Up(key: .init(code: Int(event.keyCode), down: false), at: now))
        }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard let modifier = KeyInput.modifier(forKeyCode: Int(event.keyCode)) else { return }
        let flag: NSEvent.ModifierFlags = switch modifier {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
        send(ViewMessage.Up(key: .init(code: Int(event.keyCode), down: event.modifierFlags.contains(flag)), at: now))
    }
}

// MARK: Decoding

/// HEVC or H.264 in Annex B to sample buffers the display layer decodes in hardware.
final class FrameDecoder: @unchecked Sendable {
    var hevc = true
    private var format: CMVideoFormatDescription?
    private var vps = Data(), sps = Data(), pps = Data()

    func sample(from data: Data) -> CMSampleBuffer? {
        var lengthPrefixed = Data()
        var newParameters = false
        for unit in Self.units(in: data) where !unit.isEmpty {
            // NAL unit types: H.264 keeps them in the low 5 bits, HEVC in bits 1 to 6.
            switch hevc ? Int(unit[unit.startIndex] >> 1 & 0x3f) : Int(unit[unit.startIndex] & 0x1f) {
            case hevc ? 32 : -1: vps = unit
            case hevc ? 33 : 7: sps = unit; newParameters = true
            case hevc ? 34 : 8: pps = unit
            default:
                var length = UInt32(unit.count).bigEndian
                lengthPrefixed.append(Data(bytes: &length, count: 4))
                lengthPrefixed.append(unit)
            }
        }
        if newParameters { format = makeFormat() }
        guard let format, !lengthPrefixed.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: lengthPrefixed.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: lengthPrefixed.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              lengthPrefixed.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                              dataLength: lengthPrefixed.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = lengthPrefixed.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Shown at once, or decoded only, as frames that a newer one overtook.
    static func mark(_ sample: CMSampleBuffer, show: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if !show {
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }

    /// The NAL units between start codes.
    private static func units(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0, start = -1
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 { units.append(Data(bytes[start..<(i > 0 && bytes[i - 1] == 0 ? i - 1 : i)])) }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        let sets = hevc ? [vps, sps, pps] : [sps, pps]
        guard sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        var made: CMVideoFormatDescription?
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: copy, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        if hevc {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                formatDescriptionOut: &made)
        } else {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made)
        }
        return made
    }
}
