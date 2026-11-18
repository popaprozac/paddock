import Darwin
import Dispatch
import Foundation
import Testing
@testable import PaddockCore

@Suite struct GuestAgentTests {
    func decode(_ line: String) throws -> GuestAgent.Response {
        try JSONDecoder().decode(GuestAgent.Response.self, from: Data(line.utf8))
    }

    @Test func acceptsOnlyTheHostsVsockConnections() {
        func peer(cid: UInt32, family: Int32 = AF_VSOCK) -> sockaddr_storage {
            var vsock = sockaddr_vm()
            vsock.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
            vsock.svm_family = sa_family_t(family)
            vsock.svm_cid = cid
            var storage = sockaddr_storage()
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_vm.self, capacity: 1) { $0.pointee = vsock }
            }
            return storage
        }
        let accepts = GuestAgent.onlyFromHost("test")
        #expect(accepts(peer(cid: UInt32(VMADDR_CID_HOST))))
        #expect(!accepts(peer(cid: 3)))  // the guest itself, through vsock loopback
        #expect(!accepts(peer(cid: UInt32(VMADDR_CID_HOST), family: AF_UNIX)))
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
        UnixSocket.configure(guest, readTimeout: nil)  // as LineServer does for real connections
        defer { close(host) }
        Thread.detachNewThread {
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
        try answers(to: GuestAgent.Request(op: "run", command: command))
    }

    /// Sends `request` through `handle` over a real socket and returns the answer lines.
    func answers(to request: GuestAgent.Request, runAs user: String? = nil) throws -> [GuestAgent.Response] {
        let path = "/tmp/paddock-test-\(UUID().uuidString.prefix(8)).sock"
        let server = try LineServer(path: path, queue: DispatchQueue(label: "guest-agent-tests")) { line, responder in
            GuestAgent.handle(line, runAs: user, files: NSTemporaryDirectory(), responder: responder)
        }
        defer { server.stop() }
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var answers: [GuestAgent.Response] = []
        try LineClient.stream(line, to: path) { answers.append(try decode($0)); return true }
        return answers
    }

    @Test func stateListsWhatHoldsThenExits() throws {
        let answers = try answers(to: GuestAgent.Request(op: "state"))
        #expect(answers.last == GuestAgent.Response(exit: 0))
        let held = answers.dropLast().compactMap(\.output)
        #expect(held.count == answers.count - 1)
        #expect(Set(held).isSubset(of: ["network", "session-helper"]))
    }

    @Test func stateChecksAddressesWithoutAShell() {
        #expect(GuestAgent.hasIPv4Address(on: "lo0"))
        #expect(!GuestAgent.hasIPv4Address(on: "no-such-interface"))
        #expect(GuestAgent.isIPv4Address("192.168.127.1"))
        #expect(!GuestAgent.isIPv4Address("fe80::1c1d:d3ff:fe9d:c064"))
        #expect(!GuestAgent.isIPv4Address("dns.example"))
    }

    @Test func runStreamsOutputThenTheExitStatus() throws {
        let answers = try run("echo one; echo two >&2; exit 3")
        #expect(answers == [
            GuestAgent.Response(output: "one"),
            GuestAgent.Response(output: "two"),
            GuestAgent.Response(exit: 3),
        ])
    }

    /// Runs as the workload account unless the request asks for root, the agent's own user. A
    /// workload account that doesn't exist shows which one a run used, without needing root.
    @Test func runsAsRootOnlyWhenAsked() throws {
        let workload = "paddock-no-such-user"
        let plain = try answers(to: .init(op: "run", command: "id -un"), runAs: workload)
        #expect(plain.last?.error?.contains("no user '\(workload)'") == true)
        let root = try answers(to: .init(op: "run", command: "id -un", user: "root"), runAs: workload)
        #expect(root.compactMap(\.output).last == NSUserName())
        #expect(root.last == GuestAgent.Response(exit: 0))
        let other = try answers(to: .init(op: "run", command: "id -un", user: "admin"), runAs: workload)
        #expect(other == [GuestAgent.Response(error: "run as 'root' or as the workload account, not 'admin'")])
    }

    @Test func asksForRootOnlyWhenTold() {
        #expect(GuestAgent.Request(op: "run", command: "id", user: "root").line.contains(#""as":"root""#))
        #expect(!GuestAgent.Request(op: "run", command: "id").line.contains(#""as""#))
    }

    @Test func runSplitsLongLines() throws {
        let answers = try run("printf '%9000s' x")
        let output = answers.compactMap(\.output)
        #expect(output.map(\.count) == [GuestAgent.outputChunk, 9000 - GuestAgent.outputChunk])
        #expect(answers.last == GuestAgent.Response(exit: 0))
    }

    /// The host's side of run, against the agent's own handler on the far end of a socket pair.
    @Test func askToRunStreamsOutputAndReturnsTheStatus() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let (host, guest) = (fds[0], fds[1])
        UnixSocket.configure(guest, readTimeout: nil)  // as LineServer does for real connections
        defer { close(host) }
        Thread.detachNewThread {
            if let line = UnixSocket.readLine(guest) {
                GuestAgent.handle(line, runAs: nil, files: NSTemporaryDirectory(), responder: Responder(fd: guest))
            }
        }
        var output: [String] = []
        let status = try GuestAgent.askToRun("echo hi; echo there; exit 4", over: host) { output.append($0) }
        #expect(output == ["hi", "there"])
        #expect(status == 4)
    }

    @Test func askToRunFailsWhenTheAgentStopsEarly() {
        #expect(throws: PaddockError.self) {
            var fds: [Int32] = [0, 0]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let (host, guest) = (fds[0], fds[1])
            UnixSocket.configure(guest, readTimeout: nil)
        UnixSocket.configure(guest, readTimeout: nil)  // as LineServer does for real connections
            defer { close(host) }
            Thread.detachNewThread {
                _ = UnixSocket.readLine(guest)
                UnixSocket.writeLine(#"{"output":"half"}"#, to: guest)
                close(guest)
            }
            _ = try GuestAgent.askToRun("anything", over: host) { _ in }
        }
    }

    @Test func runNeedsACommand() throws {
        #expect(try run(nil) == [GuestAgent.Response(error: "run needs a command")])
    }

    @Test func unreadableRequestsGetAnError() throws {
        #expect(try decode(GuestAgent.answer("not json")).error == "unreadable request")
        #expect(try decode(GuestAgent.answer(#"{"nothing":1}"#)).error == "unreadable request")
    }
}
