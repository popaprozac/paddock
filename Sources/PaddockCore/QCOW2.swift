import Compression
import Foundation

/// qcow2 disk images, as Ubuntu publishes its cloud images, read into the raw disks
/// Virtualization takes. Reads what cloud images use, versions 2 and 3 with plain and
/// deflate-compressed clusters, and refuses the rest: backing files, encryption, an external data
/// file, extended L2 entries and zstd compression.
enum QCOW2 {
    /// Whether the file at `url` starts with qcow2's magic, "QFI" and 0xfb.
    static func isImage(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB])
    }

    /// Writes the disk the qcow2 image at `source` holds to `destination`, as a sparse raw disk:
    /// clusters the image doesn't hold, or that hold only zeros, are left as holes.
    static func convert(_ source: URL, to destination: URL) throws {
        let name = source.lastPathComponent
        let damaged = PaddockError("\(name) is a damaged qcow2 image")
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        func read(_ count: Int, at offset: UInt64, exactly: Bool = true) throws -> Data {
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard exactly ? data.count == count : !data.isEmpty else { throw damaged }
            return data
        }

        let header = try read(112, at: 0)
        guard header.bigEndian(UInt32.self, at: 0) == 0x5146_49FB else { throw PaddockError("\(name) isn't a qcow2 image") }
        let version = header.bigEndian(UInt32.self, at: 4)
        guard version == 2 || version == 3 else {
            throw PaddockError("\(name) is qcow2 version \(version), and paddock reads versions 2 and 3")
        }
        guard header.bigEndian(UInt64.self, at: 8) == 0 else {
            throw PaddockError("\(name) needs a backing file; convert it to a raw disk that stands alone")
        }
        guard header.bigEndian(UInt32.self, at: 32) == 0 else { throw PaddockError("\(name) is encrypted") }
        if version == 3 {
            // Bit 0 marks an image that wasn't closed cleanly, which leaves its reference counts in
            // doubt but not its data; bit 3 says the header names the compression, zlib (0) here.
            let incompatible = header.bigEndian(UInt64.self, at: 72)
            let compression = header.bigEndian(UInt32.self, at: 100) > 104 ? header[104] : 0
            guard incompatible & ~0b1001 == 0, compression == 0 else {
                throw PaddockError("\(name) needs qcow2 features paddock doesn't read; convert it to a raw disk")
            }
        }
        let clusterBits = header.bigEndian(UInt32.self, at: 20)
        let size = header.bigEndian(UInt64.self, at: 24)
        guard (9...21).contains(clusterBits) else { throw damaged }
        let clusterSize = 1 << Int(clusterBits)
        let entriesPerTable = clusterSize / 8
        let bytesPerTable = UInt64(clusterSize) * UInt64(entriesPerTable)
        let tables = Int((size + bytesPerTable - 1) / bytesPerTable)
        // The L1 table is read whole: a size that makes it huge is damage, not a disk.
        guard tables <= Int(header.bigEndian(UInt32.self, at: 36)), tables <= 4 << 20 else { throw damaged }
        let l1 = try read(tables * 8, at: header.bigEndian(UInt64.self, at: 40))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: size)
        let offsetBits: UInt64 = 0x00FF_FFFF_FFFF_FE00  // bits 9 to 55 of an L1 or plain L2 entry
        let compressedOffsetBits = 62 - (UInt64(clusterBits) - 8)
        for table in 0..<tables {
            let l2Offset = l1.bigEndian(UInt64.self, at: table * 8) & offsetBits
            guard l2Offset != 0 else { continue }  // a stretch of the disk with no clusters
            let l2 = try read(clusterSize, at: l2Offset)
            for index in 0..<entriesPerTable {
                let guestOffset = (UInt64(table) * UInt64(entriesPerTable) + UInt64(index)) << UInt64(clusterBits)
                guard guestOffset < size else { break }
                let entry = l2.bigEndian(UInt64.self, at: index * 8)
                let cluster: Data
                if entry & (1 << 62) != 0 {
                    // Compressed: the offset, then how many more 512-byte sectors the data runs on.
                    let offset = entry & ((1 << compressedOffsetBits) - 1)
                    let sectors = (entry >> compressedOffsetBits) & ((1 << (UInt64(clusterBits) - 8)) - 1) + 1
                    let compressed = try read(Int(sectors * 512 - offset % 512), at: offset, exactly: false)
                    guard let inflated = inflate(compressed, to: clusterSize) else { throw damaged }
                    cluster = inflated
                } else {
                    let offset = entry & offsetBits
                    guard offset != 0, entry & 1 == 0 else { continue }  // not there, or all zeros
                    cluster = try read(clusterSize, at: offset)
                }
                guard cluster.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { continue }
                try output.seek(toOffset: guestOffset)
                try output.write(contentsOf: cluster.prefix(Int(min(UInt64(clusterSize), size - guestOffset))))
            }
        }
    }

    /// A compressed cluster's raw deflate data, inflated to the whole cluster it must fill; nil if
    /// it doesn't.
    static func inflate(_ compressed: Data, to size: Int) -> Data? {
        var cluster = Data(count: size)
        let written = cluster.withUnsafeMutableBytes { out in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        return written == size ? cluster : nil
    }
}

extension Data {
    /// The big-endian integer at `offset` bytes in.
    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        self[startIndex + offset..<startIndex + offset + MemoryLayout<T>.size].reduce(0) { $0 << 8 | T($1) }
    }
}
