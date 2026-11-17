import ArgumentParser
import Dispatch
import Foundation
import MCP
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
            their pixels. A VM still held when the client goes away is handed back, and wiped.
            """)

    func run() async throws {
        let session = AgentSession()
        let server = Server(
            name: "paddock", version: Paddock.configuration.version,
            instructions: AgentSession.instructions,
            capabilities: .init(tools: .init(listChanged: false)))
        // Registered before the server starts, so a client's first request finds them.
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: AgentSession.tools) }
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
        try await server.start(transport: StdioTransport())
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
            return try await acquire(allow: arguments.strings("allow"))
        case "release":
            let vm = try heldVM().vm
            _ = try await blocking { try ServeClient.send(ServeRequest(op: "release", vm: vm)) }
            held = nil
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
            return [Self.text(try await run(try arguments.string("command")))]
        default:
            throw PaddockError("paddock has no tool named \(tool)")
        }
    }

    private func acquire(allow: [String]?) async throws -> [Tool.Content] {
        if let vm = held?.vm {
            throw PaddockError("this session already holds '\(vm)'; release it first")
        }
        guard !acquiring else { throw PaddockError("acquire is already waiting for a VM") }
        acquiring = true
        defer { acquiring = false }
        let response = try await blocking { try ServeClient.send(ServeRequest(op: "acquire", allow: allow)) }
        guard let vm = response.vm else { throw PaddockError("paddock serve handed out no VM") }
        let display: VMConfig.Display
        do {
            display = try PaddockHome.fromEnvironment().bundle(named: vm).readConfig().display
        } catch {
            _ = try? await blocking { try ServeClient.send(ServeRequest(op: "release", vm: vm)) }
            throw error
        }
        let scale = ScreenScale(guestWidth: display.widthInPixels, guestHeight: display.heightInPixels)
        held = (vm, scale)
        return [Self.text("""
            Acquired '\(vm)', a fresh macOS VM, at \(response.ip ?? "an unknown address"). Its screen is \
            \(scale.width)x\(scale.height) in screenshot pixels. Call release when you are done; it is wiped.
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
    /// exit status.
    private func run(_ command: String) async throws -> String {
        let vm = try heldVM().vm
        let limit = 20_000
        let (output, cut, status) = try await blocking { () -> (String, Bool, Int32?) in
            var output = "", count = 0, cut = false
            var status: Int32?
            try ServeClient.stream(ServeRequest(op: "exec", vm: vm, command: command)) { response in
                if let line = response.output {
                    output += line + "\n"
                    count += line.count + 1
                    if count > 2 * limit {  // trimmed now and then, so a long run never holds much
                        output = lastLines(of: output, within: limit)
                        count = output.count
                        cut = true
                    }
                }
                status = response.exit ?? status
                return status == nil
            }
            return count > limit ? (lastLines(of: output, within: limit), true, status) : (output, cut, status)
        }
        guard let status else { throw PaddockError("paddock serve closed the connection before the command finished") }
        return (cut ? "[output cut to its last \(limit) characters]\n" : "") + output + "[exit status \(status)]"
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
        paddock gives you a fresh macOS VM to work in. Call acquire first, then look with \
        screenshot or accessibility_tree and act with click, type_text, press_keys, scroll and \
        run_command. Coordinates are pixels of the screenshot from its top left, and frames in \
        the accessibility tree use the same pixels. Input returns once it is sent, so take a \
        screenshot to see what it did. Call release when you are done; the VM is wiped.
        """

    static let tools: [Tool] = [
        Tool(name: "acquire", description: """
            Take a fresh macOS VM. Call this first; a session holds one VM at a time. With a \
            paddock serve on its userspace network, the VM reaches only the host names in allow, \
            and nothing without it.
            """,
             inputSchema: schema(["allow": ["type": "array", "items": ["type": "string"],
                                            "description": "Host names the VM may reach, such as github.com or *.example.com."]])),
        Tool(name: "screenshot", description: "See the VM's screen, as a PNG whose pixels are the coordinates click and scroll take.",
             inputSchema: schema([:]), annotations: .init(readOnlyHint: true)),
        Tool(name: "accessibility_tree", description: """
            The accessibility tree of the app that has focus, as JSON: each element has its role, \
            its title, value and description when it has them, its frame as [x, y, width, height] \
            in screenshot pixels, and its children. Text is cut at 500 characters.
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
            right, up, down, home, end, pageup, pagedown and f1 to f12.
            """,
             inputSchema: schema(["keys": ["type": "array", "items": ["type": "string"]]], required: ["keys"])),
        Tool(name: "scroll", description: "Scroll the content at a point of the screenshot.",
             inputSchema: schema([
                 "x": ["type": "integer", "description": "Pixels from the left of the screenshot."],
                 "y": ["type": "integer", "description": "Pixels from the top of the screenshot."],
                 "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                 "lines": ["type": "integer", "description": "About how many lines; defaults to 5."],
             ], required: ["x", "y", "direction"])),
        Tool(name: "run_command", description: """
            Run a shell command in the VM, in a login shell as its user in their home folder, \
            and get its output and exit status. Long output is cut to its end.
            """,
             inputSchema: schema(["command": ["type": "string"]], required: ["command"])),
        Tool(name: "release", description: "Hand the VM back. paddock wipes it and the session can acquire another.",
             inputSchema: schema([:]), annotations: .init(destructiveHint: true)),
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

/// Runs blocking socket work on a thread of its own: an acquire can wait minutes for the slot,
/// and a command as long as it runs, which would otherwise hold one of Swift concurrency's few
/// threads.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
    }
}
