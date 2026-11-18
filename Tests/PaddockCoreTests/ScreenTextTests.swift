import CoreGraphics
import Testing
@testable import PaddockCore

@Suite struct ScreenTextTests {
    private let screen = CGSize(width: 1920, height: 1200)

    @Test func findsFinderInTheMenuBar() {
        let merged = ScreenText("Finder File Edit View Go Window Help", CGRect(x: 60, y: 8, width: 400, height: 20))
        let alone = ScreenText("Finder", CGRect(x: 60, y: 8, width: 60, height: 20))
        #expect(ScreenText.showsFinder(in: [merged], screen: screen))
        #expect(ScreenText.showsFinder(in: [alone], screen: screen))
    }

    @Test func doesNotTakeFinderElsewhereOrAnotherAppForTheDesktop() {
        let lower = ScreenText("Finder", CGRect(x: 700, y: 500, width: 60, height: 20))
        let other = ScreenText("Setup Assistant", CGRect(x: 60, y: 8, width: 140, height: 20))
        #expect(!ScreenText.showsFinder(in: [lower, other], screen: screen))
    }
}
