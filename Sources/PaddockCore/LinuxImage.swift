import CryptoKit
import Darwin
import Foundation
import Virtualization

/// Linux disk images for `paddock build`: Debian's genericcloud builds, fetched and checked, or a
/// disk you keep; and the Linux VM bundle made from one.
public enum LinuxImage {
    /// The Debian releases paddock builds from, by number, with the codename Debian files them under.
    public static let debianCodenames = [13: "trixie"]

    /// The latest genericcloud arm64 build of a Debian release and the SHA512SUMS listing it.
    public struct Debian: Equatable, Sendable {
        public let release: Int
        public let fileName: String
        public let url: URL
        public let sumsURL: URL

        public init?(release: Int) {
            guard let codename = LinuxImage.debianCodenames[release] else { return nil }
            self.release = release
            let folder = URL(string: "https://cloud.debian.org/images/cloud/\(codename)/latest/")!
            fileName = "debian-\(release)-genericcloud-arm64.tar.xz"
            url = folder.appendingPathComponent(fileName)
            sumsURL = folder.appendingPathComponent("SHA512SUMS")
        }
    }

    /// The SHA-512 a SHA512SUMS file lists for `file`, in lowercase hex; nil if it lists none.
    public static func sha512(of file: String, inSums text: String) -> String? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // sha512sum's binary mode marks the name with a leading '*'.
            guard fields.count == 2, fields[1] == file || fields[1] == "*" + file else { continue }
            let hash = fields[0].lowercased()
            guard hash.count == 128, hash.allSatisfy(\.isHexDigit) else { return nil }
            return hash
        }
        return nil
    }

    /// The SHA-512 of the file at `url`, in lowercase hex, read a megabyte at a time.
    public static func sha512(ofFileAt url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA512()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The latest build of `debian`, from the cache in `folder` if it is still Debian's latest,
    /// else downloaded there. Either way it is checked against Debian's SHA512SUMS, fetched over
    /// HTTPS each time, since the latest build changes. `progress` gets bytes written and expected.
    public static func fetch(
        _ debian: Debian, into folder: URL, progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: debian.sumsURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PaddockError("can't fetch \(debian.sumsURL.absoluteString): HTTP \(http.statusCode)")
        }
        guard let expected = sha512(of: debian.fileName, inSums: String(decoding: data, as: UTF8.self)) else {
            throw PaddockError("\(debian.sumsURL.absoluteString) doesn't list \(debian.fileName)")
        }
        let cached = folder.appendingPathComponent(debian.fileName)
        if FileManager.default.fileExists(atPath: cached.path) {
            if try sha512(ofFileAt: cached) == expected { return cached }
            try FileManager.default.removeItem(at: cached)  // an older build, or a damaged file
        }
        try await RestoreImages.download(debian.url, to: cached, progress: progress)
        guard try sha512(ofFileAt: cached) == expected else {
            try? FileManager.default.removeItem(at: cached)
            throw PaddockError("the download of \(debian.fileName) doesn't match Debian's SHA512SUMS; it was deleted")
        }
        return cached
    }

    /// Makes a new Linux VM bundle at `bundle` from `image`: a `.tar.xz` holding `disk.raw`, as
    /// Debian publishes its cloud images, or a raw disk image. The disk is copied in, grown to
    /// `diskSize` bytes, and given an EFI variable store and a fresh identity. The bundle appears
    /// only once it is complete.
    @discardableResult
    public static func makeBundle(_ bundle: VMBundle, from image: URL, cpuCount: Int, memorySize: UInt64,
                                  diskSize: UInt64) throws -> VMConfig {
        let staging = try StagingArea(for: bundle)
        let disk = staging.bundle.diskURL
        if image.lastPathComponent.hasSuffix(".tar.xz") {
            try extractDisk(from: image, to: disk)
        } else {
            // A clone on the same APFS volume, a copy elsewhere.
            try FileManager.default.copyItem(at: image, to: disk)
        }
        let size = try FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? UInt64 ?? 0
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
        let config = VMConfig(
            kind: .linux, hardwareModel: Data(), machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
            macAddress: VZMACAddress.randomLocallyAdministered().string, cpuCount: cpuCount, memorySize: memorySize,
            diskSize: diskSize)
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
