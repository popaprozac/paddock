import ArgumentParser
import Foundation
import PaddockCore

/// A request to `paddock serve`, sent as one line of JSON over its socket.
struct ServeRequest: Codable {
    var op: String  // "acquire", "release" or "exec"
    var vm: String?
    var command: String?
}

/// serve's one-line answer: the VM and its address, or an error.
struct ServeResponse: Codable {
    var vm: String?
    var ip: String?
    var output: String?  // exec: one line of the command's output
    var exit: Int32?     // exec: the command's exit status, last
    var error: String?

    var line: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

enum ServeClient {
    static func send(_ request: ServeRequest) throws -> ServeResponse {
        var first: ServeResponse?
        try stream(request) { first = $0; return false }
        guard let first else {
            throw PaddockError("paddock serve closed the connection without answering")
        }
        return first
    }

    /// Passes each answer line to `onResponse` until serve closes the connection or
    /// `onResponse` returns false. An error answer throws.
    static func stream(_ request: ServeRequest, onResponse: (ServeResponse) throws -> Bool) throws {
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try LineClient.stream(line, to: PaddockHome.fromEnvironment().socketURL.path) { answer in
            guard let response = try? JSONDecoder().decode(ServeResponse.self, from: Data(answer.utf8)) else {
                throw PaddockError("unreadable answer from paddock serve: \(answer.prefix(200))")
            }
            if let error = response.error {
                throw PaddockError(error)
            }
            return try onResponse(response)
        }
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

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in a VM that paddock acquire handed out, through its guest agent.",
        discussion: """
            The command runs in a login shell as the guest's user, in its home folder, with no \
            network path into the guest. Its output streams back, and paddock exits with the \
            command's exit status. The words after -- are joined with spaces, as ssh does.
            """)

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @Argument(parsing: .postTerminator, help: "Command to run, after --.")
    var command: [String] = []

    func validate() throws {
        try BundleName.validate(vm)
        guard !command.isEmpty else { throw ValidationError("give the command after --") }
    }

    func run() throws {
        var status: Int32?
        try ServeClient.stream(ServeRequest(op: "exec", vm: vm, command: command.joined(separator: " "))) { response in
            if let output = response.output {
                print(output)
            }
            status = response.exit ?? status
            return status == nil
        }
        guard let status else {
            throw PaddockError("paddock serve closed the connection before the command finished")
        }
        if status != 0 {
            throw ExitCode(status)
        }
    }
}
