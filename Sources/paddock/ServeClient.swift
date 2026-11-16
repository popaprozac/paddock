import ArgumentParser
import Foundation
import PaddockCore

/// A request to `paddock serve`, sent as one line of JSON over its socket.
struct ServeRequest: Codable {
    var op: String  // "acquire" or "release"
    var vm: String?
}

/// serve's one-line answer: the VM and its address, or an error.
struct ServeResponse: Codable {
    var vm: String?
    var ip: String?
    var error: String?

    var line: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

enum ServeClient {
    static func send(_ request: ServeRequest) throws -> ServeResponse {
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let answer = try LineClient.send(line, to: PaddockHome.fromEnvironment().socketURL.path)
        guard let response = try? JSONDecoder().decode(ServeResponse.self, from: Data(answer.utf8)) else {
            throw PaddockError("unreadable answer from paddock serve: \(answer.prefix(200))")
        }
        if let error = response.error {
            throw PaddockError(error)
        }
        return response
    }
}

struct Acquire: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take the warm VM from paddock serve, waiting while the slot fills.",
        discussion: "Prints the VM's name and address. Hand it back with 'paddock release <vm>'.")

    func run() throws {
        let started = ContinuousClock.now
        let response = try ServeClient.send(ServeRequest(op: "acquire"))
        let waited = ContinuousClock.now - started
        print("Assigned '\(response.vm ?? "?")' at \(response.ip ?? "?") in \(DurationFormat.short(waited))")
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hand a VM back to paddock serve, which deletes it and restores a fresh one.")

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    func validate() throws {
        try BundleName.validate(vm)
    }

    func run() throws {
        _ = try ServeClient.send(ServeRequest(op: "release", vm: vm))
        print("Released '\(vm)'; serve is restoring a fresh clone")
    }
}
