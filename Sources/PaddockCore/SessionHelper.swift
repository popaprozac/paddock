import CoreGraphics

/// The protocol of paddock-session, the helper that runs in the guest user's desktop session.
/// It speaks GuestAgent's line protocol on its own vsock port, with these requests:
///
///     {"op":"health"}  ->  {"version":"0.2.2"}
///     {"op":"axtree"}  ->  {"output":"..."} per line of a JSON tree, then {"exit":0}
///     {"op":"state"}   ->  {"output":"desktop"} when it holds, then {"exit":0}
///
/// `axtree` describes the app that has focus. Like the agent, the helper runs where the workload
/// can replace it, so the host treats its answers as untrusted.
public enum SessionHelper {
    public static let port: UInt32 = 52526
    public static let version = "0.2.2"
    /// Where guest/install.sh puts the helper; a guest with a file there runs it at login.
    public static let installedPath = "/usr/local/libexec/paddock-session"

    /// What the host waits for before handing the guest out: "desktop" once loginwindow has no
    /// window on screen. After a login, loginwindow covers the screen with a snapshot of the
    /// desktop until the Dock reports the desktop ready, which took 3 s to over 20 s in testing,
    /// and a click on the snapshot leaves loginwindow with the keyboard focus. A locked screen is
    /// loginwindow's too. `windows` is CGWindowListCopyWindowInfo's on-screen list, whose owner
    /// names need no permission; without one, the helper can't vouch for the desktop.
    public static func state(onScreen windows: [[String: Any]]?) -> [String] {
        guard let windows else { return [] }
        let loginwindowShowing = windows.contains { $0[kCGWindowOwnerName as String] as? String == "loginwindow" }
        return loginwindowShowing ? [] : ["desktop"]
    }

    /// Asks the helper over `fd`, or a Linux guest's agent, which answers the same request, for
    /// the focused app's accessibility tree, passing each line of its JSON to `output`.
    public static func askForTree(over fd: Int32, output: (String) -> Void) throws {
        let status = try GuestAgent.askStreaming(GuestAgent.Request(op: "axtree"), over: fd, output: output)
        guard status == 0 else {
            throw PaddockError("the guest ended the tree with status \(status)")
        }
    }
}
