import Foundation

/// What `paddock view` and serve say to each other, as JSON lines: serve's frames down, the
/// viewer's acknowledgments and input up. Frames are HEVC or H.264 in Annex B.
public enum ViewMessage {
    /// serve's first line: the guest's screen and how its frames are encoded.
    public struct Start: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var codec: String  // "hevc" or "h264"

        public init(width: Int, height: Int, codec: String) {
            self.width = width
            self.height = height
            self.codec = codec
        }
    }

    /// A video frame, or part of one: a frame over `partSize` goes in pieces, the last marked.
    public struct Frame: Codable, Equatable, Sendable {
        public var number: Int  // 1, 2, 3...: the viewer acknowledges each frame by it
        public var key: Bool
        public var last: Bool
        public var data: Data

        public init(number: Int, key: Bool, last: Bool, data: Data) {
            self.number = number
            self.key = key
            self.last = last
            self.data = data
        }
    }

    /// One of serve's lines: exactly one field is set.
    public struct Down: Codable, Equatable, Sendable {
        public var start: Start?
        public var frame: Frame?
        public var ended: String?  // why the view ended, as when the VM was released
        public var error: String?

        public init(start: Start? = nil, frame: Frame? = nil, ended: String? = nil, error: String? = nil) {
            self.start = start
            self.frame = frame
            self.ended = ended
            self.error = error
        }
    }

    /// One of the viewer's lines: one event. `at` is the viewer's own clock, in seconds, so serve
    /// can replay input with the gaps it had there, not the bunching a stalled link adds.
    public struct Up: Codable, Equatable, Sendable {
        public var ack: Int?         // this frame arrived whole
        public var keyFrame: Bool?   // send a key frame next, as when the viewer's display failed
        public var pointer: Pointer?
        public var key: Key?
        public var scroll: Scroll?
        public var at: Double?

        public init(ack: Int? = nil, keyFrame: Bool? = nil, pointer: Pointer? = nil, key: Key? = nil, scroll: Scroll? = nil,
                    at: Double? = nil) {
            self.ack = ack
            self.keyFrame = keyFrame
            self.pointer = pointer
            self.key = key
            self.scroll = scroll
            self.at = at
        }
    }

    /// Where the pointer is, in the guest's screen pixels from the top left, and which buttons are down.
    public struct Pointer: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var left: Bool
        public var right: Bool

        public init(x: Int, y: Int, left: Bool, right: Bool) {
            self.x = x
            self.y = y
            self.left = left
            self.right = right
        }
    }

    /// A key going down or up, by its Mac virtual key code: both ends are Macs. Modifier keys too.
    public struct Key: Codable, Equatable, Sendable {
        public var code: Int
        public var down: Bool

        public init(code: Int, down: Bool) {
            self.code = code
            self.down = down
        }
    }

    /// Lines to scroll at a point: positive `down` toward the end of the content, as `paddock scroll`.
    public struct Scroll: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var down: Int
        public var right: Int

        public init(x: Int, y: Int, down: Int, right: Int) {
            self.x = x
            self.y = y
            self.down = down
            self.right = right
        }
    }

    /// The most frame data one line carries. Base64 and JSON make it about 256 KB, well under the
    /// control plane's 1 MB message cap.
    public static let partSize = 192 * 1024

    /// A frame as the lines that carry it.
    public static func parts(of data: Data, number: Int, key: Bool) -> [Frame] {
        guard data.count > partSize else { return [Frame(number: number, key: key, last: true, data: data)] }
        return stride(from: 0, to: data.count, by: partSize).map { offset in
            let end = min(offset + partSize, data.count)
            return Frame(number: number, key: key, last: end == data.count, data: data.subdata(in: offset..<end))
        }
    }

    /// JSON for one line: slashes unescaped, since base64 is full of them.
    public static func line(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
