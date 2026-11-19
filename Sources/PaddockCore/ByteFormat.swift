import Foundation

public enum ByteFormat {
    /// Decimal gigabytes with one decimal place, the way Finder and Apple's download pages count.
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Binary gigabytes with one decimal place, the way Activity Monitor and About This Mac count
    /// memory, so a 36 GB Mac reads 36.0 GB.
    public static func memory(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }
}
