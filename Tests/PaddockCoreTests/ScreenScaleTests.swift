import Foundation
import Testing
@testable import PaddockCore

@Suite struct ScreenScaleTests {
    @Test func fitsTheGuestScreenWithinTheScreenshotKeepingItsShape() {
        let wide = ScreenScale(guestWidth: 1920, guestHeight: 1200)
        #expect((wide.width, wide.height) == (1280, 800))
        let tall = ScreenScale(guestWidth: 1200, guestHeight: 1920)
        #expect((tall.width, tall.height) == (500, 800))
        let small = ScreenScale(guestWidth: 1024, guestHeight: 768)
        #expect((small.width, small.height) == (1024, 768))
    }

    @Test func mapsScreenshotPixelsToTheGuestPixelsUnderThem() throws {
        let scale = ScreenScale(guestWidth: 1920, guestHeight: 1200)
        #expect(try scale.guestPoint(x: 0, y: 0) == (0, 0))
        #expect(try scale.guestPoint(x: 640, y: 400) == (960, 600))
        #expect(try scale.guestPoint(x: 1279, y: 799) == (1919, 1199))
    }

    @Test func refusesPointsOffTheScreenshot() {
        let scale = ScreenScale(guestWidth: 1920, guestHeight: 1200)
        for (x, y) in [(-1, 0), (1280, 0), (0, 800)] {
            #expect(throws: PaddockError.self) { try scale.guestPoint(x: x, y: y) }
        }
    }

    @Test func scalesEveryFrameInATree() throws {
        let json = #"{"role":"AXApplication","frame":[0,0,1920,1200],"children":[{"role":"AXButton","title":"OK","frame":[300,150,90,30]}]}"#
        let tree = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let scaled = ScreenScale(guestWidth: 1920, guestHeight: 1200).scalingFrames(of: tree)
        let out = try #require(scaled as? [String: Any])
        #expect(out["frame"] as? [Int] == [0, 0, 1280, 800])
        #expect(out["role"] as? String == "AXApplication")
        let button = try #require((out["children"] as? [Any])?.first as? [String: Any])
        #expect(button["frame"] as? [Int] == [200, 100, 60, 20])
        #expect(button["title"] as? String == "OK")
    }
}
