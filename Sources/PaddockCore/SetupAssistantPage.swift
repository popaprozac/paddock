import CoreGraphics
import Foundation

/// What `paddock build --accept-macos-license` clicks on a Setup Assistant page, from the text
/// recognized on the guest's screen. Only the buttons that page's owner has opted in to: the
/// license agreement's Agree, which a confirmation sheet asks for twice, and the welcome screen's
/// Get Started. Any other page stops the build, rather than take a default the owner didn't
/// choose, such as sharing analytics with Apple.
public enum SetupAssistantPage {
    public static let buttons = ["Agree", "Get Started"]

    /// The button to click, or nil if the page has none of `buttons`. When a sheet covers the
    /// license, both show an Agree, and the sheet's, nearer the middle, is the one.
    public static func button(in lines: [ScreenText], screen: CGSize) -> ScreenText? {
        ScreenText.find(buttons, in: lines, screen: screen)
    }
}
