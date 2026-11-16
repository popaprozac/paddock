import Foundation
import Virtualization

/// Turns a bundle and its `VMConfig` into a validated Virtualization.framework configuration.
///
/// Install, run and bench all use this, so the golden image and its clones boot on identical
/// virtual hardware. Headless runs keep the graphics device and simply attach no view.
public enum VMConfiguration {
    /// `sharing` mounts a host folder read-only in the guest at `/Volumes/My Shared Files`.
    /// Only `run` uses it, to carry files such as the guest agent into the golden image.
    public static func make(
        bundle: VMBundle, config: VMConfig, sharing directory: URL? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = try platform(bundle: bundle, config: config)
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySize

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.widthInPixels,
                heightInPixels: config.display.heightInPixels,
                pixelsPerInch: config.display.pixelsPerInch),
        ]
        configuration.graphicsDevices = [graphics]

        let disk: VZDiskImageStorageDeviceAttachment
        do {
            disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        } catch {
            throw PaddockError("can't attach \(bundle.diskURL.path): \(error.localizedDescription)")
        }
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = try macAddress(from: config.macAddress)
        configuration.networkDevices = [network]

        configuration.pointingDevices = [
            VZMacTrackpadConfiguration(),
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
        ]
        configuration.keyboards = [VZMacKeyboardConfiguration()]

        // The host reaches the future guest agent over vsock; the guest needs no network listener.
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        if let directory {
            let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
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
