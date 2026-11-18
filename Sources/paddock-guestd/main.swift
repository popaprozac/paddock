import Dispatch
import Foundation
import PaddockCore

// The agent inside a macOS guest. It answers the host over vsock only; GuestAgent defines the
// protocol. launchd runs it as root from /Library/LaunchDaemons and restarts it if it exits.
setvbuf(stdout, nil, _IOLBF, 0)
do {
    guard let user = GuestAgent.workloadUser(), let files = GuestAgent.filesDirectory(for: user) else {
        throw PaddockError("no user with uid 501 to run commands as; finish Setup Assistant first")
    }
    // Before the user logs in, which is when their per-host preferences are first read.
    for line in GuestAgent.carryHostPreferences(for: user) {
        print("paddock-guestd: \(line)")
    }
    let fd = try GuestAgent.listen(port: GuestAgent.port)
    let server = LineServer(listening: fd, queue: .main, accepts: GuestAgent.onlyFromHost("paddock-guestd")) { line, responder in
        GuestAgent.handle(line, runAs: user, files: files, responder: responder)
    }
    print("paddock-guestd \(GuestAgent.version) listening on vsock port \(GuestAgent.port), running commands as '\(user)'")
    withExtendedLifetime(server) { dispatchMain() }
} catch {
    print("paddock-guestd: \(error)")
    exit(1)
}
