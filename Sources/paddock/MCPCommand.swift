import ArgumentParser
import Dispatch
import Foundation
import MCP
import os
import PaddockCore

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Give an agent VMs from paddock serve, as an MCP server on stdin and stdout.",
        discussion: """
            An MCP client starts 'paddock mcp' and speaks MCP to it over stdin and stdout; from \
            another Mac, start it through ssh. Its tools take a VM from serve, show its screen \
            and accessibility tree, click, type, press keys, scroll and run commands in it, and \
            hand it back. Screenshots are scaled to fit 1280x800, and every coordinate is in \
            their pixels. A VM still held when the client goes away is handed back, and wiped. \
            Small text files move in the tool calls themselves; files on this Mac move only in \
            folders named with --allow-dir, or offered by the client as roots.
            """)

    @Option(name: .customLong("allow-dir"),
            help: "A folder on this Mac the agent may copy files from and to with copy_into_vm and copy_out_of_vm (repeatable). Without one, and without roots from the client, those tools are off.")
    var allowDirs: [String] = []

    func run() async throws {
        let session = AgentSession(allowed: try AllowedDirectories(allowDirs))
        let server = Server(
            name: "paddock", version: Paddock.configuration.version,
            instructions: AgentSession.instructions,
            capabilities: .init(tools: .init(listChanged: false)))
        // Registered before the server starts, so a client's first request finds them.
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: await session.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await session.call(params.name, params.arguments ?? [:])
        }
        // A client that stops the server with a signal, or an ssh connection that drops, must
        // not leave the VM held: serve would keep it until it stops.
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task {
                    await session.releaseHeld()
                    Darwin.exit(128 + number)
                }
            }
            source.resume()
            return source
        }
        try await server.start(transport: StdioTransport()) { _, capabilities in
            // The folders a client offers can change, so they're asked for at each copy.
            guard capabilities.roots != nil else { return }
            await session.offerRoots {
                ((try? await server.listRoots()) ?? []).compactMap { root in
                    URL(string: root.uri).flatMap { $0.isFileURL ? $0.path : nil }
                }
            }
        }
        await server.waitUntilCompleted()  // until the client closes stdin
        await session.releaseHeld()
        withExtendedLifetime(signals) {}
    }
}

/// One agent's use of serve: at most one VM at a time, seen and driven in the pixels of its
/// scaled screenshots. Everything a tool returns from the guest, its screen, tree and command
/// output, comes from a machine the agent controls and is no more trustworthy than the agent.
actor AgentSession {
    private var held: (vm: String, scale: ScreenScale)?
    private var acquiring = false
    /// The folders on this Mac copy_into_vm and copy_out_of_vm may use: --allow-dir's, and the
    /// client's roots, if it offers any.
    private let allowed: AllowedDirectories
    private var roots: (@Sendable () async -> [String])?

    init(allowed: AllowedDirectories) {
        self.allowed = allowed
    }

    func offerRoots(_ roots: @escaping @Sendable () async -> [String]) {
        self.roots = roots
    }

    /// The tools, with the copy tools only where some folder on this Mac allows them.
    var tools: [Tool] {
        Self.tools + (allowed.folders.isEmpty && roots == nil ? [] : Self.copyTools)
    }

    /// What a tool returns, or its error as text for the agent.
    func call(_ tool: String, _ arguments: [String: Value]) async -> CallTool.Result {
        do {
            return .init(content: try await perform(tool, Arguments(values: arguments)), isError: false)
        } catch {
            return .init(content: [Self.text((error as? PaddockError)?.message ?? error.localizedDescription)], isError: true)
        }
    }

    /// Hands back the VM this session holds, if any.
    func releaseHeld() async {
        guard let vm = held?.vm else { return }
        held = nil
        _ = try? await blocking { try ServeClient.send(ServeRequest(op: "release", vm: vm)) }
    }

    private func perform(_ tool: String, _ arguments: Arguments) async throws -> [Tool.Content] {
        switch tool {
        case "acquire":
            let image = try arguments.string("image", default: "")
            return try await acquire(allow: arguments.strings("allow"), image: image.isEmpty ? nil : image)
        case "release":
            let vm = try heldVM().vm
            // Forgotten first: a VM that's gone, as after serve restarted, can't be released, and
            // the session must still be free to acquire another.
            held = nil
            _ = try await blocking { try ServeClient.send(ServeRequest(op: "release", vm: vm)) }
            return [Self.text("Handed '\(vm)' back; serve wipes it.")]
        case "screenshot":
            return [try await screenshot()]
        case "accessibility_tree":
            return [Self.text(try await accessibilityTree())]
        case "click":
            let (vm, scale) = try heldVM()
            let x = try arguments.int("x"), y = try arguments.int("y")
            let point = try scale.guestPoint(x: x, y: y)
            let button = try arguments.string("button", default: "left")
            guard ["left", "right"].contains(button) else { throw PaddockError("button is left or right") }
            let count = try arguments.bool("double") ? 2 : 1
            try await input(vm, InputAction(kind: "click", x: point.x, y: point.y, button: button, count: count))
            return [Self.text("Clicked at \(x), \(y).")]
        case "type_text":
            let text = try arguments.string("text")
            try await input(try heldVM().vm, InputAction(kind: "type", text: text))
            return [Self.text("Typed \(text.count) characters.")]
        case "press_keys":
            let keys = try arguments.strings("keys") ?? []
            try await input(try heldVM().vm, InputAction(kind: "key", keys: keys))
            return [Self.text("Pressed \(keys.joined(separator: " ")).")]
        case "scroll":
            let (vm, scale) = try heldVM()
            let x = try arguments.int("x"), y = try arguments.int("y")
            let point = try scale.guestPoint(x: x, y: y)
            let lines = try arguments.int("lines", default: 5)
            guard (1...1000).contains(lines) else { throw PaddockError("lines is 1 to 1,000") }
            let (down, right): (Int, Int)
            switch try arguments.string("direction") {
            case "down": (down, right) = (lines, 0)
            case "up": (down, right) = (-lines, 0)
            case "right": (down, right) = (0, lines)
            case "left": (down, right) = (0, -lines)
            default: throw PaddockError("direction is up, down, left or right")
            }
            try await input(vm, InputAction(kind: "scroll", x: point.x, y: point.y, down: down, right: right))
            return [Self.text("Scrolled \(lines) lines at \(x), \(y).")]
        case "run_command":
            let timeout = try arguments.int("timeout", default: 120)
            guard (1...3600).contains(timeout) else { throw PaddockError("timeout is 1 to 3,600 seconds") }
            return [Self.text(try await run(try arguments.string("command"), timeout: timeout))]
        case "write_file_in_vm":
            return [Self.text(try await writeFile(try arguments.string("path"), try arguments.string("content")))]
        case "read_file_from_vm":
            return [Self.text(try await readFile(try arguments.string("path")))]
        case "copy_into_vm":
            return [Self.text(try await copyIn(try arguments.string("host_path"), to: try arguments.string("path")))]
        case "copy_out_of_vm":
            return [Self.text(try await copyOut(try arguments.string("path"), to: try arguments.string("host_path")))]
        default:
            throw PaddockError("paddock has no tool named \(tool)")
        }
    }

    private func acquire(allow: [String]?, image: String?) async throws -> [Tool.Content] {
        if let vm = held?.vm {
            // One that lapsed, or went with a serve that restarted, isn't held any more.
            guard (try? await blocking { try ServeClient.send(ServeRequest(op: "renew", vm: vm)) }) == nil else {
                throw PaddockError("this session already holds '\(vm)'; release it first")
            }
            held = nil
        }
        guard !acquiring else { throw PaddockError("acquire is already waiting for a VM") }
        acquiring = true
        defer { acquiring = false }
        let response = try await blocking { try ServeClient.send(ServeRequest(op: "acquire", allow: allow), image: image) }
        guard let vm = response.vm else { throw PaddockError("paddock serve handed out no VM") }
        // From serve's answer: the VM's files are on whichever Mac the pool put it on.
        guard let os = response.os, let hasScreen = response.screen, let width = response.width, let height = response.height
        else {
            _ = try? await blocking { try ServeClient.send(ServeRequest(op: "release", vm: vm)) }
            throw PaddockError("the Mac serving '\(vm)' runs a paddock too old to say what the VM is: update paddock there")
        }
        let scale = ScreenScale(guestWidth: width, guestHeight: height)
        held = (vm, scale)
        let screen = !hasScreen ? "It has no screen; work in it with run_command."
            : "Its screen is \(scale.width)x\(scale.height) in screenshot pixels."
        return [Self.text("""
            Acquired '\(vm)', a fresh \(os == "linux" ? "Linux" : os == "windows" ? "Windows" : "macOS") VM, at \(response.ip ?? "an unknown address"). \
            \(screen) Call release when you are done; it is wiped.
            """)]
    }

    private func screenshot() async throws -> Tool.Content {
        let (vm, scale) = try heldVM()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paddock-mcp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await blocking { try ServeClient.send(ServeRequest(op: "screenshot", vm: vm, result: url.path)) }
        var image = try FrameImage.read(url)
        if image.width != scale.width || image.height != scale.height {
            image = try FrameImage.scaled(image, width: scale.width, height: scale.height)
        }
        return .image(data: try FrameImage.pngData(image).base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)
    }

    private func accessibilityTree() async throws -> String {
        let (vm, scale) = try heldVM()
        let lines = try await blocking { () -> [String] in
            var lines: [String] = []
            try ServeClient.stream(ServeRequest(op: "axtree", vm: vm)) { response in
                if let output = response.output { lines.append(output) }
                return response.exit == nil
            }
            return lines
        }
        let tree = try JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8))
        let json = try JSONSerialization.data(withJSONObject: scale.scalingFrames(of: tree), options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: json, as: UTF8.self)
    }

    /// Runs `command` in the VM and returns its output, its last lines if it is long, and its
    /// exit status, or what it printed by `timeout` seconds if it hasn't finished by then.
    /// shortcut: a command past its time limit goes on running in the VM, since the guest agent
    /// can't stop one; the VM is wiped on release. Give the agent a way to stop it if that matters.
    private func run(_ command: String, timeout: Int) async throws -> String {
        let vm = try heldVM().vm
        let output = CommandOutput()
        let status: Int32
        do {
            status = try await blocking(seconds: timeout) {
                try ServeClient.run(ServeRequest(op: "exec", vm: vm, command: command)) { output.append($0) }.status
            }
        } catch is TimedOut {
            return output.text + "[still running after \(timeout) s, so paddock stopped waiting; it may go on running in the VM]"
        }
        return output.text + "[exit status \(status)]"
    }

    /// The most write_file_in_vm and read_file_from_vm move through the call itself.
    static let fileLimit = 1 << 20

    /// Writes `content` to `path` in the VM through a file of paddock's own, never one the agent
    /// names on this Mac.
    private func writeFile(_ path: String, _ content: String) async throws -> String {
        let vm = try heldVM().vm
        let data = Data(content.utf8)
        guard data.count <= Self.fileLimit else {
            throw PaddockError("content is over 1 MiB, the most write_file_in_vm takes; use copy_into_vm")
        }
        guard let name = GuestCopy.lastComponent(of: path) else {
            throw PaddockError("'\(path)' names a folder; give the path of a file")
        }
        let file = try Self.privateFile(with: data)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await blocking { try ServeClient.send(ServeRequest(op: "put", vm: vm, file: file.path, path: path, name: name)) }
        return "Wrote \(data.count) bytes to \(path) in the VM."
    }

    /// The text of `path` in the VM, through a file of paddock's own.
    private func readFile(_ path: String) async throws -> String {
        let vm = try heldVM().vm
        let file = try Self.privateFile(with: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await blocking { try ServeClient.send(ServeRequest(op: "get", vm: vm, result: file.path, path: path)) }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.fileLimit else {
            throw PaddockError("\(path) is over 1 MiB, the most read_file_from_vm returns; use copy_out_of_vm")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PaddockError("\(path) isn't UTF-8 text; use copy_out_of_vm")
        }
        return text
    }

    /// Copies a file on this Mac, in an allowed folder, to `path` in the VM.
    private func copyIn(_ hostPath: String, to path: String) async throws -> String {
        let vm = try heldVM().vm
        let file = try await allowedFolders().check(hostPath)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw PaddockError("\(hostPath) isn't a file")
        }
        _ = try await blocking {
            try ServeClient.send(ServeRequest(op: "put", vm: vm, file: file.path, path: path, name: file.lastPathComponent))
        }
        return "Copied \(hostPath) to \(path.isEmpty ? "the home folder" : path) in the VM."
    }

    /// Copies `path` in the VM to a file on this Mac, in an allowed folder; a folder takes the
    /// file under its own name.
    private func copyOut(_ path: String, to hostPath: String) async throws -> String {
        let vm = try heldVM().vm
        guard let name = GuestCopy.lastComponent(of: path) else {
            throw PaddockError("'\(path)' names a folder; give the path of a file in the VM")
        }
        let folders = try await allowedFolders()
        var file = try folders.check(hostPath)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), isFolder.boolValue {
            file = try folders.check(file.appendingPathComponent(name).path)
        }
        let destination = file.path
        _ = try await blocking { try ServeClient.send(ServeRequest(op: "get", vm: vm, result: destination, path: path)) }
        return "Copied \(path) in the VM to \(destination)."
    }

    /// --allow-dir's folders and the client's roots, as they are now.
    private func allowedFolders() async throws -> AllowedDirectories {
        let offered = await roots?() ?? []
        return try AllowedDirectories(allowed.folders + offered.filter { folder in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue
        })
    }

    /// A file only this user can read, in the temporary folder, holding `data`.
    private static func privateFile(with data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paddock-mcp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PaddockError("can't make a file for the copy in \(file.deletingLastPathComponent().path)")
        }
        return file
    }

    private func input(_ vm: String, _ action: InputAction) async throws {
        _ = try await blocking { try ServeClient.send(ServeRequest(op: "input", vm: vm, input: action)) }
    }

    private func heldVM() throws -> (vm: String, scale: ScreenScale) {
        guard let held else { throw PaddockError("this session holds no VM; call acquire first") }
        return held
    }

    private static func text(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    static let instructions = """
        paddock gives you a fresh VM to work in. Call acquire first, then look with \
        screenshot or accessibility_tree and act with click, type_text, press_keys, scroll and \
        run_command; a Linux VM without a desktop has no screen, and takes only run_command. Move \
        small text files with write_file_in_vm and read_file_from_vm. Coordinates are pixels of the screenshot from its top left, and frames in \
        the accessibility tree use the same pixels. Input returns once it is sent, so take a \
        screenshot to see what it did. Call release when you are done; the VM is wiped.
        """

    static let tools: [Tool] = [
        Tool(name: "acquire", description: """
            Take a fresh VM: macOS, Linux or Windows. Call this first; a session holds one VM at a \
            time. In a pool that serves several golden images, image picks one. With a paddock \
            serve on its userspace network, the VM reaches only the host names in allow, and \
            nothing without it. A VM no tool uses for an hour goes back, and later calls for it \
            fail saying so; acquire again then.
            """,
             inputSchema: schema([
                 "image": ["type": "string",
                           "description": "In a pool of several images, the golden image to clone, such as golden or ubuntu-desktop."],
                 "allow": ["type": "array", "items": ["type": "string"],
                           "description": "Host names the VM may reach, such as github.com or *.example.com."],
             ])),
        Tool(name: "screenshot", description: "See the VM's screen, as a PNG whose pixels are the coordinates click and scroll take.",
             inputSchema: schema([:]), annotations: .init(readOnlyHint: true)),
        Tool(name: "accessibility_tree", description: """
            The accessibility tree of the app that has focus, as JSON: each element has its role, \
            its title, value and description when it has them, its frame as [x, y, width, height] \
            in screenshot pixels, and its children. Text is cut at 500 characters. A Linux VM's \
            roles are AT-SPI's names, such as push button, and a Windows VM's are UI Automation's \
            control types, such as Button.
            """,
             inputSchema: schema([:]), annotations: .init(readOnlyHint: true)),
        Tool(name: "click", description: "Click at a point of the screenshot.",
             inputSchema: schema([
                 "x": ["type": "integer", "description": "Pixels from the left of the screenshot."],
                 "y": ["type": "integer", "description": "Pixels from the top of the screenshot."],
                 "button": ["type": "string", "enum": ["left", "right"], "description": "Defaults to left."],
                 "double": ["type": "boolean", "description": "Click twice in a row, as to select a word."],
             ], required: ["x", "y"])),
        Tool(name: "type_text", description: """
            Type text, as key presses, into whatever has the keyboard focus, at about 100 \
            characters a second. Only characters a US keyboard types work.
            """,
             inputSchema: schema(["text": ["type": "string"]], required: ["text"])),
        Tool(name: "press_keys", description: """
            Press key combinations in order. Each is modifiers and one key joined by +, such as \
            cmd+s, cmd+shift+z, return or escape. Modifiers are cmd, ctrl, opt and shift; keys are \
            characters, plus for +, or return, tab, space, delete, forwarddelete, escape, left, \
            right, up, down, home, end, pageup, pagedown and f1 to f12. In a Linux VM, cmd is the \
            Super key, and in a Windows VM the Windows key, so shortcuts there use ctrl, as ctrl+s.
            """,
             inputSchema: schema(["keys": ["type": "array", "items": ["type": "string"]]], required: ["keys"])),
        Tool(name: "scroll", description: "Scroll the content at a point of the screenshot.",
             inputSchema: schema([
                 "x": ["type": "integer", "description": "Pixels from the left of the screenshot."],
                 "y": ["type": "integer", "description": "Pixels from the top of the screenshot."],
                 "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                 "lines": ["type": "integer", "description": "About how many lines, 1 to 1,000; defaults to 5."],
             ], required: ["x", "y", "direction"])),
        Tool(name: "run_command", description: """
            Run a shell command in the VM as its user, in their home folder: in a login shell on \
            macOS and Linux, in cmd.exe as an administrator on Windows. Get its output and exit \
            status. Long output is cut to its end. A command still \
            running after timeout seconds returns what it printed so far and goes on running.
            """,
             inputSchema: schema([
                 "command": ["type": "string"],
                 "timeout": ["type": "integer", "description": "Seconds to wait, 1 to 3600; defaults to 120."],
             ], required: ["command"])),
        Tool(name: "write_file_in_vm", description: """
            Write text to a file in the VM, as its account: path is absolute, or relative to the \
            account's home. Up to 1 MiB; a file already there is replaced.
            """,
             inputSchema: schema([
                 "path": ["type": "string", "description": "The file in the VM, such as work/notes.txt or /tmp/run.sh."],
                 "content": ["type": "string"],
             ], required: ["path", "content"])),
        Tool(name: "read_file_from_vm", description: """
            Read a text file in the VM, up to 1 MiB: path is absolute, or relative to the \
            account's home. What it returns comes from the VM, and is no more trustworthy than it.
            """,
             inputSchema: schema(["path": ["type": "string"]], required: ["path"]), annotations: .init(readOnlyHint: true)),
        Tool(name: "release", description: "Hand the VM back. paddock wipes it and the session can acquire another.",
             inputSchema: schema([:]), annotations: .init(destructiveHint: true)),
    ]

    /// Listed only when some folder on this Mac allows them: --allow-dir's, or the client's roots.
    static let copyTools: [Tool] = [
        Tool(name: "copy_into_vm", description: """
            Copy a file from this Mac into the VM, up to 4 GB, or 1 GB through a pool. host_path is absolute, in a folder \
            paddock may copy from: one named with --allow-dir, or a root of the client's. path, \
            in the VM, is absolute or relative to the account's home; "" is the home folder, and a \
            folder takes the file under its own name.
            """,
             inputSchema: schema([
                 "host_path": ["type": "string", "description": "The file on this Mac, as an absolute path."],
                 "path": ["type": "string", "description": "Where it goes in the VM."],
             ], required: ["host_path", "path"])),
        Tool(name: "copy_out_of_vm", description: """
            Copy a file from the VM to this Mac, up to 4 GB, or 1 GB through a pool. path, in the VM, is absolute or \
            relative to the account's home. host_path is absolute, in a folder paddock may copy \
            to: one named with --allow-dir, or a root of the client's; a folder takes the file \
            under its own name, and a file there is replaced.
            """,
             inputSchema: schema([
                 "path": ["type": "string", "description": "The file in the VM."],
                 "host_path": ["type": "string", "description": "Where it goes on this Mac, as an absolute path."],
             ], required: ["path", "host_path"])),
    ]

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }
}

/// A tool call's arguments, read with the errors an agent can act on.
private struct Arguments {
    let values: [String: Value]

    func int(_ name: String, default fallback: Int? = nil) throws -> Int {
        switch values[name] {
        case .int(let value)?: return value
        case .double(let value)? where value == value.rounded() && abs(value) < 1e9: return Int(value)
        case nil where fallback != nil: return fallback!
        default: throw PaddockError("\(name) must be a whole number")
        }
    }

    func string(_ name: String, default fallback: String? = nil) throws -> String {
        if let value = values[name]?.stringValue { return value }
        if values[name] == nil, let fallback { return fallback }
        throw PaddockError("\(name) must be a string")
    }

    func bool(_ name: String) throws -> Bool {
        guard let value = values[name] else { return false }
        guard let bool = value.boolValue else { throw PaddockError("\(name) must be true or false") }
        return bool
    }

    func strings(_ name: String) throws -> [String]? {
        guard let value = values[name] else { return nil }
        guard let strings = value.arrayValue?.compactMap(\.stringValue), strings.count == value.arrayValue?.count else {
            throw PaddockError("\(name) must be a list of strings")
        }
        return strings
    }
}

/// The end of `text`, at most `limit` characters, from the start of a line if it has one.
private func lastLines(of text: String, within limit: Int) -> String {
    let tail = text.suffix(limit)
    guard let newline = tail.dropLast().firstIndex(of: "\n") else { return String(tail) }
    return String(tail[tail.index(after: newline)...])
}

/// What a command has printed, cut to its last 20,000 characters, from the start of a line, once
/// it is longer, shared by the thread that reads it and the session that returns it.
private final class CommandOutput: Sendable {
    private static let limit = 20_000
    private let state = OSAllocatedUnfairLock(initialState: (text: "", count: 0, cut: false))

    func append(_ line: String) {
        state.withLock { output in
            output.text += line + "\n"
            output.count += line.count + 1
            if output.count > 2 * Self.limit {  // trimmed now and then, so a long run never holds much
                output.text = lastLines(of: output.text, within: Self.limit)
                output.count = output.text.count
                output.cut = true
            }
        }
    }

    var text: String {
        state.withLock { output in
            guard output.cut || output.count > Self.limit else { return output.text }
            return "[output cut to its last \(Self.limit) characters]\n" + lastLines(of: output.text, within: Self.limit)
        }
    }
}

private struct TimedOut: Error {}

/// Runs blocking socket work on a thread of its own: an acquire can wait minutes for the slot,
/// and a command as long as it runs, which would otherwise hold one of Swift concurrency's few
/// threads. With `seconds`, it throws TimedOut once they pass, leaving the work to finish alone.
private func blocking<T: Sendable>(seconds: Int? = nil, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let pending = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
    let finish: @Sendable (Result<T, any Error>) -> Void = { result in
        let continuation = pending.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        continuation?.resume(with: result)
    }
    return try await withCheckedThrowingContinuation { continuation in
        pending.withLock { $0 = continuation }
        Thread.detachNewThread { finish(Result { try work() }) }
        if let seconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { finish(.failure(TimedOut())) }
        }
    }
}
