import Foundation

/// Everything needed to rebuild a VM's hardware, stored as `config.json` in its bundle.
///
/// `hardwareModel` and `machineIdentifier` are the opaque `dataRepresentation` blobs from
/// Virtualization.framework; JSON stores them as base64. A clone gets a new `machineIdentifier`
/// and `macAddress` and keeps everything else.
public struct VMConfig: Codable, Equatable, Sendable {
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
    public var hardwareModel: Data
    public var machineIdentifier: Data
    public var macAddress: String
    public var cpuCount: Int
    public var memorySize: UInt64
    public var diskSize: UInt64
    public var display: Display
    public var os: OSInfo?

    public init(
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
