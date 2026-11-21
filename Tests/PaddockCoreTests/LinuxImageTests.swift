import Foundation
import Testing
import Virtualization
@testable import PaddockCore

@Suite struct LinuxImageTests {
    @Test func findsDebiansLatestBuildOfAKnownRelease() throws {
        let debian = try #require(LinuxImage.Debian(release: 13))
        #expect(debian.url.absoluteString
            == "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.tar.xz")
        #expect(debian.sumsURL.absoluteString == "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS")
        #expect(LinuxImage.Debian(release: 12) == nil)
        #expect(ImageFile.debianReleases == [13])
    }

    @Test func readsAFilesHashFromSHA512SUMS() {
        let hash = String(repeating: "ab", count: 64)
        let sums = """
            \(String(repeating: "cd", count: 64))  debian-13-genericcloud-amd64.tar.xz
            \(hash.uppercased())  debian-13-genericcloud-arm64.tar.xz
            """
        #expect(LinuxImage.sha512(of: "debian-13-genericcloud-arm64.tar.xz", inSums: sums) == hash)
        #expect(LinuxImage.sha512(of: "disk.raw", inSums: "\(hash) *disk.raw") == hash)
        #expect(LinuxImage.sha512(of: "other.tar.xz", inSums: sums) == nil)
        #expect(LinuxImage.sha512(of: "short.tar.xz", inSums: "abc123  short.tar.xz") == nil)
    }

    @Test func hashesAFile() throws {
        let tmp = try TemporaryDirectory()
        let file = tmp.url.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try LinuxImage.hash(ofFileAt: file, .sha512) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
            + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        #expect(try LinuxImage.hash(ofFileAt: file, .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// An image already in the cache under its hash comes from there, with nothing downloaded:
    /// the URL can't be reached.
    @Test func takesAnImageByURLFromTheCacheWhenItMatches() async throws {
        let tmp = try TemporaryDirectory()
        let checksum = try #require(LinuxImage.Checksum(.sha256, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        let cached = tmp.url.appendingPathComponent("sha256-\(checksum.hex)/abc.raw")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: cached)
        let url = URL(string: "https://images.invalid/abc.raw")!
        #expect(try await LinuxImage.fetch(url, matching: checksum, into: tmp.url) { _, _ in } == cached)

        // A cached file that doesn't match is deleted, and the download it then needs fails here.
        try Data("abd".utf8).write(to: cached)
        await #expect(throws: (any Error).self) { try await LinuxImage.fetch(url, matching: checksum, into: tmp.url) { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: cached.path))
    }

    @Test func checksumsNeedTheirAlgorithmsLength() {
        #expect(LinuxImage.Checksum(.sha256, String(repeating: "a", count: 64)) != nil)
        #expect(LinuxImage.Checksum(.sha256, String(repeating: "a", count: 128)) == nil)
        #expect(LinuxImage.Checksum(.sha512, String(repeating: "g", count: 128)) == nil)
    }

    /// A small disk with recognizable bytes, as disk.raw in a folder of its own.
    func writeDisk(in tmp: TemporaryDirectory) throws -> URL {
        let folder = tmp.url.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let disk = folder.appendingPathComponent("disk.raw")
        try Data(repeating: 0x5a, count: 1 << 20).write(to: disk)
        return disk
    }

    func tarball(of disk: URL, named name: String = "image.tar.xz") throws -> URL {
        let archive = disk.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", disk.deletingLastPathComponent().path, disk.lastPathComponent]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return archive
    }

    func expectLinuxBundle(_ bundle: VMBundle, diskSize: UInt64, config: VMConfig) throws {
        let disk = try Data(contentsOf: bundle.diskURL)
        #expect(UInt64(disk.count) == diskSize)
        #expect(disk.prefix(1 << 20) == Data(repeating: 0x5a, count: 1 << 20))
        #expect(disk.suffix(16) == Data(count: 16))
        #expect(FileManager.default.fileExists(atPath: bundle.efiVariablesURL.path))
        #expect(config.isLinux && config.cpuCount == 2 && config.memorySize == 2 << 30 && config.diskSize == diskSize)
        #expect(VZGenericMachineIdentifier(dataRepresentation: config.machineIdentifier) != nil)
        #expect(try bundle.readConfig() == config)
    }

    @Test func makesABundleFromACloudImageTarball() throws {
        let tmp = try TemporaryDirectory()
        let archive = try tarball(of: try writeDisk(in: tmp))
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("vms/debian"))
        let config = try LinuxImage.makeBundle(bundle, from: archive, cpuCount: 2, memorySize: 2 << 30, diskSize: 4 << 20)
        try expectLinuxBundle(bundle, diskSize: 4 << 20, config: config)
    }

    @Test func keepsWhetherTheImageUsesRosetta() throws {
        let tmp = try TemporaryDirectory()
        let disk = try writeDisk(in: tmp)
        let plain = try LinuxImage.makeBundle(VMBundle(url: tmp.url.appendingPathComponent("vms/a")), from: disk,
                                              cpuCount: 2, memorySize: 2 << 30, diskSize: 4 << 20)
        let rosetta = try LinuxImage.makeBundle(VMBundle(url: tmp.url.appendingPathComponent("vms/b")), from: disk,
                                                cpuCount: 2, memorySize: 2 << 30, diskSize: 4 << 20, rosetta: true)
        #expect(plain.rosetta == nil && rosetta.rosetta == true)
    }

    @Test func makesABundleFromARawDisk() throws {
        let tmp = try TemporaryDirectory()
        let disk = try writeDisk(in: tmp)
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("vms/debian"))
        let config = try LinuxImage.makeBundle(bundle, from: disk, cpuCount: 2, memorySize: 2 << 30, diskSize: 4 << 20)
        try expectLinuxBundle(bundle, diskSize: 4 << 20, config: config)
        #expect(FileManager.default.fileExists(atPath: disk.path))  // the image itself is left as it was
    }

    @Test func leavesNoBundleWhenTheImageWontFit() throws {
        let tmp = try TemporaryDirectory()
        let disk = try writeDisk(in: tmp)
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("vms/debian"))
        let error = #expect(throws: PaddockError.self) {
            try LinuxImage.makeBundle(bundle, from: disk, cpuCount: 2, memorySize: 2 << 30, diskSize: 512 << 10)
        }
        #expect(error?.message.contains("more than") == true)
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
        #expect(!FileManager.default.fileExists(atPath: StagingArea.stagingURL(for: bundle).path))
    }

    @Test func refusesATarballWithoutADisk() throws {
        let tmp = try TemporaryDirectory()
        let other = tmp.url.appendingPathComponent("image/notes.txt")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: other)
        let archive = try tarball(of: other)
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("vms/debian"))
        let error = #expect(throws: PaddockError.self) {
            try LinuxImage.makeBundle(bundle, from: archive, cpuCount: 2, memorySize: 2 << 30, diskSize: 4 << 20)
        }
        #expect(error?.message.contains("holds no disk.raw") == true)
        #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
    }
}
