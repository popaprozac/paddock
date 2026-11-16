import Foundation

public enum ByteFormat {
    /// Decimal gigabytes with one decimal place, the way Finder and Apple's download pages count.
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
