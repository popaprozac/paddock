import CoreGraphics
import Testing
@testable import PaddockCore

@Suite struct SessionHelperTests {
    private func window(_ owner: String) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: 0]
    }

    @Test func reportsTheDesktopOnceLoginwindowHasNoWindowOnScreen() {
        #expect(SessionHelper.state(onScreen: [window("Dock"), window("Finder"), window("TextEdit")]) == ["desktop"])
    }

    @Test func holdsTheDesktopBackWhileLoginwindowShowsAWindow() {
        #expect(SessionHelper.state(onScreen: [window("Dock"), window("loginwindow")]).isEmpty)
    }

    @Test func holdsTheDesktopBackWithoutAWindowList() {
        #expect(SessionHelper.state(onScreen: nil).isEmpty)
    }

    @Test func readsTheAppFrontReplacedWithFinder() {
        #expect(SessionHelper.replacedApp(in: SessionHelper.broughtFinderForward + "Accessibility") == "Accessibility")
        #expect(SessionHelper.replacedApp(in: "Finder") == nil)
        #expect(SessionHelper.replacedApp(in: "TextEdit") == nil)
    }
}
