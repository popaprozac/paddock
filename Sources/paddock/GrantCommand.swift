import ArgumentParser
import Foundation
import PaddockCore

struct GrantCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant",
        abstract: "Grant paddock-session Accessibility and paddock-guestd Full Disk Access in a golden image, with SIP on.",
        discussion: """
            Boots the VM, which must be shut down, in macOS Recovery without a window, reads its \
            screen to open Terminal, and types a command that writes the two permissions into the \
            image's privacy database (TCC.db), each tied to the helper's code signature, as \
            System Settings does when you allow them. It also removes the Full Disk Access that \
            turning on Remote Login gives sshd, which 'paddock build' turns off. Then the VM shuts \
            down. System Integrity \
            Protection stays on throughout, so nothing running in the image or its clones can \
            change that database. Apple doesn't document its format, and a macOS release could \
            change it; allowing the two in System Settings, or with an MDM profile, is the \
            supported way. Needs the guest agent installed, as 'paddock build' does, and the \
            image's volumes under their default names.
            """)

    @Argument(help: "VM to grant the permissions in, usually the golden image.")
    var name: String

    func validate() throws {
        try BundleName.validate(name)
    }

    func run() async throws {
        try await RecoveryGrant.run(name: name)
    }
}

/// Drives macOS Recovery from the host, as an owner would: picks Options at the startup screen,
/// opens Terminal, and types PrivacyGrants's command, which halts the VM once the permissions are
/// written.
@MainActor
enum RecoveryGrant {
    static func run(name: String) async throws {
        let bundle = try PaddockHome.fromEnvironment().bundle(named: name)
        let vm = try HeadlessVM(bundle: bundle, config: try bundle.readConfig())
        // Attached before the first frame, so there is a screen to read and to save on failure.
        try? vm.attachScreen()
        print("Booting '\(name)' in macOS Recovery")
        try await vm.startInRecovery()
        do {
            try await click("Options", on: vm, within: .seconds(120))
            // Selecting Options shows a Continue button under it.
            try await click("Continue", on: vm, within: .seconds(30))
            // Recovery's window lists Disk Utility once it is up. Its menu bar reads as one line,
            // so Terminal is opened with Utilities > Terminal's shortcut, not by its menu title.
            _ = try await find("Disk Utility", on: vm, within: .seconds(180))
            print("  opening Terminal")
            try await vm.press([KeyInput.stroke("cmd+shift+t")])
            // Its window title names the shell once it runs; keys typed from then on reach it.
            _ = try await poll("Terminal's shell", within: .seconds(30)) {
                try await read(vm)?.lines.contains { $0.string.contains("bash") } == true ? true : nil
            }
            print("  writing the permissions")
            try await vm.press(KeyInput.strokes(typing: PrivacyGrants.recoveryScript()))
            guard try await vm.waitUntilStopped(within: .seconds(60)) else {
                throw PaddockError("'\(name)' didn't shut down after the command in Terminal, so it didn't finish")
            }
        } catch {
            await vm.saveScreen(as: "paddock-grant-\(name)")
            await vm.stop()
            throw error
        }
        print("Granted paddock-session Accessibility and paddock-guestd Full Disk Access in '\(name)'; SIP is still on.")
    }

    /// Waits until `label` shows as a whole line on the guest's screen, and returns that line.
    private static func find(_ label: String, on vm: HeadlessVM, within timeout: Duration) async throws -> ScreenText {
        try await poll(label, within: timeout) { () async throws -> ScreenText? in
            guard let (lines, screen) = try await read(vm) else { return nil }
            return ScreenText.find([label], in: lines, screen: screen)
        }
    }

    /// Waits until `label` shows as a whole line on the guest's screen, and clicks it.
    private static func click(_ label: String, on vm: HeadlessVM, within timeout: Duration) async throws {
        let line = try await find(label, on: vm, within: timeout)
        try vm.click(x: Int(line.frame.midX), y: Int(line.frame.midY), button: .left, count: 1)
        try await Task.sleep(for: .seconds(1))
    }

    /// What the guest's screen says now, or nil while it has no frame to read, as for several
    /// seconds after Recovery starts. Throws at once if the VM has stopped.
    private static func read(_ vm: HeadlessVM) async throws -> (lines: [ScreenText], size: CGSize)? {
        if let failure = vm.failure { throw failure }
        return try? await vm.readScreen()
    }

    /// Checks every second until `check` returns something; throws after `timeout`.
    private static func poll<T>(_ what: String, within timeout: Duration, _ check: () async throws -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = try await check() { return found }
            try await Task.sleep(for: .seconds(1))
        }
        throw PaddockError("macOS Recovery didn't show \(what) within \(DurationFormat.short(timeout))")
    }
}
