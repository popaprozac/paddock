import Testing
@testable import PaddockCore

@Suite struct GuestSupportTests {
    private func failure(_ version: String, license: Bool) -> String {
        do {
            return "\(try GuestSupport.firstBoot(macOS: version, acceptsLicense: license))"
        } catch {
            return "\(error)"
        }
    }

    @Test func provisionsMacOS27AndLaterWithOrWithoutTheLicense() throws {
        #expect(try GuestSupport.firstBoot(macOS: "27.2.1", acceptsLicense: false) == .provisioning)
        #expect(try GuestSupport.firstBoot(macOS: "28.0", acceptsLicense: true) == .provisioning)
    }

    @Test func clicksThroughMacOS26OnlyWithTheLicenseAccepted() throws {
        #expect(try GuestSupport.firstBoot(macOS: "26.6.2", acceptsLicense: true) == .setupAssistant)
        #expect(failure("26.6.2", license: false).contains("needs license: accept"))
    }

    @Test func leavesOlderVersionsToSetUpByHand() {
        #expect(failure("15.6.1", license: true).contains("set this one up by hand"))
        #expect(failure("Tahoe", license: true) == "can't tell which macOS 'Tahoe' is")
    }

    @Test func readsTheMajorVersion() {
        #expect(GuestSupport.major("26.6.2") == 26)
        #expect(GuestSupport.major("27") == 27)
        #expect(GuestSupport.major("") == nil)
    }
}
