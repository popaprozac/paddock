import Foundation
import Testing
import Virtualization
@testable import PaddockCore

@Suite struct VMConfigurationTests {
    @Test func rejectsGarbageHardwareModel() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        #expect(throws: PaddockError.self) {
            try VMConfiguration.make(bundle: bundle, config: VMConfigTests.sample)
        }
    }

    @Test func needsALinuxVMsEFIStore() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        try Data(count: 1 << 20).write(to: bundle.diskURL)
        let error = #expect(throws: PaddockError.self) {
            try VMConfiguration.make(bundle: bundle, config: VMConfigTests.linuxSample)
        }
        #expect(error?.message.contains("no EFI variable store") == true)
    }

    /// A Linux VM's own hardware: generic platform, EFI, entropy and console, with no display,
    /// keyboard or pointer. (Validating the whole configuration needs the virtualization
    /// entitlement, which the tests don't have.)
    @Test func givesALinuxVMNoDisplayOrUSB() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariablesURL)
        let configuration = VZVirtualMachineConfiguration()
        try VMConfiguration.linux(configuration, bundle: bundle, config: VMConfigTests.linuxSample)
        #expect(configuration.platform is VZGenericPlatformConfiguration)
        #expect(configuration.bootLoader is VZEFIBootLoader)
        #expect(configuration.graphicsDevices.isEmpty && configuration.keyboards.isEmpty && configuration.pointingDevices.isEmpty)
        #expect(configuration.serialPorts.count == 1 && configuration.entropyDevices.count == 1)
        #expect(FileManager.default.fileExists(atPath: bundle.consoleLogURL.path))
        #expect(configuration.directorySharingDevices.isEmpty)
    }

    /// A Linux VM with a desktop gets a screen at its display's size, and USB input.
    @Test func givesADesktopLinuxVMAScreenAndUSBInput() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariablesURL)
        var config = VMConfigTests.linuxSample
        config.desktop = true
        let configuration = VZVirtualMachineConfiguration()
        try VMConfiguration.linux(configuration, bundle: bundle, config: config)
        let scanouts = (configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)?.scanouts ?? []
        #expect(configuration.graphicsDevices.count == 1 && scanouts.count == 1)
        #expect(scanouts.first?.widthInPixels == 1920 && scanouts.first?.heightInPixels == 1200)
        #expect(configuration.keyboards.count == 1 && configuration.keyboards.first is VZUSBKeyboardConfiguration)
        #expect(configuration.pointingDevices.count == 1
            && configuration.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
    }

    /// With Rosetta, the VM gets its share by the tag the guest mounts. Only on a Mac with Rosetta.
    @Test(.enabled(if: VZLinuxRosettaDirectoryShare.availability == .installed))
    func givesARosettaLinuxVMItsShare() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariablesURL)
        var config = VMConfigTests.linuxSample
        config.rosetta = true
        let configuration = VZVirtualMachineConfiguration()
        try VMConfiguration.linux(configuration, bundle: bundle, config: config)
        let shares = configuration.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
        #expect(shares.map(\.tag) == ["rosetta"] && shares.first?.share is VZLinuxRosettaDirectoryShare)
    }

    @Test(arguments: ["", "not-a-mac", "12:34:56:78:9a"])
    func rejectsBadMACAddresses(_ address: String) {
        #expect(throws: PaddockError.self) { try VMConfiguration.macAddress(from: address) }
    }

    @Test func parsesMACAddresses() throws {
        #expect(try VMConfiguration.macAddress(from: "12:34:56:78:9a:bc").string == "12:34:56:78:9a:bc")
    }
}
