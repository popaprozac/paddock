import CoreGraphics
import Testing
@testable import PaddockCore

@Suite struct SetupAssistantPageTests {
    private let screen = CGSize(width: 1920, height: 1200)

    @Test func clicksAgreeOnTheLicenseNotDisagreeOrTheBodyText() {
        let page = [
            ScreenText("Terms and Conditions", CGRect(x: 735, y: 365, width: 180, height: 24)),
            ScreenText("I have read and agree to the macOS Software License Agreement.", CGRect(x: 860, y: 655, width: 230, height: 60)),
            ScreenText("Disagree", CGRect(x: 1100, y: 850, width: 60, height: 20)),
            ScreenText("Agree", CGRect(x: 1250, y: 850, width: 50, height: 20)),
        ]
        #expect(SetupAssistantPage.button(in: page, screen: screen)?.frame.minX == 1250)
    }

    @Test func clicksTheSheetsAgreeOverTheOneBehindIt() {
        let page = [
            ScreenText("Agree", CGRect(x: 1250, y: 850, width: 50, height: 20)),  // the license, behind
            ScreenText("Disagree", CGRect(x: 880, y: 655, width: 60, height: 20)),
            ScreenText("Agree", CGRect(x: 1030, y: 655, width: 50, height: 20)),  // the sheet
        ]
        #expect(SetupAssistantPage.button(in: page, screen: screen)?.frame.minX == 1030)
    }

    @Test func clicksGetStartedOnTheWelcomeScreen() {
        let page = [ScreenText("Get Started", CGRect(x: 920, y: 1080, width: 90, height: 20))]
        #expect(SetupAssistantPage.button(in: page, screen: screen)?.string == "Get Started")
    }

    @Test func clicksNothingOnAPageNobodyOptedInTo() {
        let page = [
            ScreenText("Analytics", CGRect(x: 900, y: 300, width: 100, height: 24)),
            ScreenText("Continue", CGRect(x: 1250, y: 850, width: 70, height: 20)),
        ]
        #expect(SetupAssistantPage.button(in: page, screen: screen) == nil)
    }
}
