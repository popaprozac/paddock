import ArgumentParser
import Foundation
import PaddockCore

/// A request to `paddock serve`, sent as one line of JSON over its socket.
struct ServeRequest: Codable {
    var op: String  // "acquire", "release", "exec", "task", "screenshot", "axtree" or "input"
    var vm: String?
    var command: String?
    var bundle: String?  // task: absolute path of the git bundle to work on
    var result: String?  // task and screenshot: absolute path to save the result at
    var allow: [String]?  // acquire: the names the VM may reach on the userspace network
    var input: InputAction?  // input: what to send to the VM's pointer or keyboard
    var wait: Bool?  // acquire: false answers busy at once when no warm VM is free, instead of waiting
}

/// One piece of input for a VM, sent with the "input" request. Coordinates are the guest's screen
/// pixels from the top left, as in screenshots and accessibility frames.
struct InputAction: Codable {
    var kind: String  // "click", "type", "key" or "scroll"
    var x: Int?
    var y: Int?
    var button: String?  // click: "left", the default, or "right"
    var count: Int?      // click: how many in a row, 1 to 3
    var text: String?    // type: characters a US keyboard types
    var keys: [String]?  // key: combinations such as "cmd+s", pressed in order
    var down: Int?       // scroll: lines toward the end of the content; negative scrolls up
    var right: Int?      // scroll: lines toward the right; negative scrolls left
}

/// serve's one-line answer: the VM and its address, or an error.
struct ServeResponse: Codable {
    var vm: String?
    var ip: String?
    var output: String?  // exec: one line of the command's output
    var exit: Int32?     // exec and task: the command's exit status, last
    var result: String?  // task: where the bundle of new commits was saved, if there are any
    var error: String?
    var host: String?    // acquire through the pool: the name of the Mac the VM runs on
    var busy: Bool?      // acquire that doesn't wait: no warm VM was free

    var line: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Sends serve's requests: to the pool of the control plane this Mac is logged in to, or, with
/// `local`, PADDOCK_LOCAL=1 or no login, to this Mac's serve.
enum ServeClient {
    static func send(_ request: ServeRequest, image: String? = nil, local: Bool = false) throws -> ServeResponse {
        var first: ServeResponse?
        try stream(request, image: image, local: local) { first = $0; return false }
        guard let first else {
            throw PaddockError("paddock serve closed the connection without answering")
        }
        return first
    }

    /// Passes each answer line to `onResponse` until serve closes the connection or
    /// `onResponse` returns false. An error answer throws.
    static func stream(_ request: ServeRequest, image: String? = nil, local: Bool = false,
                       onResponse: (ServeResponse) throws -> Bool) throws {
        if let identity = try PoolRoute.identity(local: local) {
            return try PoolRoute.stream(request, image: image, as: identity, onResponse: onResponse)
        }
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
            without it. Logged in to a control plane, it takes a warm VM from any Mac in the pool \
            serving the image, waiting its turn if none is free; --local takes this Mac's.
            """)

    @Option(help: "Names the VM may reach, comma-separated, as host.example or *.example (any name under example). Needs 'serve --userspace'.")
    var allow: String?

    @Option(help: "In the pool: the golden image the VM is a clone of, when the pool serves more than one.")
    var image: String?

    @OptionGroup var target: Target

    func run() throws {
        let names = allow?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let started = ContinuousClock.now
        let response = try ServeClient.send(ServeRequest(op: "acquire", allow: names), image: image, local: target.local)
        let waited = ContinuousClock.now - started
        // A VM in the pool has its address on its own Mac's private network, no use from here.
        let place = response.host.map { "on \($0)" } ?? "at \(response.ip ?? "?")"
        print("Assigned '\(response.vm ?? "?")' \(place) in \(DurationFormat.short(waited))")
    }
}

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save the screen of a VM that paddock acquire handed out, as a PNG.",
        discussion: "serve reads the VM's framebuffer on this Mac; the guest grants nothing and runs nothing.")

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @Option(name: .shortAndLong, help: "Where to save the PNG. Defaults to <vm>.png in the current folder.")
    var output: String?

    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
    }

    func run() throws {
        let url = URL(fileURLWithPath: output ?? "\(vm).png").standardizedFileURL
        let started = ContinuousClock.now
        _ = try ServeClient.send(ServeRequest(op: "screenshot", vm: vm, result: url.path), local: target.local)
        print("Saved \(url.path) in \(DurationFormat.short(ContinuousClock.now - started))")
    }
}

struct AXTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "axtree",
        abstract: "Print the accessibility tree of the focused app in a VM that paddock acquire handed out.",
        discussion: """
            The tree is JSON: each element has its role, its title, value and description when it \
            has them, its frame as x, y, width and height in screen points from the top left, and \
            its children. A point is a pixel of 'paddock screenshot'. It comes from paddock-session, \
            which must run in the guest's desktop session with Accessibility allowed.
            """)

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
    }

    func run() throws {
        try ServeClient.stream(ServeRequest(op: "axtree", vm: vm), local: target.local) { response in
            if let output = response.output {
                print(output)
            }
            return response.exit == nil
        }
    }
}

/// The input commands: each sends one input request to serve for a VM it handed out.
private func sendInput(_ vm: String, _ action: InputAction, local: Bool) throws {
    _ = try ServeClient.send(ServeRequest(op: "input", vm: vm, input: action), local: local)
}

private let inputDiscussion = """
    The input goes to the VM's virtual pointer and keyboard from the host, so the guest grants \
    nothing, and it is sent before the guest has acted on it.
    """

private let pointerDiscussion = """
    Coordinates are the guest's screen pixels from the top left, the same as in \
    'paddock screenshot' and the frames 'paddock axtree' prints. \(inputDiscussion)
    """

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Click in a VM that paddock acquire handed out.", discussion: pointerDiscussion)

    @Argument(help: "VM that 'paddock acquire' printed.") var vm: String
    @Argument(help: "Pixels from the left of the guest's screen.") var x: Int
    @Argument(help: "Pixels from the top of the guest's screen.") var y: Int
    @Flag(help: "Click the right button.") var right = false
    @Flag(help: "Click twice in a row.") var double = false
    @OptionGroup var target: Target

    func validate() throws { try BundleName.validate(vm) }

    func run() throws {
        try sendInput(vm, InputAction(kind: "click", x: x, y: y, button: right ? "right" : "left", count: double ? 2 : 1),
                      local: target.local)
    }
}

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into a VM that paddock acquire handed out, as key presses.",
        discussion: """
            The text goes to whatever has the keyboard focus in the guest, at about 100 \
            characters a second. Only characters a US keyboard types work, and the guest must \
            use a US keyboard layout for them to come out as typed. \(inputDiscussion)
            """)

    @Argument(help: "VM that 'paddock acquire' printed.") var vm: String
    @Argument(help: "Text to type.") var text: String
    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
        do { _ = try KeyInput.strokes(typing: text) } catch let error as PaddockError { throw ValidationError(error.message) }
    }

    func run() throws { try sendInput(vm, InputAction(kind: "type", text: text), local: target.local) }
}

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press key combinations in a VM that paddock acquire handed out.",
        discussion: """
            Each combination is modifiers and one key joined by +, such as cmd+s, cmd+shift+z, \
            return or escape, pressed in order. Modifiers are cmd, ctrl, opt and shift; keys are \
            characters a US keyboard types, plus for +, or return, tab, space, delete, \
            forwarddelete, escape, left, right, up, down, home, end, pageup, pagedown and f1 to f12. \
            \(inputDiscussion)
            """)

    @Argument(help: "VM that 'paddock acquire' printed.") var vm: String
    @Argument(help: "Key combinations, such as cmd+s.") var combinations: [String]
    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
        guard !combinations.isEmpty else { throw ValidationError("give at least one key combination, such as cmd+s") }
        for combination in combinations {
            do { _ = try KeyInput.stroke(combination) } catch let error as PaddockError { throw ValidationError(error.message) }
        }
    }

    func run() throws { try sendInput(vm, InputAction(kind: "key", keys: combinations), local: target.local) }
}

struct Scroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scroll in a VM that paddock acquire handed out.",
        discussion: """
            Directions are the content's, as with macOS's default natural scrolling; a guest that \
            turns natural scrolling off scrolls the other way. \(pointerDiscussion)
            """)

    @Argument(help: "VM that 'paddock acquire' printed.") var vm: String
    @Argument(help: "Pixels from the left of the guest's screen.") var x: Int
    @Argument(help: "Pixels from the top of the guest's screen.") var y: Int
    @Option(help: "Lines to scroll down.") var down = 0
    @Option(help: "Lines to scroll up.") var up = 0
    @Option(help: "Lines to scroll right.") var right = 0
    @Option(help: "Lines to scroll left.") var left = 0
    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
        guard [down, up, right, left].allSatisfy({ $0 >= 0 }) else { throw ValidationError("give lines as positive numbers") }
    }

    func run() throws {
        try sendInput(vm, InputAction(kind: "scroll", x: x, y: y, down: down - up, right: right - left), local: target.local)
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hand a VM back to paddock serve, which deletes it and restores a fresh one.")

    @Argument(help: "VM that 'paddock acquire' printed.")
    var vm: String

    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
    }

    func run() throws {
        _ = try ServeClient.send(ServeRequest(op: "release", vm: vm), local: target.local)
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

    @OptionGroup var target: Target

    func validate() throws {
        try BundleName.validate(vm)
        guard !command.isEmpty else { throw ValidationError("give the command after --") }
    }

    func run() throws {
        var status: Int32?
        let request = ServeRequest(op: "exec", vm: vm, command: command.joined(separator: " "))
        try ServeClient.stream(request, local: target.local) { response in
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

    @OptionGroup var target: Target

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
        try ServeClient.stream(request, local: target.local) { response in
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
