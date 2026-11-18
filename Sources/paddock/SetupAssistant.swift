import CoreGraphics
import Foundation
import PaddockCore

/// Clicks through Setup Assistant on a build's first boot, for `--accept-macos-license`: reads
/// the guest's screen on the host, finds the buttons by their text, and clicks them with the VM's
/// virtual pointer. Provisioning then logs the account in, with automatic login on.
@MainActor
enum SetupAssistant {
    /// Clicks what SetupAssistantPage picks until the account is logged in, which paddock-session
    /// answering over vsock shows; it starts at the desktop login. Throws after `timeout`, when
    /// the build saves the screen, which shows the page it stopped at.
    static func clickThrough(_ vm: HeadlessVM, within timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        var last = "", repeats = 0
        while ContinuousClock.now < deadline {
            if try await vm.sessionHelperVersion(within: .milliseconds(500)) != nil {
                return
            }
            let (lines, screen) = try await vm.readScreen()
            guard let button = SetupAssistantPage.button(in: lines, screen: screen) else {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            // Agree comes twice in a row, the license and its sheet. A third means the click
            // didn't take: the license may need reading to its end first.
            repeats = button.string == last ? repeats + 1 : 0
            last = button.string
            if repeats >= 2 {
                try vm.scroll(x: Int(button.frame.midX), y: Int(screen.height / 2), down: 200, right: 0)
                try await Task.sleep(for: .seconds(1))
            }
            print("  clicking '\(button.string)'")
            try vm.click(x: Int(button.frame.midX), y: Int(button.frame.midY), button: .left, count: 1)
            try await Task.sleep(for: .seconds(3))
        }
        throw PaddockError("Setup Assistant didn't log the account in within \(DurationFormat.short(timeout))")
    }
}
