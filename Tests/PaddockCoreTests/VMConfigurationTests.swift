import Foundation
import Testing
@testable import PaddockCore

@Suite struct VMConfigurationTests {
    @Test func rejectsGarbageHardwareModel() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        #expect(throws: PaddockError.self) {
            try VMConfiguration.make(bundle: bundle, config: VMConfigTests.sample)
        }
    }

    @Test(arguments: ["", "not-a-mac", "12:34:56:78:9a"])
    func rejectsBadMACAddresses(_ address: String) {
        #expect(throws: PaddockError.self) { try VMConfiguration.macAddress(from: address) }
    }

    @Test func parsesMACAddresses() throws {
        #expect(try VMConfiguration.macAddress(from: "12:34:56:78:9a:bc").string == "12:34:56:78:9a:bc")
    }
}
