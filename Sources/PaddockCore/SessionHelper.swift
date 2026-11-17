/// The protocol of paddock-session, the helper that runs in the guest user's desktop session.
/// It speaks GuestAgent's line protocol on its own vsock port, with these requests:
///
///     {"op":"health"}  ->  {"version":"0.1.0"}
///     {"op":"axtree"}  ->  {"output":"..."} per line of a JSON tree, then {"exit":0}
///
/// `axtree` describes the app that has focus. Like the agent, the helper runs where the workload
/// can replace it, so the host treats its answers as untrusted.
public enum SessionHelper {
    public static let port: UInt32 = 52526
    public static let version = "0.1.0"

    /// Asks the helper over `fd` for the focused app's accessibility tree, passing each line of
    /// its JSON to `output`.
    public static func askForTree(over fd: Int32, output: (String) -> Void) throws {
        let status = try GuestAgent.askStreaming(GuestAgent.Request(op: "axtree"), over: fd, output: output)
        guard status == 0 else {
            throw PaddockError("paddock-session ended the tree with status \(status)")
        }
    }
}
