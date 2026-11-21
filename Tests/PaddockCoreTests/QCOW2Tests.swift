import Compression
import Foundation
import Testing
@testable import PaddockCore

@Suite struct QCOW2Tests {
    static let cluster = 4096
    static let plain = Data((0..<cluster).map { UInt8($0 % 251) })
    static let squeezable = Data(String(repeating: "paddock ", count: cluster / 8).utf8)
    static let last = Data(repeating: 0xAB, count: cluster)
    /// Four clusters and three quarters of one: the last cluster is cut short by the disk's size.
    static let size = 4 * cluster + 3 * cluster / 4

    /// A version 3 image of 4 KiB clusters, laid out as qemu-img writes one: the header, the L1
    /// table, one L2 table, then data. The disk is a plain cluster, a hole, a cluster marked as
    /// zeros, a compressed cluster and a plain one past the disk's end.
    static func image() -> Data {
        var image = Data(count: 6 * cluster)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.bigEndian) { image.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }
        put(UInt32(0x5146_49FB), at: 0)
        put(UInt32(3), at: 4)
        put(UInt32(12), at: 20)  // cluster bits
        put(UInt64(size), at: 24)
        put(UInt32(1), at: 36)  // L1 entries
        put(UInt64(cluster), at: 40)  // L1 offset
        put(UInt32(4), at: 96)  // refcount order
        put(UInt32(112), at: 100)  // header length
        let copied: UInt64 = 1 << 63
        put(UInt64(2 * cluster) | copied, at: cluster)
        let compressed = deflate(squeezable)
        let compressedOffset = 4 * cluster
        let extraSectors = UInt64((compressed.count + 511) / 512 - 1)
        let l2 = 2 * cluster
        put(UInt64(3 * cluster) | copied, at: l2)
        put(UInt64(1), at: l2 + 16)  // all zeros
        put(1 << 62 | extraSectors << 58 | UInt64(compressedOffset), at: l2 + 24)
        put(UInt64(5 * cluster) | copied, at: l2 + 32)
        image.replaceSubrange(3 * cluster..<4 * cluster, with: plain)
        image.replaceSubrange(compressedOffset..<compressedOffset + compressed.count, with: compressed)
        image.replaceSubrange(5 * cluster..<6 * cluster, with: last)
        return image
    }

    static func deflate(_ data: Data) -> Data {
        var out = Data(count: data.count)
        let count = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(count)
    }

    func write(_ image: Data, in tmp: TemporaryDirectory, named name: String = "ubuntu.img") throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try image.write(to: url)
        return url
    }

    @Test func convertsAnImageToARawDisk() throws {
        let tmp = try TemporaryDirectory()
        let source = try write(Self.image(), in: tmp)
        #expect(QCOW2.isImage(at: source))
        let disk = tmp.url.appendingPathComponent("disk.raw")
        try QCOW2.convert(source, to: disk)
        let zeros = Data(count: Self.cluster)
        let want = Self.plain + zeros + zeros + Self.squeezable + Self.last.prefix(3 * Self.cluster / 4)
        #expect(try Data(contentsOf: disk) == want)
    }

    @Test func makesABundleFromAnImage() throws {
        let tmp = try TemporaryDirectory()
        let source = try write(Self.image(), in: tmp)
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("vms/ubuntu"))
        let config = try LinuxImage.makeBundle(bundle, from: source, cpuCount: 2, memorySize: 2 << 30, diskSize: 1 << 20)
        let disk = try Data(contentsOf: bundle.diskURL)
        #expect(disk.count == 1 << 20 && config.diskSize == 1 << 20)
        #expect(disk.prefix(Self.cluster) == Self.plain)
        #expect(disk[3 * Self.cluster..<4 * Self.cluster] == Self.squeezable)
    }

    @Test func refusesWhatItDoesntRead() throws {
        let tmp = try TemporaryDirectory()
        func failure(_ change: (inout Data) -> Void) throws -> String? {
            var image = Self.image()
            change(&image)
            let source = try write(image, in: tmp)
            return #expect(throws: PaddockError.self) {
                try QCOW2.convert(source, to: tmp.url.appendingPathComponent("disk.raw"))
            }?.message
        }
        #expect(try failure { $0[15] = 0x70 } == "ubuntu.img needs a backing file; convert it to a raw disk that stands alone")
        #expect(try failure { $0[35] = 1 } == "ubuntu.img is encrypted")
        #expect(try failure { $0[79] = 0x10 }  // extended L2 entries
            == "ubuntu.img needs qcow2 features paddock doesn't read; convert it to a raw disk")
        #expect(try failure { $0[79] = 0x08; $0[104] = 1 }  // zstd
            == "ubuntu.img needs qcow2 features paddock doesn't read; convert it to a raw disk")
        #expect(try failure { $0[7] = 4 } == "ubuntu.img is qcow2 version 4, and paddock reads versions 2 and 3")
        #expect(try failure { $0.replaceSubrange(4 * Self.cluster..<4 * Self.cluster + 64, with: Data(count: 64)) }
            == "ubuntu.img is a damaged qcow2 image")
        #expect(try failure { $0 = $0.prefix(5 * Self.cluster) } == "ubuntu.img is a damaged qcow2 image")
    }

    @Test func tellsARawDiskFromAnImage() throws {
        let tmp = try TemporaryDirectory()
        #expect(!QCOW2.isImage(at: try write(Data(repeating: 0x5A, count: 4096), in: tmp, named: "disk.img")))
        #expect(!QCOW2.isImage(at: tmp.url.appendingPathComponent("missing.img")))
    }
}
