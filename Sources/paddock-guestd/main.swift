import Dispatch
import Foundation
import PaddockCore

// The agent inside a macOS guest. It answers the host over vsock only; GuestAgent defines the
// protocol. launchd runs it as root from /Library/LaunchDaemons and restarts it if it exits.
setvbuf(stdout, nil, _IOLBF, 0)
do {
    let fd = try GuestAgent.listen(port: GuestAgent.port)
    let server = LineServer(listening: fd, queue: .main) { line, reply in
        reply(GuestAgent.answer(line))
    }
    print("paddock-guestd \(GuestAgent.version) listening on vsock port \(GuestAgent.port)")
    withExtendedLifetime(server) { dispatchMain() }
} catch {
    print("paddock-guestd: \(error)")
    exit(1)
}
