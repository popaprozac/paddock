import Foundation
import Virtualization

/// Creates a VM bundle and installs macOS into it from a local restore image.
@MainActor
public enum MacOSInstall {
    public struct Request: Sendable {
        public var image: LocalRestoreImage
        public var cpuCount: Int
        public var memorySize: UInt64
        public var diskSize: UInt64
        public var display: VMConfig.Display

        public init(image: LocalRestoreImage, cpuCount: Int, memorySize: UInt64, diskSize: UInt64,
                    display: VMConfig.Display = .standard) {
            self.image = image
            self.cpuCount = cpuCount
            self.memorySize = memorySize
            self.diskSize = diskSize
            self.display = display
        }
    }

    /// Installs macOS into a new bundle. The work happens in a hidden staging directory next to
    /// the bundle, which is renamed into place only when the install succeeds.
    /// `progress` receives the installer's fraction complete about once a second.
    public static func install(
        _ request: Request,
        into bundle: VMBundle,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> VMConfig {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: bundle.url.path) else {
            throw PaddockError("VM '\(bundle.name)' already exists at \(bundle.url.path)")
        }
        let staging = VMBundle(url: bundle.url.deletingLastPathComponent()
            .appendingPathComponent(".\(bundle.name).installing", isDirectory: true))
        try? fileManager.removeItem(at: staging.url)
        try fileManager.createDirectory(at: staging.url, withIntermediateDirectories: true)

        do {
            let config = try createFiles(for: request, in: staging)
            try await runInstaller(bundle: staging, config: config, imageURL: request.image.url, progress: progress)
            try fileManager.moveItem(at: staging.url, to: bundle.url)
            return config
        } catch {
            try? fileManager.removeItem(at: staging.url)
            throw error
        }
    }

    static func createFiles(for request: Request, in bundle: VMBundle) throws -> VMConfig {
        // A sparse file: it reports the full size but only takes the space the guest writes.
        guard FileManager.default.createFile(atPath: bundle.diskURL.path, contents: nil) else {
            throw PaddockError("can't create \(bundle.diskURL.path)")
        }
        let disk = try FileHandle(forWritingTo: bundle.diskURL)
        try disk.truncate(atOffset: request.diskSize)
        try disk.close()

        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: request.image.hardwareModel) else {
            throw PaddockError("the restore image reported an unreadable hardware model")
        }
        do {
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [])
        } catch {
            throw PaddockError("can't create auxiliary storage: \(error.localizedDescription)")
        }

        let config = VMConfig(
            hardwareModel: request.image.hardwareModel,
            machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
            macAddress: VZMACAddress.randomLocallyAdministered().string,
            cpuCount: request.cpuCount,
            memorySize: request.memorySize,
            diskSize: request.diskSize,
            display: request.display,
            os: .init(version: request.image.version, build: request.image.build))
        try bundle.writeConfig(config)
        return config
    }

    static func runInstaller(
        bundle: VMBundle,
        config: VMConfig,
        imageURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let machine = VZVirtualMachine(configuration: try VMConfiguration.make(bundle: bundle, config: config))
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: imageURL)

        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress(installer.progress.fractionCompleted)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { reporter.cancel() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                installer.install { continuation.resume(with: $0) }
            }
        } catch {
            throw PaddockError("macOS install failed: \(error.localizedDescription)")
        }
        progress(1)
    }
}
