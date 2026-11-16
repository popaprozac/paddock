import Darwin
import Dispatch
import Foundation
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
        let server = try LineServer(path: path, queue: queue) { line, reply in reply("echo \(line)") }
        #expect(try LineClient.send("hello", to: path) == "echo hello")
        #expect(try LineClient.send("again", to: path) == "echo again")
        withExtendedLifetime(server) {}
    }

    @Test func canAnswerLater() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { line, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply("late \(line)") }
        }
        #expect(try LineClient.send("x", to: path) == "late x")
        withExtendedLifetime(server) {}
    }

    @Test func onlyTheOwnerCanConnect() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, reply in reply("") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        withExtendedLifetime(server) {}
    }

    @Test func refusesASecondServerOnTheSamePath() throws {
        let path = socketPath()
        let first = try LineServer(path: path, queue: queue) { _, reply in reply("first") }
        #expect(throws: PaddockError.self) {
            try LineServer(path: path, queue: queue) { _, reply in reply("second") }
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

        let server = try LineServer(path: path, queue: queue) { _, reply in reply("fresh") }
        #expect(try LineClient.send("x", to: path) == "fresh")
        withExtendedLifetime(server) {}
    }

    @Test func stoppingRemovesTheSocket() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, reply in reply("") }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: PaddockError.self) { try LineClient.send("x", to: path) }
    }

    @Test func clientFailsWithoutAServer() {
        #expect(throws: PaddockError.self) { try LineClient.send("x", to: socketPath()) }
    }

    @Test func rejectsPathsTooLongForASocket() {
        #expect(throws: PaddockError.self) { try UnixSocket.address("/tmp/" + String(repeating: "a", count: 200)) }
    }
}
