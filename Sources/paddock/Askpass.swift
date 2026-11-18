import ArgumentParser
import Dispatch
import Foundation
import PaddockCore

/// The program ssh runs for a password; see AskpassServer.
struct Askpass: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the password a running paddock build holds, for ssh.", shouldDisplay: false)

    @Argument(parsing: .captureForPassthrough, help: "ssh's prompt, which is ignored.")
    var prompt: [String] = []

    func run() throws {
        guard let socket = ProcessInfo.processInfo.environment["PADDOCK_ASKPASS"] else {
            throw PaddockError("paddock askpass runs only for ssh, from paddock build")
        }
        print(try LineClient.send("password", to: socket))
    }
}
