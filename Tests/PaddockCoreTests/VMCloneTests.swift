import Foundation
import Testing
import Virtualization
@testable import PaddockCore

@Suite struct VMCloneTests {
    /// A source bundle with small but recognizable disk and aux files.
    func makeSource(in tmp: TemporaryDirectory) throws -> VMBundle {
        let source = VMBundle(url: tmp.url.appendingPathComponent("vms/golden"))
        try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
        try Data("boot disk".utf8).write(to: source.diskURL)
        try Data("nvram".utf8).write(to: source.auxiliaryStorageURL)
        try source.writeConfig(VMConfigTests.sample)
        return source
    }

    @Test func copiesDisksAndGivesTheCloneAFreshIdentity() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        let clone = VMBundle(url: tmp.url.appendingPathComponent("vms/clone-1"))

        let config = try VMClone.clone(source, to: clone)

        #expect(try Data(contentsOf: clone.diskURL) == Data("boot disk".utf8))
        #expect(try Data(contentsOf: clone.auxiliaryStorageURL) == Data("nvram".utf8))
        #expect(try clone.readConfig() == config)

        let original = VMConfigTests.sample
        #expect(config.hardwareModel == original.hardwareModel)
        #expect(config.cpuCount == original.cpuCount)
        #expect(config.machineIdentifier != original.machineIdentifier)
        #expect(VZMacMachineIdentifier(dataRepresentation: config.machineIdentifier) != nil)
        #expect(config.macAddress != original.macAddress)
        #expect(VZMACAddress(string: config.macAddress)?.isLocallyAdministeredAddress == true)
        #expect(try source.readConfig() == original)
    }

    @Test func clonesDoNotShareAnIdentity() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        let a = try VMClone.clone(source, to: VMBundle(url: tmp.url.appendingPathComponent("vms/a")))
        let b = try VMClone.clone(source, to: VMBundle(url: tmp.url.appendingPathComponent("vms/b")))
        #expect(a.machineIdentifier != b.machineIdentifier)
        #expect(a.macAddress != b.macAddress)
    }

    @Test func writesToTheCloneDoNotReachTheSource() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        let clone = VMBundle(url: tmp.url.appendingPathComponent("vms/clone-1"))
        _ = try VMClone.clone(source, to: clone)
        try Data("changed".utf8).write(to: clone.diskURL)
        #expect(try Data(contentsOf: source.diskURL) == Data("boot disk".utf8))
    }

    @Test func refusesAnExistingDestination() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        let clone = VMBundle(url: tmp.url.appendingPathComponent("vms/clone-1"))
        _ = try VMClone.clone(source, to: clone)
        #expect(throws: PaddockError.self) { try VMClone.clone(source, to: clone) }
    }

    @Test func refusesASourceThatIsInUse() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        let running = try BundleLock(bundle: source)
        let clone = VMBundle(url: tmp.url.appendingPathComponent("vms/clone-1"))
        #expect(throws: PaddockError.self) { try VMClone.clone(source, to: clone) }
        #expect(!FileManager.default.fileExists(atPath: clone.url.path))
        withExtendedLifetime(running) {}
    }

    @Test func leavesNothingBehindWhenTheSourceIsIncomplete() throws {
        let tmp = try TemporaryDirectory()
        let source = try makeSource(in: tmp)
        try FileManager.default.removeItem(at: source.auxiliaryStorageURL)
        let clone = VMBundle(url: tmp.url.appendingPathComponent("vms/clone-1"))
        #expect(throws: PaddockError.self) { try VMClone.clone(source, to: clone) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.appendingPathComponent("vms").path)
        #expect(leftovers == ["golden"])
    }
}
