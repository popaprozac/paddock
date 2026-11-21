import Foundation
import Virtualization

/// Picks CPU and memory for a new VM: the user's request, raised to what the macOS image needs
/// and capped at what this host allows.
public enum VMSizing {
    public static let defaultCPUCount = 4
    public static let defaultMemorySize: UInt64 = 8 << 30
    public static let defaultDiskSize: UInt64 = 80 << 30

    /// What a running VM costs its host in memory: the guest's memory and Virtualization's own.
    /// A restored VM costs all of its memory at once, so serve's warm VMs do. shortcut: for macOS
    /// 1.7 times, measured on 8 GB macOS 27 VMs (10.7 to 13.6 GB once warm). For Linux 1.15 times,
    /// or 1.6 times with a desktop, measured on 4 GB VMs: restored, Debian 13 took 4.2 to 4.3 GB
    /// and Ubuntu 26.04 4.6 GB; after opening an app and reading its tree, Debian's Xfce took
    /// 4.5 GB and Ubuntu's GNOME 6.3 GB, the extra on the host's side. A cold-booted one took
    /// 0.45 GB idle, 0.82 GB with Xfce. Measure other sizes and long sessions before trusting it.
    public static func hostMemory(for memorySize: UInt64, linux: Bool = false, desktop: Bool = false) -> UInt64 {
        guard linux else { return memorySize * 17 / 10 }
        return desktop ? memorySize * 8 / 5 : memorySize * 23 / 20
    }

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

        /// What Virtualization.framework allows on this host, for images with no minimums of their own.
        public static var host: Limits {
            Limits(
                minimumCPUCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                maximumCPUCount: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                minimumMemorySize: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                maximumMemorySize: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
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
