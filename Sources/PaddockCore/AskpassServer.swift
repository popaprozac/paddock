import Darwin
import Dispatch
import Foundation

/// Hands ssh a password without putting it in an environment variable, a command line or a
/// file. ssh runs its SSH_ASKPASS program for each password it needs: here a script, in a folder
/// only this user can open, that runs `paddock askpass`, which gets the password from this
/// process over a Unix socket in the same folder. Stop it as soon as ssh is done.
public final class AskpassServer {
    /// What ssh's environment needs to use this server.
    public let environment: [String: String]
    private let server: LineServer
    private let directory: URL

    /// `helper` is the program the script runs to ask for the password: paddock, whose hidden
    /// `askpass` command does that.
    public init(password: String, helper: String) throws {
        // /tmp, not $TMPDIR, keeps the socket's path within the 104 bytes macOS allows; mkdtemp
        // makes the folder 0700 whatever its parent.
        var template = Array("/tmp/paddock-askpass.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            throw PaddockError("couldn't make a private folder for ssh's password helper")
        }
        directory = URL(fileURLWithPath: String(cString: made), isDirectory: true)  // mkdtemp makes it 0700
        let socket = directory.appendingPathComponent("askpass.sock").path
        let script = directory.appendingPathComponent("askpass")
        let quoted = "'" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            try "#!/bin/sh\nexec \(quoted) askpass\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            server = try LineServer(path: socket, queue: DispatchQueue(label: "paddock.askpass")) { _, responder in
                responder.finish(password)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment = ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "PADDOCK_ASKPASS": socket]
    }

    public func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
