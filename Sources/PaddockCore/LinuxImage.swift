import CryptoKit
import Darwin
import Foundation
import Virtualization

/// Linux disk images for `paddock build`: Debian's and Ubuntu's cloud builds, fetched and checked,
/// or a disk you keep; and the Linux VM bundle made from one.
public enum LinuxImage {
    /// The Debian releases paddock builds from, by number, with the codename Debian files them under.
    public static let debianCodenames = [13: "trixie"]

    /// The latest arm64 build of a Debian release, in one of the variants Debian publishes, and
    /// the SHA512SUMS listing it.
    public struct Debian: Equatable, Sendable {
        /// genericcloud's kernel drives only what a cloud VM needs; generic's full kernel also
        /// drives a screen and USB input, which a desktop needs.
        public enum Variant: String, CaseIterable, Sendable {
            case genericcloud, generic
        }

        public let release: Int
        public let variant: Variant
        public let fileName: String
        public let url: URL
        public let sumsURL: URL

        public init?(release: Int, variant: Variant = .genericcloud) {
            guard let codename = LinuxImage.debianCodenames[release] else { return nil }
            self.release = release
            self.variant = variant
            let folder = URL(string: "https://cloud.debian.org/images/cloud/\(codename)/latest/")!
            fileName = "debian-\(release)-\(variant.rawValue)-arm64.tar.xz"
            url = folder.appendingPathComponent(fileName)
            sumsURL = folder.appendingPathComponent("SHA512SUMS")
        }
    }

    /// The Ubuntu releases paddock builds from, by number, with the codename Ubuntu files them under.
    public static let ubuntuCodenames = ["26.04": "resolute"]

    /// The latest arm64 server cloud image of an Ubuntu release, a qcow2 disk, and the SHA256SUMS
    /// listing it.
    public struct Ubuntu: Equatable, Sendable {
        public let release: String
        public let url: URL
        public let sumsURL: URL

        public init?(release: String) {
            guard let codename = LinuxImage.ubuntuCodenames[release] else { return nil }
            self.release = release
            let folder = URL(string: "https://cloud-images.ubuntu.com/releases/\(codename)/release/")!
            url = folder.appendingPathComponent("ubuntu-\(release)-server-cloudimg-arm64.img")
            sumsURL = folder.appendingPathComponent("SHA256SUMS")
        }
    }

    /// The hash a downloaded image must match.
    public struct Checksum: Equatable, Sendable {
        public enum Algorithm: String, Sendable {
            case sha256, sha512

            public var hexLength: Int { self == .sha256 ? 64 : 128 }
        }

        public let algorithm: Algorithm
        public let hex: String  // lowercase

        /// Nil unless `hex` is the algorithm's length of hex digits.
        public init?(_ algorithm: Algorithm, _ hex: String) {
            let hex = hex.lowercased()
            guard hex.count == algorithm.hexLength, hex.allSatisfy(\.isHexDigit) else { return nil }
            self.algorithm = algorithm
            self.hex = hex
        }
    }

    /// Whether a file's name says it's an image `makeBundle` takes: a `.tar.xz` holding
    /// `disk.raw`, a `.raw` disk, or a `.qcow2` or `.img`, which `makeBundle` reads as qcow2 or
    /// raw by what the file holds.
    public static func isDiskFileName(_ name: String) -> Bool {
        [".tar.xz", ".raw", ".qcow2", ".img"].contains { name.hasSuffix($0) }
    }

    /// The hash a SHA512SUMS or SHA256SUMS file lists for `file`; nil if it lists none.
    public static func checksum(of file: String, inSums text: String, _ algorithm: Checksum.Algorithm) -> Checksum? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // sha512sum's binary mode marks the name with a leading '*'.
            guard fields.count == 2, fields[1] == file || fields[1] == "*" + file else { continue }
            return Checksum(algorithm, String(fields[0]))
        }
        return nil
    }

    /// The hash of the file at `url`, in lowercase hex, read a megabyte at a time.
    public static func hash(ofFileAt url: URL, _ algorithm: Checksum.Algorithm) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func hex(_ hasher: inout some HashFunction) throws -> String {
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            return try hex(&hasher)
        case .sha512:
            var hasher = SHA512()
            return try hex(&hasher)
        }
    }

    /// The latest build at `url`, such as Debian's or Ubuntu's, from the cache in `folder` if it is
    /// still the one `sums` lists, else downloaded there. Either way it is checked against `sums`,
    /// fetched over HTTPS each time, since the latest build changes. `progress` gets bytes written
    /// and expected.
    public static func fetchLatest(
        _ url: URL, listedIn sums: URL, _ algorithm: Checksum.Algorithm, into folder: URL,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: sums)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaddockError("can't fetch \(sums.absoluteString): HTTP \(http.statusCode)")
        }
        let file = url.lastPathComponent
        guard let expected = checksum(of: file, inSums: String(decoding: data, as: UTF8.self), algorithm) else {
            throw PaddockError("\(sums.absoluteString) doesn't list \(file)")
        }
        // Kept by name: the latest build replaces the one before it.
        return try await fetch(url, matching: expected, to: folder.appendingPathComponent(file), progress: progress)
    }

    /// The image at `url`, which must match `checksum`, from the cache in `folder` or downloaded
    /// there. Kept by its hash, so a file is downloaded once however many image files name it.
    public static func fetch(
        _ url: URL, matching checksum: Checksum, into folder: URL,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws -> URL {
        let cached = folder.appendingPathComponent("\(checksum.algorithm.rawValue)-\(checksum.hex)", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        return try await fetch(url, matching: checksum, to: cached, progress: progress)
    }

    /// `cached` if it matches `checksum`, else a fresh download there that must.
    static func fetch(
        _ url: URL, matching checksum: Checksum, to cached: URL,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: cached.path) {
            if try hash(ofFileAt: cached, checksum.algorithm) == checksum.hex { return cached }
            try FileManager.default.removeItem(at: cached)  // an older build, or a damaged file
        }
        try await RestoreImages.download(url, to: cached, progress: progress)
        guard try hash(ofFileAt: cached, checksum.algorithm) == checksum.hex else {
            try? FileManager.default.removeItem(at: cached)
            throw PaddockError("the download of \(url.lastPathComponent) doesn't match its \(checksum.algorithm.rawValue), "
                + "so it was deleted")
        }
        return cached
    }

    /// Makes a new Linux VM bundle at `bundle` from `image`: a `.tar.xz` holding `disk.raw`, as
    /// Debian publishes its cloud images, a qcow2 image, as Ubuntu publishes them, or a raw disk
    /// image. The disk is copied in as a raw disk, grown to `diskSize` bytes, and given an EFI
    /// variable store and a fresh identity. The bundle appears only once it is complete.
    @discardableResult
    public static func makeBundle(_ bundle: VMBundle, from image: URL, cpuCount: Int, memorySize: UInt64,
                                  diskSize: UInt64, rosetta: Bool = false) throws -> VMConfig {
        let staging = try StagingArea(for: bundle)
        let disk = staging.bundle.diskURL
        if image.lastPathComponent.hasSuffix(".tar.xz") {
            try extractDisk(from: image, to: disk)
        } else if QCOW2.isImage(at: image) {
            try QCOW2.convert(image, to: disk)
        } else {
            // A clone on the same APFS volume, a copy elsewhere; of the file a link points at, since
            // a copied link would have the VM write to that file.
            try FileManager.default.copyItem(at: image.resolvingSymlinksInPath(), to: disk)
        }
        // The item itself, not what it may point at: a tarball's disk.raw can be a link.
        let attributes = try FileManager.default.attributesOfItem(atPath: disk.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PaddockError("\(image.lastPathComponent)'s disk isn't a regular file")
        }
        let size = attributes[.size] as? UInt64 ?? 0
        guard size <= diskSize else {
            throw PaddockError("\(image.lastPathComponent)'s disk is \(ByteFormat.gigabytes(Int64(size))), more than "
                + "the \(diskSize >> 30) GB vm.disk asks for")
        }
        // Growing only adds zeros at the end: cloud-init grows the guest's partition into them.
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: diskSize)
        try handle.close()
        do {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: staging.bundle.efiVariablesURL)
        } catch {
            throw PaddockError("can't create the EFI variable store: \(error.localizedDescription)")
        }
        var config = VMConfig(
            kind: .linux, hardwareModel: Data(), machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
            macAddress: VZMACAddress.randomLocallyAdministered().string, cpuCount: cpuCount, memorySize: memorySize,
            diskSize: diskSize)
        config.rosetta = rosetta ? true : nil
        try staging.bundle.writeConfig(config)
        try staging.commit()
        return config
    }

    /// Extracts `disk.raw`, and nothing else, from a cloud image's tarball to `destination`.
    static func extractDisk(from archive: URL, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", folder.path, "disk.raw"]
        let errors = Pipe()
        tar.standardError = errors
        tar.standardOutput = FileHandle.nullDevice
        try tar.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tar.waitUntilExit()
        let extracted = folder.appendingPathComponent("disk.raw")
        guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: extracted.path) else {
            let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PaddockError("\(archive.lastPathComponent) holds no disk.raw to extract"
                + (reason.isEmpty ? "" : ": \(reason.prefix(300))"))
        }
        try FileManager.default.moveItem(at: extracted, to: destination)
    }
}
