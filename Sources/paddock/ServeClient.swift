import ArgumentParser
import Foundation
import PaddockCore

/// A request to `paddock serve`, sent as one line of JSON over its socket.
struct ServeRequest: Codable {
    var op: String  // "acquire", "release", "exec" or "task"
    var vm: String?
    var command: String?
    var bundle: String?  // task: absolute path of the git bundle to work on
    var result: String?  // task: absolute path to save the result bundle at
    var allow: [String]?  // acquire: the names the VM may reach on the userspace network
}

/// serve's one-line answer: the VM and its address, or an error.
struct ServeResponse: Codable {
    var vm: String?
    var ip: String?
    var output: String?  // exec: one line of the command's output
    var exit: Int32?     // exec and task: the command's exit status, last
    var result: String?  // task: where the bundle of new commits was saved, if there are any
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
        discussion: """
            Prints the VM's name and address. Hand it back with 'paddock release <vm>'. With \
            'serve --userspace', the VM reaches only the names given with --allow, and nothing \
            without it.
            """)

    @Option(help: "Names the VM may reach, comma-separated, as host.example or *.example (any name under example). Needs 'serve --userspace'.")
    var allow: String?

    func run() throws {
        let names = allow?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let started = ContinuousClock.now
        let response = try ServeClient.send(ServeRequest(op: "acquire", allow: names))
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

struct RunTask: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task",
        abstract: "Run a command on a git branch in a VM that paddock acquire handed out.",
        discussion: """
            The bundle must hold the branch with HEAD, as 'git bundle create in.bundle HEAD' \
            makes it. paddock copies it into the guest over vsock, clones it, runs the command \
            in the clone and commits whatever the command changed, as paddock. If the branch \
            gained commits, they are saved as a bundle at --result, ready for \
            'git fetch <result> HEAD:<branch>'. paddock exits with the command's status.
            """)

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @Option(help: "Git bundle of the branch to work on.")
    var bundle: String

    @Option(help: "Where to save a bundle of the new commits.")
    var result: String

    @Argument(parsing: .postTerminator, help: "Command to run in the clone, after --.")
    var command: [String] = []

    func validate() throws {
        try BundleName.validate(vm)
        guard !command.isEmpty else { throw ValidationError("give the command after --") }
        guard FileManager.default.fileExists(atPath: bundle) else { throw ValidationError("no bundle at \(bundle)") }
    }

    func run() throws {
        let request = ServeRequest(
            op: "task", vm: vm, command: command.joined(separator: " "),
            bundle: URL(fileURLWithPath: bundle).standardizedFileURL.path,
            result: URL(fileURLWithPath: result).standardizedFileURL.path)
        var last: ServeResponse?
        try ServeClient.stream(request) { response in
            if let output = response.output {
                print(output)
            }
            if response.exit != nil {
                last = response
            }
            return last == nil
        }
        guard let last, let status = last.exit else {
            throw PaddockError("paddock serve closed the connection before the task finished")
        }
        // stdout carries the command's output, so the summary goes to stderr.
        let summary = last.result.map { "New commits saved to \($0)" } ?? "No changes"
        FileHandle.standardError.write(Data((summary + "\n").utf8))
        if status != 0 {
            throw ExitCode(status)
        }
    }
}
