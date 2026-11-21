import Foundation
import os
import PaddockCore

/// `paddock build <file>` for a Linux image: get the image, make the VM from its disk, boot it
/// once with the cloud-init seed, which creates the account and sets the image up, then once more
/// without it to run the steps and seal the image. An image with a display manager, or a file
/// with `desktop: true`, boots a last time with a screen to check its desktop.
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
            let steps = try await ImageSteps.run(name: plan.name, steps: image.steps, share: plan.share)
            if steps.displayManager != nil || image.desktop {
                try await checkDesktop(bundle, required: image.desktop, from: image.from)
            }
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
        case let .debian(release, variant):
            guard let debian = LinuxImage.Debian(release: release, variant: variant) else {
                throw PaddockError("no Debian \(release) to build from")
            }
            print("Checking Debian \(release)'s latest \(variant.rawValue) build against \(debian.sumsURL.absoluteString)")
            return try await LinuxImage.fetchLatest(debian.url, listedIn: debian.sumsURL, .sha512,
                                                    into: home.linuxCacheDirectory, progress: progress)
        case let .ubuntu(release):
            guard let ubuntu = LinuxImage.Ubuntu(release: release) else { throw PaddockError("no Ubuntu \(release) to build from") }
            print("Checking Ubuntu \(release)'s latest build against \(ubuntu.sumsURL.absoluteString)")
            return try await LinuxImage.fetchLatest(ubuntu.url, listedIn: ubuntu.sumsURL, .sha256,
                                                    into: home.linuxCacheDirectory, progress: progress)
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
            // A cloud image boots at 1970 until its network time arrives, which breaks steps that check certificates.
            try await vm.setGuestClock()
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

    /// Boots the sealed image with a screen and USB input until the agent says the account's
    /// desktop is up, then marks the image a desktop, so its VMs get those devices. A desktop
    /// that doesn't come up leaves the image headless, saying why, or with `required` stops the
    /// build. Either way the guest shuts itself down, which empties its machine-id again.
    static func checkDesktop(_ bundle: VMBundle, required: Bool, from source: ImageFile.Source) async throws {
        var config = try bundle.readConfig()
        config.desktop = true
        print("Booting '\(bundle.name)' with a screen to check its desktop")
        let vm = try HeadlessVM(bundle: bundle, config: config)
        try await vm.start()
        var missing: String?
        var accessibility = true
        do {
            guard try await vm.agentVersion(within: .seconds(180)) != nil else {
                throw PaddockError("the guest agent in '\(bundle.name)' didn't answer within 180 s")
            }
            let deadline = ContinuousClock.now + .seconds(120)
            while !(try await vm.desktopReady(within: .seconds(5))) {
                let lines = OSAllocatedUnfairLock(initialState: [String]())
                let status = try await vm.runInGuest(LinuxSeed.desktopDiagnosisScript, asRoot: true) { line in
                    lines.withLock { $0.append(line) }
                }
                // 2: it can't come up as the image is; otherwise it may still be starting.
                if status == 2 || ContinuousClock.now >= deadline {
                    missing = lines.withLock { $0.last } ?? "its desktop didn't come up"
                    break
                }
            }
            if missing == nil {
                // axtree reads AT-SPI's bus, which starts with the session when the image has it.
                accessibility = try await vm.runInGuest(LinuxSeed.accessibilityBusCheck, asRoot: true) { _ in } == 0
            }
            _ = try await vm.runInGuest("sync; (sleep 2; systemctl poweroff) </dev/null >/dev/null 2>&1 &", asRoot: true) { _ in }
            guard try await vm.waitUntilStopped(within: .seconds(120)) else {
                throw PaddockError("'\(bundle.name)' didn't shut down within 120 s of its desktop check")
            }
        } catch {
            await vm.stop()
            throw error
        }
        if var missing {
            if case let .debian(release, .genericcloud) = source, missing.hasPrefix("its kernel") {
                missing += " (Debian's generic variant has one that does: from: { debian: \(release), variant: generic })"
            }
            guard !required else {
                throw PaddockError("'\(bundle.name)' has no working desktop: \(missing). The image file says desktop: true")
            }
            print("  no desktop: \(missing); the image stays headless")
            return
        }
        try bundle.writeConfig(config)
        print("  a desktop: its VMs get a \(config.display.widthInPixels)x\(config.display.heightInPixels) screen and USB input")
        if !accessibility {
            print("  note: the desktop has no AT-SPI bus, so paddock axtree can't read its apps; install at-spi2-core in a step")
        }
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
