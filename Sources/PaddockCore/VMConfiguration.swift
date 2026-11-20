import Foundation
import Virtualization

/// Turns a bundle and its `VMConfig` into a validated Virtualization.framework configuration.
///
/// Install, run and bench all use this, so the golden image and its clones boot on identical
/// virtual hardware. Headless runs keep the graphics device and simply attach no view. A Linux
/// VM gets its own hardware: see `linux`.
public enum VMConfiguration {
    /// `sharing` mounts a host folder read-only in the guest at `/Volumes/My Shared Files`; a Linux
    /// guest mounts it by `linuxShareTag`.
    /// Only `run` uses it, to carry files such as the guest agent into the golden image.
    /// `network` replaces macOS's shared NAT with another attachment, such as a
    /// `UserspaceNetwork`'s; a saved state restores only into the same kind it was saved with.
    public static func make(
        bundle: VMBundle, config: VMConfig, sharing directory: URL? = nil, network attachment: VZNetworkDeviceAttachment? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySize
        if config.isLinux {
            try linux(configuration, bundle: bundle, config: config)
        } else {
            try mac(configuration, bundle: bundle, config: config)
        }

        let disk: VZDiskImageStorageDeviceAttachment
        do {
            disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        } catch {
            throw PaddockError("can't attach \(bundle.diskURL.path): \(error.localizedDescription)")
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = attachment ?? VZNATNetworkDeviceAttachment()
        network.macAddress = try macAddress(from: config.macAddress)
        configuration.networkDevices = [network]

        // The host reaches the future guest agent over vsock; the guest needs no network listener.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let directory {
            let tag = config.isLinux ? linuxShareTag : VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            let share = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: directory, readOnly: true))
            configuration.directorySharingDevices = [share]
        }

        do {
            try configuration.validate()
        } catch {
            throw PaddockError("invalid VM configuration for '\(bundle.name)': \(error.localizedDescription)")
        }
        return configuration
    }

    /// The tag a Linux guest mounts the shared folder by: `mount -t virtiofs paddock-share <dir>`.
    public static let linuxShareTag = "paddock-share"

    /// A macOS guest's platform, boot loader, display, trackpad and keyboard.
    static func mac(_ configuration: VZVirtualMachineConfiguration, bundle: VMBundle, config: VMConfig) throws {
        configuration.platform = try platform(bundle: bundle, config: config)
        configuration.bootLoader = VZMacOSBootLoader()
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.widthInPixels,
                heightInPixels: config.display.heightInPixels,
                pixelsPerInch: config.display.pixelsPerInch),
        ]
        configuration.graphicsDevices = [graphics]
        configuration.pointingDevices = [
            VZMacTrackpadConfiguration(),
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
        ]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
    }

    /// A Linux guest's generic platform, EFI boot, entropy and console. No display, keyboard or
    /// pointer: a cloud image's kernel has no GPU driver, and any USB device stops a Linux VM's
    /// saved state from restoring (it fails with "invalid argument").
    static func linux(_ configuration: VZVirtualMachineConfiguration, bundle: VMBundle, config: VMConfig) throws {
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: config.machineIdentifier) else {
            throw PaddockError("config.json for '\(bundle.name)' has an unreadable machine identifier")
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        configuration.platform = platform
        guard FileManager.default.fileExists(atPath: bundle.efiVariablesURL.path) else {
            throw PaddockError("'\(bundle.name)' has no EFI variable store at \(bundle.efiVariablesURL.path)")
        }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.efiVariablesURL)
        configuration.bootLoader = bootLoader
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // The guest's console, for reading why a guest never came up; each start writes it afresh.
        guard FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil),
              let log = try? FileHandle(forWritingTo: bundle.consoleLogURL) else {
            throw PaddockError("can't write \(bundle.consoleLogURL.path)")
        }
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: log)
        configuration.serialPorts = [console]
    }

    static func platform(bundle: VMBundle, config: VMConfig) throws -> VZMacPlatformConfiguration {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: config.hardwareModel) else {
            throw PaddockError("config.json for '\(bundle.name)' has an unreadable hardware model")
        }
        guard hardwareModel.isSupported else {
            throw PaddockError("this Mac can't run the hardware model of '\(bundle.name)'; update macOS on the host")
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: config.machineIdentifier) else {
            throw PaddockError("config.json for '\(bundle.name)' has an unreadable machine identifier")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return platform
    }

    public static func macAddress(from string: String) throws -> VZMACAddress {
        guard let address = VZMACAddress(string: string) else {
            throw PaddockError("invalid MAC address '\(string)'")
        }
        return address
    }
}
