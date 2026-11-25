import ArgumentParser
import Foundation
import PaddockCore

/// What this Mac's serve offers, changed while it runs: these go to serve on this Mac only, never
/// through a pool, and a control plane can't send them.
struct Join: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Link this Mac's running serve to a control plane's pool, without a restart.",
        discussion: """
            The first time, give a token from 'paddock-control join-token' there; after that this \
            Mac rejoins without one. It stays in the pool until 'paddock leave' or serve stops: a \
            serve started again links only with --control.
            """)

    @Argument(help: "The control plane, such as https://studio.local:7443.")
    var url: String

    @Option(help: "A join token from 'paddock-control join-token', the first time this Mac joins it.")
    var token: String?

    func run() throws {
        print(try ServeClient.send(ServeRequest(op: "join", url: url, token: token), local: true).output ?? "")
    }
}

struct Leave: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take this Mac's running serve out of its pool; it goes on serving here alone.",
        discussion: """
            While the pool holds VMs on this Mac it refuses and names them, unless --force, which \
            wipes them. This Mac can join again without a token.
            """)

    @Flag(help: "Wipe the VMs the pool holds here, and leave.")
    var force = false

    func run() throws {
        print(try ServeClient.send(ServeRequest(op: "leave", force: force), local: true).output ?? "")
    }
}

struct Offer: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start or stop this Mac's serve handing out VMs, here and to its pool.",
        discussion: """
            off: no new hand-outs; warm VMs nobody holds stop, and VMs in use run until they're \
            released. The slots keep their saved state, so on fills them again in seconds.
            """)

    enum State: String, ExpressibleByArgument {
        case on, off
    }

    @Argument(help: "on or off.")
    var state: State

    func run() throws {
        print(try ServeClient.send(ServeRequest(op: "offer", offering: state == .on), local: true).output ?? "")
    }
}
