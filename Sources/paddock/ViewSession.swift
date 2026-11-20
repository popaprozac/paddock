import CoreMedia
import Foundation
import IOSurface
import PaddockCore
import VideoToolbox

/// A person's view of a VM, from this Mac or another through the pool: the guest's screen as
/// HEVC (H.264 where there's no HEVC encoder) down to the viewer, and their pointer and keyboard
/// back up, as `ViewMessage` lines. serve runs one per view, with agents' input refused, until
/// the viewer stops sending or the VM goes away. A watch is the same with no input taken, so agents
/// keep the VM. Frames are sent only when the screen changed, at most a `ViewFlow` window of them
/// unacknowledged.
final class ViewSession: @unchecked Sendable {
    private let responder: Responder
    private let screen: VMScreen  // main actor only
    private let width: Int
    private let height: Int
    private let watch: Bool  // frames only: the viewer's input is dropped and the guest's left alone
    private let stillHandedOut: @MainActor () -> Bool
    private let onEnd: @MainActor (String) -> Void
    private let lock = NSLock()
    private var flow: ViewFlow      // under lock
    private var wantKeyFrame = true // under lock
    private var ended = false       // under lock
    private var timeline = InputTimeline()  // the input thread's alone
    private let inputQueue = DispatchQueue(label: "paddock.view.input")

    @MainActor
    init(screen: VMScreen, responder: Responder, watch: Bool, stillHandedOut: @escaping @MainActor () -> Bool,
         onEnd: @escaping @MainActor (String) -> Void) {
        self.screen = screen
        self.responder = responder
        (width, height) = screen.pixelSize
        self.watch = watch
        self.stillHandedOut = stillHandedOut
        self.onEnd = onEnd
        flow = ViewFlow(maxKbps: 2000, maxFPS: 30)
    }

    func start() {
        Thread.detachNewThread { [self] in sendFrames() }
        Thread.detachNewThread { [self] in readInput() }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private var isRunning: Bool { lock.withLock { !ended } }

    /// Ends the view once, from whichever side sees it first: tells the viewer why and, unless it
    /// was a watch, lets go of the guest's pointer and keys and hands the VM back to agents.
    private func end(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        responder.finish(ViewMessage.line(ViewMessage.Down(ended: reason)))
        DispatchQueue.main.async { [screen, onEnd, watch] in
            MainActor.assumeIsolated {
                if !watch { screen.releaseView() }  // a watcher held nothing, and someone else may be driving
                onEnd(reason)
            }
        }
    }

    // MARK: Frames

    private func sendFrames() {
        let (kbps, fps) = lock.withLock { (flow.kbps, flow.fps) }
        guard let encoder = VideoEncoder(hevc: true, width: width, height: height, kbps: kbps, fps: fps)
            ?? VideoEncoder(hevc: false, width: width, height: height, kbps: kbps, fps: fps)
        else {
            responder.send(ViewMessage.line(ViewMessage.Down(error: "this Mac has no hardware video encoder")))
            return end("this Mac has no hardware video encoder")
        }
        responder.send(ViewMessage.line(ViewMessage.Down(start: .init(width: width, height: height, codec: encoder.hevc ? "hevc" : "h264"))))
        let copy = FrameCopy(width: width, height: height)
        var number = 0
        var lastFrame = -Double.infinity
        var lastCheck = Self.now
        var lastAdapt = Self.now
        while isRunning {
            let (fps, canSend, keyFrame) = lock.withLock { (flow.fps, flow.canSend, wantKeyFrame) }
            let wait = lastFrame + 1 / Double(fps) - Self.now
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            guard canSend else {
                Thread.sleep(forTimeInterval: 0.005)  // waiting for acknowledgments
                continue
            }
            let started = Self.now
            if started - lastCheck >= 1 {
                lastCheck = started
                let here = DispatchQueue.main.sync { MainActor.assumeIsolated { stillHandedOut() } }
                guard here else { return end("the VM was released") }
            }
            let surface = DispatchQueue.main.sync { MainActor.assumeIsolated { (try? screen.frameSurface()).flatMap { $0 }.map(Surface.init) } }?.ref
            guard let surface, copy.changed(surface) || keyFrame else {
                Thread.sleep(forTimeInterval: 1.0 / 240)  // nothing new on screen yet
                continue
            }
            guard let data = encoder.encode(surface, keyFrame: keyFrame) else { continue }  // dropped by rate control
            number += 1
            for part in ViewMessage.parts(of: data.bytes, number: number, key: data.key, at: started) {
                responder.send(ViewMessage.line(ViewMessage.Down(frame: part)))
            }
            lock.withLock {
                flow.sent(number, at: Self.now)
                if data.key { wantKeyFrame = false }
            }
            lastFrame = started
            if Self.now - lastAdapt >= 1 {
                lastAdapt = Self.now
                if let kbps = lock.withLock({ flow.adapt() ? flow.kbps : nil }) {
                    encoder.setBitrate(kbps)
                }
            }
        }
    }

    // MARK: Input

    private func readInput() {
        var pending = Data()
        while isRunning {
            guard let chunk = responder.receive(upTo: 64 * 1024) else {
                // End of file, or on a local socket a read timeout while the viewer had nothing to say.
                if responder.clientHungUp { break }
                continue
            }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let up = try? JSONDecoder().decode(ViewMessage.Up.self, from: Data(line)) {
                    take(up)
                }
            }
            guard pending.count <= 64 * 1024 else { break }  // no viewer sends lines that long
        }
        end("the viewer closed the view")
    }

    private func take(_ up: ViewMessage.Up) {
        let now = Self.now
        if let ack = up.ack {
            lock.withLock { flow.acknowledged(ack, at: now) }
        }
        if up.keyFrame == true {
            lock.withLock { wantKeyFrame = true }
        }
        guard !watch else { return }
        let stamp = up.at ?? now
        if let pointer = up.pointer {
            apply(at: timeline.time(for: stamp, arrivedAt: now, keyEdge: false)) { screen in
                screen.pointer(x: pointer.x, y: pointer.y, left: pointer.left, right: pointer.right)
            }
        }
        if let key = up.key, (0..<128).contains(key.code) {
            apply(at: timeline.time(for: stamp, arrivedAt: now, keyEdge: true)) { screen in
                screen.key(code: key.code, down: key.down)
            }
        }
        if let scroll = up.scroll, abs(scroll.down) <= 100, abs(scroll.right) <= 100 {
            let x = min(max(scroll.x, 0), width - 1), y = min(max(scroll.y, 0), height - 1)
            apply(at: timeline.time(for: stamp, arrivedAt: now, keyEdge: false)) { screen in
                try? screen.scroll(x: x, y: y, down: scroll.down, right: scroll.right)
            }
        }
    }

    /// Runs `action` on the main actor at `time`, after everything scheduled before it.
    private func apply(at time: Double, _ action: @escaping @MainActor (VMScreen) -> Void) {
        inputQueue.async { [self] in
            let wait = time - Self.now
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            guard isRunning else { return }
            DispatchQueue.main.async { [screen] in MainActor.assumeIsolated { action(screen) } }
        }
    }
}

/// The guest's framebuffer handed from the main actor to the frame thread, which only reads it.
private struct Surface: @unchecked Sendable {
    let ref: IOSurfaceRef
}

/// The last frame sent, to tell whether the screen changed since.
private final class FrameCopy {
    private var pixels: [UInt8]
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Whether the surface differs from the copy; it becomes the copy if so.
    func changed(_ surface: IOSurfaceRef) -> Bool {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        let rows = min(IOSurfaceGetHeight(surface), height), rowLength = min(IOSurfaceGetWidth(surface), width) * 4
        var changed = false
        pixels.withUnsafeMutableBytes { copy in
            for row in 0..<rows {
                let source = base + row * rowBytes, target = copy.baseAddress! + row * width * 4
                if changed || memcmp(source, target, rowLength) != 0 {
                    changed = true
                    memcpy(target, source, rowLength)
                }
            }
        }
        return changed
    }
}

/// HEVC or H.264 from the Mac's hardware encoder in its low-latency mode, as Annex B with the
/// parameter sets in front of each key frame. Frames go in from the guest's IOSurface uncopied.
private final class VideoEncoder {
    let hevc: Bool
    private let session: VTCompressionSession

    init?(hevc: Bool, width: Int, height: Int, kbps: Int, fps: Int) {
        self.hevc = hevc
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                         encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
              let created
        else { return nil }
        session = created
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // The link is TCP and loses nothing: a key frame is needed only to start, or when asked.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32.max as CFNumber)
        setBitrate(kbps)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func setBitrate(_ kbps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: kbps * 1000 as CFNumber)
    }

    /// The surface's picture now, encoded; nil if rate control dropped it or the encoder failed.
    func encode(_ surface: IOSurfaceRef, keyFrame: Bool) -> (bytes: Data, key: Bool)? {
        var wrapped: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &wrapped) == kCVReturnSuccess,
              let buffer = wrapped?.takeRetainedValue() else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: (bytes: Data, key: Bool)?
        let time = CMTime(value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000), timescale: 1_000_000)
        let options = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: options, infoFlagsOut: nil) { [hevc] status, _, sample in
            if status == noErr, let sample { result = Self.annexB(sample, hevc: hevc) }
            done.signal()
        }
        guard status == noErr, done.wait(timeout: .now() + 1) == .success else { return nil }
        return result
    }

    private static func annexB(_ sample: CMSampleBuffer, hevc: Bool) -> (bytes: Data, key: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            let parameterSet = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            var count = 0
            _ = parameterSet(format, 0, nil, nil, &count, nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                _ = parameterSet(format, index, &pointer, &size, nil, nil)
                if let pointer { out += start + UnsafeBufferPointer(start: pointer, count: size) }
            }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else { return nil }
        var i = 0
        while i + 4 <= bytes.count {  // VideoToolbox gives 4-byte lengths in front of each NAL unit
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            out += start + bytes[i..<min(i + length, bytes.count)]
            i += length
        }
        return (out, key)
    }
}
