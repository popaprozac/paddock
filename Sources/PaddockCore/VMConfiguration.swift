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
    /// `seed` attaches a disk image read-only as a second disk, as `build` does with a Linux
    /// image's cloud-init seed. `console` connects a Linux guest's console to something other than
    /// its console.log, such as `run`'s terminal.
    public static func make(
        bundle: VMBundle, config: VMConfig, sharing directory: URL? = nil, network attachment: VZNetworkDeviceAttachment? = nil,
        seed: URL? = nil, console: VZSerialPortAttachment? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySize
        if config.isLinux {
            try linux(configuration, bundle: bundle, config: config, console: console)
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
        if let seed {
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)
                configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                throw PaddockError("can't attach \(seed.path): \(error.localizedDescription)")
            }
        }

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
            configuration.directorySharingDevices.append(share)
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

    /// A Linux guest's generic platform, EFI boot, entropy and console, and with a desktop, a
    /// screen at the config's display size, a USB keyboard and a USB pointer. Without one, none of
    /// those: a cloud image's kernel drives neither, and with USB devices its saved state doesn't
    /// restore ("invalid argument"). A kernel with XHCI and HID drivers restores with them.
    static func linux(_ configuration: VZVirtualMachineConfiguration, bundle: VMBundle, config: VMConfig,
                      console attachment: VZSerialPortAttachment? = nil) throws {
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
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        if let attachment {
            console.attachment = attachment
        } else {
            // The guest's console, for reading why a guest never came up; each start writes it afresh.
            guard FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil),
                  let log = try? FileHandle(forWritingTo: bundle.consoleLogURL) else {
                throw PaddockError("can't write \(bundle.consoleLogURL.path)")
            }
            console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: log)
        }
        configuration.serialPorts = [console]
        if config.rosetta == true {
            configuration.directorySharingDevices = [try rosettaShare()]
        }
        if config.desktop == true {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: config.display.widthInPixels, heightInPixels: config.display.heightInPixels)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
    }

    /// The tag a Linux guest mounts Rosetta's share by, and the abstract socket its translation
    /// cache, rosettad, listens on in the guest.
    public static let rosettaTag = "rosetta"

    /// Rosetta's share, with its ahead-of-time translation cache on, which makes launching an
    /// x86-64 program again about four times faster.
    static func rosettaShare() throws -> VZVirtioFileSystemDeviceConfiguration {
        try checkRosetta()
        let share = try VZLinuxRosettaDirectoryShare()
        try share.setCachingOptions(.abstractSocket(rosettaTag))
        let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
        device.share = share
        return device
    }

    /// Fails unless this Mac can give a Linux VM Rosetta, saying how to install it if it can.
    public static func checkRosetta() throws {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            break
        case .notInstalled:
            throw PaddockError("Rosetta isn't installed on this Mac, and this Linux image uses it. Install it with "
                + "'softwareupdate --install-rosetta --agree-to-license', which accepts Apple's license for Rosetta")
        default:
            throw PaddockError("this Mac can't run Rosetta for Linux VMs, and this Linux image uses it")
        }
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
