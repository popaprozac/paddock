import Foundation

/// Maps between a VM's screen and the smaller screenshots an agent sees. Models work best with
/// screenshots of about 1280x800, so the guest's screen is fitted within that, keeping its shape,
/// and every coordinate the agent sees or gives is in the screenshot's pixels.
public struct ScreenScale: Equatable, Sendable {
    public let guestWidth: Int
    public let guestHeight: Int
    /// The screenshot's size.
    public let width: Int
    public let height: Int

    /// Fits a guest screen of `guestWidth` x `guestHeight` within `maxWidth` x `maxHeight`; a
    /// screen that already fits keeps its size.
    public init(guestWidth: Int, guestHeight: Int, maxWidth: Int = 1280, maxHeight: Int = 800) {
        let factor = min(1, Double(maxWidth) / Double(guestWidth), Double(maxHeight) / Double(guestHeight))
        self.guestWidth = guestWidth
        self.guestHeight = guestHeight
        width = max(1, Int((Double(guestWidth) * factor).rounded()))
        height = max(1, Int((Double(guestHeight) * factor).rounded()))
    }

    /// The guest pixel at the middle of screenshot pixel `x`, `y`. Throws for a point off the
    /// screenshot.
    public func guestPoint(x: Int, y: Int) throws -> (x: Int, y: Int) {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            throw PaddockError("\(x), \(y) is off the \(width)x\(height) screenshot")
        }
        return (min(guestWidth - 1, Int((Double(x) + 0.5) * Double(guestWidth) / Double(width))),
                min(guestHeight - 1, Int((Double(y) + 0.5) * Double(guestHeight) / Double(height))))
    }

    /// An accessibility tree, as JSONSerialization reads it, with every frame, [x, y, width,
    /// height] in guest pixels, turned into whole screenshot pixels.
    public func scalingFrames(of tree: Any) -> Any {
        if var element = tree as? [String: Any] {
            for (key, value) in element {
                element[key] = key == "frame" ? frame(value) ?? value : scalingFrames(of: value)
            }
            return element
        }
        if let children = tree as? [Any] {
            return children.map { scalingFrames(of: $0) }
        }
        return tree
    }

    private func frame(_ value: Any?) -> [Int]? {
        guard let numbers = (value as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), numbers.count == 4 else {
            return nil
        }
        let sx = Double(width) / Double(guestWidth), sy = Double(height) / Double(guestHeight)
        return zip(numbers, [sx, sy, sx, sy]).map { Int(($0 * $1).rounded()) }
    }
}
