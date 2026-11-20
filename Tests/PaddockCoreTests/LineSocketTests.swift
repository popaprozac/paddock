import Darwin
import Dispatch
import Foundation
import os
import Testing
@testable import PaddockCore

@Suite struct LineSocketTests {
    let queue = DispatchQueue(label: "line-socket-tests")

    /// A short socket path: Unix socket paths are limited to 103 bytes, and the test
    /// temporary directory can be long.
    func socketPath() -> String {
        "/tmp/paddock-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func answersEachRequest() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { line, responder in responder.finish("echo \(line)") }
        #expect(try LineClient.send("hello", to: path) == "echo hello")
        #expect(try LineClient.send("again", to: path) == "echo again")
        withExtendedLifetime(server) {}
    }

    @Test func closesAConnectionItRefusesUnread() throws {
        let path = socketPath()
        let handled = OSAllocatedUnfairLock(initialState: false)
        let server = try LineServer(path: path, queue: queue, accepts: { _ in false }) { _, responder in
            handled.withLock { $0 = true }
            responder.finish("answered")
        }
        #expect(throws: PaddockError.self) { try LineClient.send("hello", to: path) }
        #expect(!handled.withLock { $0 })
        withExtendedLifetime(server) {}
    }

    @Test func canAnswerLater() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { line, responder in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { responder.finish("late \(line)") }
        }
        #expect(try LineClient.send("x", to: path) == "late x")
        withExtendedLifetime(server) {}
    }

    @Test func streamsManyLinesThenCloses() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { line, responder in
            Thread.detachNewThread {
                for index in 1...3 {
                    responder.send("\(line) \(index)")
                }
                responder.finish("done")
                responder.send("ignored after finish")
            }
        }
        var lines: [String] = []
        try LineClient.stream("go", to: path) { lines.append($0); return true }
        #expect(lines == ["go 1", "go 2", "go 3", "done"])
        withExtendedLifetime(server) {}
    }

    @Test func knowsWhenAWaitingClientHangsUp() async throws {
        let path = socketPath()
        let held = OSAllocatedUnfairLock<Responder?>(initialState: nil)
        let server = try LineServer(path: path, queue: queue) { _, responder in held.withLock { $0 = responder } }
        let client = try UnixSocket.connect(path)
        UnixSocket.writeLine("acquire", to: client)
        var responder: Responder?
        for _ in 0..<200 where responder == nil {
            try await Task.sleep(for: .milliseconds(10))
            responder = held.withLock { $0 }
        }
        let waiting = try #require(responder)
        #expect(!waiting.clientHungUp)
        close(client)
        var hungUp = false
        for _ in 0..<200 where !hungUp {
            hungUp = waiting.clientHungUp
            if !hungUp { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(hungUp)
        waiting.finish()
        withExtendedLifetime(server) {}
    }

    @Test func droppingTheResponderClosesTheConnection() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, _ in }
        #expect(throws: PaddockError.self) { try LineClient.send("x", to: path) }
        withExtendedLifetime(server) {}
    }

    @Test func onlyTheOwnerCanConnect() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, responder in responder.finish("") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        withExtendedLifetime(server) {}
    }

    @Test func refusesASecondServerOnTheSamePath() throws {
        let path = socketPath()
        let first = try LineServer(path: path, queue: queue) { _, responder in responder.finish("first") }
        #expect(throws: PaddockError.self) {
            try LineServer(path: path, queue: queue) { _, responder in responder.finish("second") }
        }
        #expect(try LineClient.send("x", to: path) == "first")
        withExtendedLifetime(first) {}
    }

    @Test func replacesASocketLeftByADeadServer() throws {
        let path = socketPath()
        // A bound socket that never listens stands in for one left behind by a killed process.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocket.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = try LineServer(path: path, queue: queue) { _, responder in responder.finish("fresh") }
        #expect(try LineClient.send("x", to: path) == "fresh")
        withExtendedLifetime(server) {}
    }

    @Test func stoppingRemovesTheSocket() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, responder in responder.finish("") }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: PaddockError.self) { try LineClient.send("x", to: path) }
    }

    /// The guest agent hands LineServer a vsock socket; a loopback TCP socket stands in for it.
    @Test func servesAnyListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        try #require(listening)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let server = LineServer(listening: fd, queue: queue, handle: { line, responder in responder.finish("tcp \(line)") },
                                onStop: { stopped.withLock { $0 = true } })

        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) == 0 }
        }
        try #require(connected)
        UnixSocket.writeLine("hi", to: client)
        #expect(UnixSocket.readLine(client) == "tcp hi")

        server.stop()
        #expect(stopped.withLock { $0 })
    }

    @Test func clientFailsWithoutAServer() {
        #expect(throws: PaddockError.self) { try LineClient.send("x", to: socketPath()) }
    }

    @Test func rejectsPathsTooLongForASocket() {
        #expect(throws: PaddockError.self) { try UnixSocket.address("/tmp/" + String(repeating: "a", count: 200)) }
    }

    /// A duplex pipe's input reaches the handler while it answers, and finishing the input is
    /// end of file there.
    @Test func aDuplexPipeCarriesInputToTheHandlerWhileItAnswers() async throws {
        let (responder, lines, input) = try ResponderPipe.makeDuplex()
        Thread.detachNewThread {
            #expect(!responder.clientHungUp)
            while let data = responder.receive(upTo: 64) {
                responder.send("got \(String(decoding: data, as: UTF8.self))")
            }
            responder.finish("ended")
        }
        input.send(Data("A".utf8))
        var answers: [String] = []
        for await line in lines {
            answers.append(line)
            if line == "got A" {
                input.send(Data("B".utf8))
            } else if line == "got B" {
                input.finish()
            }
        }
        #expect(answers == ["got A", "got B", "ended"])
    }

    /// A pipe made without an input sends the handler nothing and doesn't look hung up, as an
    /// acquire waiting for a warm VM relies on.
    @Test func aPlainPipeDoesntLookHungUp() throws {
        let (responder, _) = try ResponderPipe.make()
        Thread.sleep(forTimeInterval: 0.1)  // the input end is dropped on its own queue
        #expect(!responder.clientHungUp)
        responder.finish()
    }
}
