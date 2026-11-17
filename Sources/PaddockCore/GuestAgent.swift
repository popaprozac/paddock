import Darwin
import Foundation

/// The protocol between the host and paddock-guestd, the agent inside each macOS guest.
///
/// The agent listens only on vsock, so nothing on the VM network can reach it. Each
/// connection carries one request line of JSON and gets one or more answer lines back:
///
///     {"op":"health"}                       ->  {"version":"0.3.0"}
///     {"op":"run","command":"ls"}           ->  {"output":"..."} per line, then {"exit":0}
///     {"op":"put","name":"a","size":N} + N bytes  ->  {"exit":0}
///     {"op":"get","name":"a"}               ->  {"chunk":n} + n bytes, repeated, then {"exit":0}
///
/// `put` and `get` work on files in the workload account's `~/paddock` folder.
/// The host treats every answer as untrusted: the workload runs as admin and can replace the
/// agent.
public enum GuestAgent {
    /// The vsock port the agent listens on inside the guest.
    public static let port: UInt32 = 52525
    public static let version = "0.3.0"

    /// Output lines longer than this are split, so every answer line stays well under the
    /// 64 KB a reader accepts even after JSON escaping.
    static let outputChunk = 8 * 1024

    public struct Request: Codable, Equatable, Sendable {
        public var op: String  // "health", "run", "put" or "get"
        public var command: String?
        public var name: String?
        public var size: Int64?

        public init(op: String, command: String? = nil, name: String? = nil, size: Int64? = nil) {
            self.op = op
            self.command = command
            self.name = name
            self.size = size
        }

        var line: String {
            (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var version: String?
        public var output: String?
        public var chunk: Int?
        public var exit: Int32?
        public var error: String?

        public init(
            version: String? = nil, output: String? = nil, chunk: Int? = nil, exit: Int32? = nil, error: String? = nil
        ) {
            self.version = version
            self.output = output
            self.chunk = chunk
            self.exit = exit
            self.error = error
        }

        var line: String {
            (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    /// The account a workload runs as: the first one made in Setup Assistant.
    /// shortcut: assumes uid 501; the design's Assign step should name each session's user.
    public static func workloadUser() -> String? {
        getpwuid(501).map { String(cString: $0.pointee.pw_name) }
    }

    /// Answers one request on `responder`. `run`, `put` and `get` work on their own thread as
    /// `user`, through sudo, which needs the agent to run as root; with no user they run as the
    /// agent's own user, as the tests do. `files` is the folder `put` and `get` use.
    public static func handle(_ line: String, runAs user: String?, files: String, responder: Responder) {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
            return responder.finish(answer(line))
        }
        let work: @Sendable () -> Response
        switch request.op {
        case "run":
            guard let command = request.command else { return responder.finish(answer(line)) }
            work = { run(command, as: user) { responder.send(Response(output: $0).line) } }
        case "put":
            guard let name = request.name, isFileName(name), let size = request.size, (0...maxFileSize).contains(size) else {
                return responder.finish(Response(error: "put needs a plain file name and a size up to \(maxFileSize) bytes").line)
            }
            work = { put(name, size: size, into: files, as: user, from: responder) }
        case "get":
            guard let name = request.name, isFileName(name) else {
                return responder.finish(Response(error: "get needs a plain file name").line)
            }
            work = { get(name, from: files, as: user, to: responder) }
        default:
            return responder.finish(answer(line))
        }
        // Commands and file transfers can take a long time, so each gets its own thread.
        Thread.detachNewThread {
            responder.finish(work().line)
        }
    }

    /// The agent's one-line answer to a request that doesn't stream.
    public static func answer(_ line: String) -> String {
        let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8))
        let response = switch request?.op {
        case "health": Response(version: version)
        case "run": Response(error: "run needs a command")
        case let op?: Response(error: "unknown request '\(op.prefix(64))'")
        case nil: Response(error: "unreadable request")
        }
        return response.line
    }

    /// Runs `command` with stdin closed, passes each line of its combined stdout and stderr to
    /// `output`, and returns its exit status, or an error if it couldn't start.
    static func run(_ command: String, as user: String?, output: (String) -> Void) -> Response {
        let pipe = Pipe()
        let process: Process
        do {
            process = try launch(user == nil ? ["/bin/zsh", "-c", command] : ["/bin/zsh", "-lc", command], as: user) {
                $0.standardOutput = pipe
                $0.standardError = pipe
            }
        } catch {
            return Response(error: "can't start the command: \(error.localizedDescription)")
        }

        var pending: [UInt8] = []
        func emit(_ bytes: ArraySlice<UInt8>) {
            output(String(decoding: bytes, as: UTF8.self))
        }
        let reader = pipe.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty {
            pending.append(contentsOf: chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                emit(pending[..<newline])
                pending.removeSubrange(...newline)
            }
            while pending.count > outputChunk {
                emit(pending[..<outputChunk])
                pending.removeSubrange(..<outputChunk)
            }
        }
        if !pending.isEmpty {
            emit(pending[...])
        }
        process.waitUntilExit()
        return Response(exit: process.terminationStatus)
    }

    /// Starts `arguments` as `user` through sudo, in that account's home folder, or as this
    /// process when `user` is nil. Stdin is closed unless `configure` sets it.
    static func launch(_ arguments: [String], as user: String?, configure: (Process) -> Void) throws -> Process {
        let process = Process()
        if let user {
            guard let account = getpwnam(user) else { throw PaddockError("no user '\(user)' in the guest") }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-u", user, "-H"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        } else {
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
        }
        process.standardInput = FileHandle.nullDevice
        configure(process)
        try process.run()
        return process
    }

    /// Sends `request` over `fd`, a connection to the agent, and returns its answer. The answer
    /// comes from a guest that may be hostile, so it is size-limited and checked, not trusted.
    public static func ask(_ request: Request, over fd: Int32, timeout seconds: Int = 2) throws -> Response {
        UnixSocket.configure(fd, readTimeout: seconds)
        UnixSocket.writeLine(request.line, to: fd)
        guard let answer = UnixSocket.readLine(fd, limit: 4096) else {
            throw PaddockError("the guest agent didn't answer")
        }
        return try checked(answer)
    }

    /// Asks the agent over `fd` to run `command`, passes each output line to `output` as it
    /// arrives and returns the command's exit status. Waits as long as the command runs.
    public static func askToRun(_ command: String, over fd: Int32, output: (String) -> Void) throws -> Int32 {
        UnixSocket.configure(fd, readTimeout: nil)
        UnixSocket.writeLine(Request(op: "run", command: command).line, to: fd)
        while let answer = UnixSocket.readLine(fd) {
            let response = try checked(answer)
            if let exit = response.exit {
                return exit
            }
            if let text = response.output {
                output(text)
            }
        }
        throw PaddockError("the guest agent stopped answering before the command finished")
    }

    static func checked(_ answer: String) throws -> Response {
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(answer.utf8)) else {
            throw PaddockError("unreadable answer from the guest agent")
        }
        if let error = response.error {
            throw PaddockError("the guest agent refused: \(error.prefix(200))")
        }
        return response
    }

    /// Opens a vsock socket listening on `port` for the host. Works only inside a VM: a macOS
    /// host has no vsock transport and reaches guests through Virtualization.framework instead.
    public static func listen(port: UInt32) throws -> Int32 {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.error("create a vsock socket") }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = VMADDR_CID_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let error = UnixSocket.error("listen on vsock port \(port)")
            close(fd)
            throw error
        }
        return fd
    }
}
