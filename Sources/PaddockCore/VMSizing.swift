import Foundation
import Virtualization

/// Picks CPU and memory for a new VM: the user's request, raised to what the macOS image needs
/// and capped at what this host allows.
public enum VMSizing {
    public static let defaultCPUCount = 4
    public static let defaultMemorySize: UInt64 = 8 << 30
    public static let defaultDiskSize: UInt64 = 80 << 30

    public struct Limits: Sendable {
        public var minimumCPUCount: Int
        public var maximumCPUCount: Int
        public var minimumMemorySize: UInt64
        public var maximumMemorySize: UInt64

        public init(minimumCPUCount: Int, maximumCPUCount: Int, minimumMemorySize: UInt64, maximumMemorySize: UInt64) {
            self.minimumCPUCount = minimumCPUCount
            self.maximumCPUCount = maximumCPUCount
            self.minimumMemorySize = minimumMemorySize
            self.maximumMemorySize = maximumMemorySize
        }

        /// The image's minimums combined with this host's maximums.
        public static func forImage(_ image: LocalRestoreImage) -> Limits {
            Limits(
                minimumCPUCount: max(image.minimumCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                minimumMemorySize: max(image.minimumMemorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                maximumMemorySize: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        }
    }

    public struct Resolved: Equatable, Sendable {
        public var cpuCount: Int
        public var memorySize: UInt64
    }

    public static func resolve(cpuCount: Int, memorySize: UInt64, limits: Limits) -> Resolved {
        let mebibyte: UInt64 = 1 << 20
        let roundedMemory = (memorySize + mebibyte - 1) / mebibyte * mebibyte
        return Resolved(
            cpuCount: min(max(cpuCount, limits.minimumCPUCount), limits.maximumCPUCount),
            memorySize: min(max(roundedMemory, limits.minimumMemorySize), limits.maximumMemorySize))
    }
}
