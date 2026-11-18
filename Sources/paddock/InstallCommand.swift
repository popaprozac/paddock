import ArgumentParser
import Foundation
import PaddockCore

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the latest supported macOS and install it into a new VM.",
        discussion: """
            Restore images are cached in $PADDOCK_HOME/cache/ipsw (default ~/.paddock). \
            Afterwards, finish Setup Assistant once with 'paddock run <name>'; that VM becomes \
            the golden image that 'clone' and 'bench' copy.
            """)

    @Argument(help: "Name of the new VM.")
    var name: String

    @Option(help: ArgumentHelp("Install from this IPSW file instead of downloading one.", valueName: "path"))
    var ipsw: String?

    @Option(help: "Virtual CPUs.")
    var cpus: Int = VMSizing.defaultCPUCount

    @Option(help: "Memory in GB.")
    var memory: UInt64 = VMSizing.defaultMemorySize >> 30

    @Option(name: .customLong("disk-size"), help: "Disk size in GB. The disk is sparse, so unused space costs nothing.")
    var diskSize: UInt64 = VMSizing.defaultDiskSize >> 30

    func validate() throws {
        try BundleName.validate(name)
        guard cpus > 0 else { throw ValidationError("--cpus must be at least 1") }
        guard memory > 0 else { throw ValidationError("--memory must be at least 1") }
        guard diskSize >= 32 else { throw ValidationError("--disk-size must be at least 32 GB for macOS") }
    }

    func run() async throws {
        try await Self.install(name: name, ipsw: ipsw, cpus: cpus, memory: memory, diskSize: diskSize)
        print("Next: paddock run \(name)   (finish Setup Assistant once; this becomes the golden image)")
        print("  or, with macOS 27: paddock run \(name) --provision <account>   (creates the account, no Setup Assistant)")
    }

    /// Installs macOS into a new VM named `name`, from `ipsw` or the latest this Mac supports,
    /// downloaded into the cache if it isn't there; memory and disk in GB. `build` uses it too.
    static func install(name: String, ipsw: String?, cpus: Int, memory: UInt64, diskSize: UInt64) async throws {
        let home = PaddockHome.fromEnvironment()
        let bundle = try home.bundle(named: name)
        guard !FileManager.default.fileExists(atPath: bundle.url.path) else {
            throw PaddockError("VM '\(name)' already exists at \(bundle.url.path)")
        }

        // Ctrl-C would otherwise leave a hidden, partly written multi-GB disk in the vms directory.
        let interrupt = await MainActor.run {
            onInterrupt {
                print("\nInterrupted; removing the partial install.")
                StagingArea.removeAllInProgress()
                Darwin.exit(130)
            }
        }
        defer { interrupt.cancel() }

        let imageURL = try await resolveRestoreImage(ipsw, home: home)
        let image = try await RestoreImages.load(from: imageURL)
        let sizing = VMSizing.resolve(cpuCount: cpus, memorySize: memory << 30, limits: .forImage(image))
        let request = MacOSInstall.Request(
            image: image, cpuCount: sizing.cpuCount, memorySize: sizing.memorySize, diskSize: diskSize << 30)

        print("""
            Installing macOS \(image.version) (\(image.build)) into '\(name)': \
            \(sizing.cpuCount) CPUs, \(sizing.memorySize >> 30) GB memory, \(diskSize) GB sparse disk
            """)
        let started = ContinuousClock.now
        let line = ProgressLine("Installing")
        _ = try await MacOSInstall.install(request, into: bundle) { line.update(fraction: $0) }
        line.finish()

        let minutes = Double((ContinuousClock.now - started).components.seconds) / 60
        print("Installed '\(name)' in \(String(format: "%.1f", minutes)) min at \(bundle.url.path)")
    }

    private static func resolveRestoreImage(_ ipsw: String?, home: PaddockHome) async throws -> URL {
        if let ipsw {
            return URL(fileURLWithPath: (ipsw as NSString).expandingTildeInPath)
        }
        print("Looking up the latest macOS this Mac supports...")
        let remote = try await RestoreImages.fetchLatestSupported()
        let cached = remote.cachedFileURL(in: home.ipswCacheDirectory)
        if FileManager.default.fileExists(atPath: cached.path) {
            print("Using cached macOS \(remote.version) (\(remote.build)): \(cached.path)")
            return cached
        }
        print("Downloading macOS \(remote.version) (\(remote.build)) from \(remote.url.absoluteString)")
        let line = ProgressLine("Downloading")
        try await RestoreImages.download(remote, to: cached) { written, expected in
            guard expected > 0 else { return }
            line.update(fraction: Double(written) / Double(expected),
                        detail: "\(ByteFormat.gigabytes(written)) of \(ByteFormat.gigabytes(expected))")
        }
        line.finish()
        return cached
    }
}
