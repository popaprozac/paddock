import Foundation

/// Everything needed to rebuild a VM's hardware, stored as `config.json` in its bundle.
///
/// `hardwareModel` and `machineIdentifier` are the opaque `dataRepresentation` blobs from
/// Virtualization.framework; JSON stores them as base64. A clone gets a new `machineIdentifier`
/// and `macAddress` and keeps everything else.
///
/// A Linux VM says so in `kind`; a config without it, as every one before Linux VMs, is macOS. A
/// Linux VM's `machineIdentifier` is a VZGenericMachineIdentifier, its `hardwareModel` is empty,
/// and it has a display only with `desktop`.
public struct VMConfig: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case linux
    }

    public struct Display: Codable, Equatable, Sendable {
        public var widthInPixels: Int
        public var heightInPixels: Int
        public var pixelsPerInch: Int

        public init(widthInPixels: Int, heightInPixels: Int, pixelsPerInch: Int) {
            self.widthInPixels = widthInPixels
            self.heightInPixels = heightInPixels
            self.pixelsPerInch = pixelsPerInch
        }

        public static let standard = Display(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
    }

    /// The macOS release the bundle was installed from.
    public struct OSInfo: Codable, Equatable, Sendable {
        public var version: String
        public var build: String

        public init(version: String, build: String) {
            self.version = version
            self.build = build
        }
    }

    public var formatVersion: Int
    public var kind: Kind?  // nil for macOS
    public var hardwareModel: Data
    public var machineIdentifier: Data
    public var macAddress: String
    public var cpuCount: Int
    public var memorySize: UInt64
    public var diskSize: UInt64
    public var display: Display
    public var os: OSInfo?
    /// A Linux VM with Rosetta's share, to run x86-64 programs. Every VM of an image keeps it, since
    /// saved state restores only onto the same devices.
    public var rosetta: Bool?
    /// A Linux VM with a desktop, whose kernel drives a screen and USB input. Every VM of an image
    /// keeps it, since saved state restores only onto the same devices.
    public var desktop: Bool?

    public var isLinux: Bool { kind == .linux }
    /// Whether the VM has a screen and input: every macOS VM, and a Linux VM with a desktop.
    public var hasScreen: Bool { !isLinux || desktop == true }

    public init(
        kind: Kind? = nil,
        hardwareModel: Data,
        machineIdentifier: Data,
        macAddress: String,
        cpuCount: Int,
        memorySize: UInt64,
        diskSize: UInt64,
        display: Display = .standard,
        os: OSInfo? = nil
    ) {
        self.formatVersion = 1
        self.kind = kind
        self.hardwareModel = hardwareModel
        self.machineIdentifier = machineIdentifier
        self.macAddress = macAddress
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.display = display
        self.os = os
    }
}
