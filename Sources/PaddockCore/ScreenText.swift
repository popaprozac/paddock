import CoreGraphics
import Foundation

/// A line of text recognized on a guest's screen, in its pixels from the top left.
public struct ScreenText: Equatable, Sendable {
    public var string: String
    public var frame: CGRect

    public init(_ string: String, _ frame: CGRect) {
        self.string = string
        self.frame = frame
    }

    /// The first of `labels`, in their order, that is a whole line on the screen, such as a
    /// button's title, or nil if none is. A whole line, so "Agree" doesn't match "Disagree" or a
    /// sentence with "agree" in it. When a label shows more than once, as a sheet's Agree in front
    /// of the one behind it, the one nearest the middle of the screen wins.
    public static func find(_ labels: [String], in lines: [ScreenText], screen: CGSize) -> ScreenText? {
        let middle = CGPoint(x: screen.width / 2, y: screen.height / 2)
        func distance(_ line: ScreenText) -> CGFloat {
            hypot(line.frame.midX - middle.x, line.frame.midY - middle.y)
        }
        for label in labels {
            let matches = lines.filter { $0.string.trimmingCharacters(in: .whitespaces) == label }
            if let nearest = matches.min(by: { distance($0) < distance($1) }) {
                return nearest
            }
        }
        return nil
    }

    /// Whether the screen shows the desktop with Finder in front: Finder's name in the menu bar,
    /// which recognition may read as one line with the menus after it.
    public static func showsFinder(in lines: [ScreenText], screen: CGSize) -> Bool {
        lines.contains { $0.frame.maxY < screen.height * 0.04 && $0.string.hasPrefix("Finder") }
    }
}
