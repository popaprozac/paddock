import AppKit
import ApplicationServices
import Foundation
import PaddockCore

// paddock-session, the helper in a macOS guest's desktop session. It reads the accessibility tree
// of the app that has focus, which only a process in the logged-in user's session can do, and
// answers the host over vsock only, on its own port; SessionHelper defines the protocol. launchd
// runs it from /Library/LaunchAgents for the user who logs in and restarts it if it exits.
setvbuf(stdout, nil, _IOLBF, 0)
// Connects to the window server, as a desktop app does; with no bundle it shows no Dock icon.
_ = NSApplication.shared

// Reading other apps needs the Accessibility permission. Until it is allowed, asking with the
// prompt option lists the helper under Privacy & Security > Accessibility and shows macOS's
// prompt. Asking that way once allowed would still bring AccessibilityUIServer to the front,
// with no window, so it would be the app every tree describes until another app opens.
let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
let trusted = AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(prompt)
print("paddock-session \(SessionHelper.version): Accessibility \(trusted ? "allowed" : "not allowed yet")")

/// The app in front, after making Finder the app in front if the one there isn't an app people
/// use, such as AccessibilityUIServer (see SessionHelper.broughtFinderForward). Through the
/// accessibility API, as System Events does, so no window opens.
func bringFinderForwardIfNeeded() -> String {
    let front = NSWorkspace.shared.frontmostApplication
    let name = front?.localizedName ?? "nothing"
    guard front?.activationPolicy != .regular, AXIsProcessTrusted(),
          let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    else { return name }
    let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(finder.processIdentifier),
                                              kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    return result == .success ? SessionHelper.broughtFinderForward + name : name
}

do {
    let fd = try GuestAgent.listen(port: SessionHelper.port)
    let server = LineServer(listening: fd, queue: .main, accepts: GuestAgent.onlyFromHost("paddock-session")) { line, responder in
        let request = try? JSONDecoder().decode(GuestAgent.Request.self, from: Data(line.utf8))
        switch request?.op {
        case "health":
            responder.finish(GuestAgent.Response(version: SessionHelper.version).line)
        case "state":
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            responder.send(lines: SessionHelper.state(onScreen: windows).map { GuestAgent.Response(output: $0).line })
            responder.finish(GuestAgent.Response(exit: 0).line)
        case "front":
            responder.send(lines: [GuestAgent.Response(output: bringFinderForwardIfNeeded()).line])
            responder.finish(GuestAgent.Response(exit: 0).line)
        case "axtree":
            guard AXIsProcessTrusted() else {
                return responder.finish(GuestAgent.Response(
                    error: "paddock-session isn't allowed Accessibility; allow it in System Settings > Privacy & Security > Accessibility").line)
            }
            do {
                let lines = try AXTree.focusedAppJSON().split(separator: "\n", omittingEmptySubsequences: false)
                responder.send(lines: lines.map { GuestAgent.Response(output: String($0)).line })
                responder.finish(GuestAgent.Response(exit: 0).line)
            } catch {
                responder.finish(GuestAgent.Response(error: "\(error)").line)
            }
        default:
            responder.finish(GuestAgent.Response(error: "unknown request").line)
        }
    }
    print("paddock-session listening on vsock port \(SessionHelper.port)")
    // The main run loop, unlike dispatchMain, also delivers NSWorkspace's front-app changes.
    withExtendedLifetime(server) { CFRunLoopRun() }
} catch {
    print("paddock-session: \(error)")
    exit(1)
}
