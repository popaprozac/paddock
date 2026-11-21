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
    ///
    /// With `keepingSavedState`, the clone also gets the source's saved state and keeps its
    /// machine identifier and MAC address, because the saved memory still holds that identity.
    /// Such clones can't run at the same time as each other.
    @discardableResult
    public static func clone(
        _ source: VMBundle, to destination: VMBundle, keepingSavedState: Bool = false
    ) throws -> VMConfig {
        guard source.exists else {
            throw PaddockError("no VM '\(source.name)' at \(source.url.path)")
        }
        if keepingSavedState, !FileManager.default.fileExists(atPath: source.savedStateURL.path) {
            throw PaddockError("VM '\(source.name)' has no saved state")
        }
        let lock = try BundleLock(bundle: source)
        defer { withExtendedLifetime(lock) {} }
        let staging = try StagingArea(for: destination)

        var config = try source.readConfig()
        try cloneFile(source.diskURL, to: staging.bundle.diskURL)
        if !config.isMac {
            try cloneFile(source.efiVariablesURL, to: staging.bundle.efiVariablesURL)
        } else {
            try cloneFile(source.auxiliaryStorageURL, to: staging.bundle.auxiliaryStorageURL)
        }

        if keepingSavedState {
            try cloneFile(source.savedStateURL, to: staging.bundle.savedStateURL)
        } else {
            config.machineIdentifier = !config.isMac
                ? VZGenericMachineIdentifier().dataRepresentation : VZMacMachineIdentifier().dataRepresentation
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
        }
        try staging.bundle.writeConfig(config)

        try staging.commit()
        return config
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
