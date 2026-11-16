import Darwin
import Foundation
import Virtualization

/// Copy-on-write clones of a VM bundle.
public enum VMClone {
    /// Clones `source` into `destination` with APFS `clonefile(2)` and gives the clone a fresh
    /// machine identifier and MAC address, so it can run alongside the source and other clones.
    ///
    /// The clone shares disk blocks with the source until either one writes, so it takes
    /// milliseconds and almost no space. It fails rather than falling back to a full copy when
    /// the destination is on another volume. The source is locked while cloning, so a VM that
    /// is running can't be cloned mid-write.
    @discardableResult
    public static func clone(_ source: VMBundle, to destination: VMBundle) throws -> VMConfig {
        let fileManager = FileManager.default
        guard source.exists else {
            throw PaddockError("no VM '\(source.name)' at \(source.url.path)")
        }
        guard !fileManager.fileExists(atPath: destination.url.path) else {
            throw PaddockError("VM '\(destination.name)' already exists at \(destination.url.path)")
        }
        let lock = try BundleLock(bundle: source)
        defer { withExtendedLifetime(lock) {} }

        let staging = VMBundle(url: destination.url.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.name).cloning", isDirectory: true))
        try? fileManager.removeItem(at: staging.url)
        try fileManager.createDirectory(at: staging.url, withIntermediateDirectories: true)

        do {
            try cloneFile(source.diskURL, to: staging.diskURL)
            try cloneFile(source.auxiliaryStorageURL, to: staging.auxiliaryStorageURL)

            var config = try source.readConfig()
            config.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            try staging.writeConfig(config)

            try fileManager.moveItem(at: staging.url, to: destination.url)
            return config
        } catch {
            try? fileManager.removeItem(at: staging.url)
            throw error
        }
    }

    static func cloneFile(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            let code = errno
            switch code {
            case EXDEV:
                throw PaddockError("can't clone across volumes; keep clones on the same APFS volume as '\(source.deletingLastPathComponent().lastPathComponent)'")
            case ENOTSUP:
                throw PaddockError("\(destination.deletingLastPathComponent().path) is not on APFS, which clones need")
            default:
                throw PaddockError("can't clone \(source.lastPathComponent): \(String(cString: strerror(code)))")
            }
        }
    }
}
