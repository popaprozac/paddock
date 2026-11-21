import Foundation
import PaddockCore

/// `paddock build <file>` for a Linux image: get the image, make the VM from its disk, boot it
/// once with the cloud-init seed, which creates the account and sets the image up, then once more
/// without it to run the steps and seal the image.
@MainActor
enum LinuxBuild {
    static let defaultMemoryGB: UInt64 = 4
    static let defaultDiskGB: UInt64 = 16

    static func run(_ plan: ImageBuild.Plan) async throws {
        let started = ContinuousClock.now
        let image = plan.image
        let home = PaddockHome.fromEnvironment()
        if image.rosetta {
            try VMConfiguration.checkRosetta()  // before a download that couldn't be used
        }
        let source = try await fetch(image.from, disk: plan.disk, home: home)
        let sizing = VMSizing.resolve(cpuCount: image.vm.cpus ?? VMSizing.defaultCPUCount,
                                      memorySize: UInt64(image.vm.memory.map(UInt64.init) ?? defaultMemoryGB) << 30,
                                      limits: .host)
        let diskGB = image.vm.disk.map(UInt64.init) ?? defaultDiskGB
        print("Making '\(plan.name)' from \(source.lastPathComponent): \(sizing.cpuCount) CPUs, "
            + "\(sizing.memorySize >> 30) GB memory, \(diskGB) GB sparse disk")
        let bundle = try home.bundle(named: plan.name)
        try LinuxImage.makeBundle(bundle, from: source, cpuCount: sizing.cpuCount, memorySize: sizing.memorySize,
                                  diskSize: diskGB << 30, rosetta: image.rosetta)
        do {
            let seed = bundle.url.appendingPathComponent("seed.iso")
            try LinuxSeed.makeISO(at: seed, agent: plan.guest.appendingPathComponent("linux"), account: image.account.name,
                                  fullName: image.account.fullName ?? image.account.name, name: plan.name,
                                  rosetta: image.rosetta)
            try await firstBoot(bundle, seed: seed)
            try FileManager.default.removeItem(at: seed)
            // Without the seed: the image must come up on its own, as every clone does.
            _ = try await ImageSteps.run(name: plan.name, steps: image.steps, share: plan.share)
        } catch {
            print("The build stopped; '\(plan.name)' is left at \(bundle.url.path) to look at. Delete it to build again.")
            throw error
        }
        print("Built '\(plan.name)' from \(plan.file.lastPathComponent) in \(DurationFormat.short(ContinuousClock.now - started)).")
        print("  Ready to serve: paddock serve \(plan.name)")
    }

    /// The image file's Linux disk: the one it names, or Debian's or a URL's, checked and cached.
    static func fetch(_ from: ImageFile.Source, disk: URL?, home: PaddockHome) async throws -> URL {
        let line = ProgressLine("Downloading")
        let progress: @Sendable (Int64, Int64) -> Void = { written, expected in
            guard expected > 0 else { return }
            line.update(fraction: Double(written) / Double(expected),
                        detail: "\(ByteFormat.gigabytes(written)) of \(ByteFormat.gigabytes(expected))")
        }
        defer { line.finish() }
        switch from {
        case let .debian(release):
            guard let debian = LinuxImage.Debian(release: release) else { throw PaddockError("no Debian \(release) to build from") }
            print("Checking Debian \(release)'s latest build against \(debian.sumsURL.absoluteString)")
            return try await LinuxImage.fetch(debian, into: home.linuxCacheDirectory, progress: progress)
        case let .url(url, checksum):
            print("Getting \(url.absoluteString), which must match its \(checksum.algorithm.rawValue)")
            return try await LinuxImage.fetch(url, matching: checksum, into: home.linuxCacheDirectory, progress: progress)
        case .disk:
            guard let disk else { throw PaddockError("the image file's disk wasn't checked") }
            return disk
        case .latest, .ipsw:
            throw PaddockError("that's a macOS image file")
        }
    }

    /// Boots the new VM with the seed attached until cloud-init has set it up and the guest agent
    /// answers, then has the guest shut itself down, so what setup wrote is on disk.
    static func firstBoot(_ bundle: VMBundle, seed: URL) async throws {
        let vm = try HeadlessVM(bundle: bundle, config: try bundle.readConfig(), seed: seed)
        print("Booting '\(bundle.name)' once to create the account and install the guest agent")
        try await vm.start()
        do {
            guard try await vm.agentVersion(within: .seconds(300)) != nil else {
                throw PaddockError("the guest agent in '\(bundle.name)' didn't answer within 300 s. The guest's console "
                    + "ends:\n\(consoleTail(of: bundle))")
            }
            try await setClock(vm)
            // cloud-init's last modules may still be running; 2 is done with warnings.
            let status = try await vm.runInGuest("cloud-init status --wait --long", asRoot: true) { print("    \($0)") }
            guard status == 0 || status == 2 else {
                throw PaddockError("cloud-init failed in '\(bundle.name)', as its status above says")
            }
            print("  set up; shutting down")
            _ = try await vm.runInGuest("\(LinuxSeed.disableCloudInit); sync; (sleep 2; systemctl poweroff) </dev/null >/dev/null 2>&1 &",
                                        asRoot: true) { _ in }
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(bundle.name)' didn't shut down within 120 s of its setup")
            }
        } catch {
            await vm.stop()
            throw error
        }
    }

    /// Sets the guest's clock from this Mac's. A cloud image boots with its clock at 1970 until
    /// its network time arrives, and steps that check certificates would fail until then.
    static func setClock(_ vm: HeadlessVM) async throws {
        let now = Int(Date().timeIntervalSince1970)
        _ = try await vm.runInGuest("date -u -s @\(now) >/dev/null", asRoot: true) { _ in }
    }

    /// The last lines of the guest's console, as console.log kept them, without terminal escapes.
    static func consoleTail(of bundle: VMBundle, lines count: Int = 20) -> String {
        guard let data = FileManager.default.contents(atPath: bundle.consoleLogURL.path) else { return "  (no console.log)" }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        let lines = text.split(whereSeparator: \.isNewline).suffix(count)
        return lines.isEmpty ? "  (nothing)" : lines.map { "  " + $0 }.joined(separator: "\n")
    }
}
