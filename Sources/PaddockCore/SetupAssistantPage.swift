import CoreGraphics
import Foundation

/// What `paddock build --accept-macos-license` clicks on a Setup Assistant page, from the text
/// recognized on the guest's screen. Only the buttons that page's owner has opted in to: the
/// license agreement's Agree, which a confirmation sheet asks for twice, and the welcome screen's
/// Get Started. Any other page stops the build, rather than take a default the owner didn't
/// choose, such as sharing analytics with Apple.
public enum SetupAssistantPage {
    /// A line of text recognized on the screen, in guest pixels from the top left.
    public struct Text: Equatable, Sendable {
        public var string: String
        public var frame: CGRect

        public init(_ string: String, _ frame: CGRect) {
            self.string = string
            self.frame = frame
        }
    }

    public static let buttons = ["Agree", "Get Started"]

    /// The button to click, or nil if the page has none of `buttons`. A label must be a whole
    /// line, so "Disagree" and the sentence "I have read and agree…" don't count. When a sheet
    /// covers the license, both show an Agree, and the sheet's, nearer the middle, is the one.
    public static func button(in texts: [Text], screen: CGSize) -> Text? {
        let middle = CGPoint(x: screen.width / 2, y: screen.height / 2)
        func distance(_ text: Text) -> CGFloat {
            hypot(text.frame.midX - middle.x, text.frame.midY - middle.y)
        }
        for label in buttons {
            let matches = texts.filter { $0.string.trimmingCharacters(in: .whitespaces) == label }
            if let nearest = matches.min(by: { distance($0) < distance($1) }) {
                return nearest
            }
        }
        return nil
    }
}
