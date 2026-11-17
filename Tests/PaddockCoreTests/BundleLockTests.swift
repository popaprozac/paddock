import Foundation
import Testing
@testable import PaddockCore

@Suite struct BundleLockTests {
    func makeBundle(in tmp: TemporaryDirectory) throws -> VMBundle {
        let bundle = VMBundle(url: tmp.url)
        try bundle.writeConfig(VMConfigTests.sample)
        return bundle
    }

    @Test func secondLockOnSameBundleFails() throws {
        let tmp = try TemporaryDirectory()
        let bundle = try makeBundle(in: tmp)
        let held = try BundleLock(bundle: bundle)
        #expect(throws: PaddockError.self) { try BundleLock(bundle: bundle) }
        withExtendedLifetime(held) {}
    }

    @Test func lockIsReleasedWhenDropped() throws {
        let tmp = try TemporaryDirectory()
        let bundle = try makeBundle(in: tmp)
        do { _ = try BundleLock(bundle: bundle) }
        _ = try BundleLock(bundle: bundle)
    }

    @Test func lockingAMissingBundleFails() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("missing"))
        #expect(throws: PaddockError.self) { try BundleLock(bundle: bundle) }
    }
}
