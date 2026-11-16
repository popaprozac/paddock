import Darwin
import Dispatch
import Foundation
import Testing
@testable import PaddockCore

@Suite struct GuestAgentTests {
    func decode(_ line: String) throws -> GuestAgent.Response {
        try JSONDecoder().decode(GuestAgent.Response.self, from: Data(line.utf8))
    }

    @Test func healthReportsTheVersion() throws {
        let answer = GuestAgent.answer(#"{"op":"health"}"#)
        #expect(try decode(answer) == GuestAgent.Response(version: GuestAgent.version))
        #expect(!answer.contains("\n"))
    }

    @Test func unknownRequestsGetAnError() throws {
        #expect(try decode(GuestAgent.answer(#"{"op":"reboot"}"#)).error == "unknown request 'reboot'")
    }

    /// A socket pair stands in for the vsock connection; the far end answers like the agent.
    func askAgainst(_ agent: @escaping @Sendable (String) -> String?, _ request: GuestAgent.Request) throws -> GuestAgent.Response {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let (host, guest) = (fds[0], fds[1])
        defer { close(host) }
        DispatchQueue.global().async {
            if let line = UnixSocket.readLine(guest), let answer = agent(line) {
                UnixSocket.writeLine(answer, to: guest)
            }
            close(guest)
        }
        return try GuestAgent.ask(request, over: host, timeout: 1)
    }

    @Test func askGetsTheAgentsAnswer() throws {
        let response = try askAgainst({ GuestAgent.answer($0) }, GuestAgent.Request(op: "health"))
        #expect(response.version == GuestAgent.version)
    }

    @Test func askTurnsAnAgentErrorIntoAThrow() {
        #expect(throws: PaddockError.self) { try askAgainst({ GuestAgent.answer($0) }, GuestAgent.Request(op: "nope")) }
    }

    @Test func askRejectsSilenceAndGarbage() {
        #expect(throws: PaddockError.self) { try askAgainst({ _ in nil }, GuestAgent.Request(op: "health")) }
        #expect(throws: PaddockError.self) { try askAgainst({ _ in "not json" }, GuestAgent.Request(op: "health")) }
        #expect(throws: PaddockError.self) {
            try askAgainst({ _ in String(repeating: "x", count: 10_000) }, GuestAgent.Request(op: "health"))
        }
    }

    /// Runs `command` through `handle` over a real socket, the way the agent serves it, and
    /// returns the answer lines.
    func run(_ command: String?) throws -> [GuestAgent.Response] {
        let path = "/tmp/paddock-test-\(UUID().uuidString.prefix(8)).sock"
        let server = try LineServer(path: path, queue: DispatchQueue(label: "guest-agent-tests")) { line, responder in
            GuestAgent.handle(line, runAs: nil, responder: responder)
        }
        defer { server.stop() }
        let request = String(decoding: try JSONEncoder().encode(GuestAgent.Request(op: "run", command: command)), as: UTF8.self)
        var answers: [GuestAgent.Response] = []
        try LineClient.stream(request, to: path) { answers.append(try decode($0)); return true }
        return answers
    }

    @Test func runStreamsOutputThenTheExitStatus() throws {
        let answers = try run("echo one; echo two >&2; exit 3")
        #expect(answers == [
            GuestAgent.Response(output: "one"),
            GuestAgent.Response(output: "two"),
            GuestAgent.Response(exit: 3),
        ])
    }

    @Test func runSplitsLongLines() throws {
        let answers = try run("printf '%9000s' x")
        let output = answers.compactMap(\.output)
        #expect(output.map(\.count) == [GuestAgent.outputChunk, 9000 - GuestAgent.outputChunk])
        #expect(answers.last == GuestAgent.Response(exit: 0))
    }

    @Test func runNeedsACommand() throws {
        #expect(try run(nil) == [GuestAgent.Response(error: "run needs a command")])
    }

    @Test func unreadableRequestsGetAnError() throws {
        #expect(try decode(GuestAgent.answer("not json")).error == "unreadable request")
        #expect(try decode(GuestAgent.answer(#"{"nothing":1}"#)).error == "unreadable request")
    }
}
