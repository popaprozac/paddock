import Darwin
import Dispatch
import Foundation
import Testing
@testable import PaddockCore

@Suite struct GuestFilesTests {
    let tmp: TemporaryDirectory
    let files: URL
    let server: LineServer
    let path: String

    /// An agent on a Unix socket, storing files in a temporary folder.
    init() throws {
        tmp = try TemporaryDirectory()
        files = tmp.url.appendingPathComponent("paddock")
        path = "/tmp/paddock-test-\(UUID().uuidString.prefix(8)).sock"
        let folder = files.path
        server = try LineServer(path: path, queue: DispatchQueue(label: "guest-files-tests")) { line, responder in
            GuestAgent.handle(line, runAs: nil, files: folder, responder: responder)
        }
    }

    func connection() throws -> Int32 {
        try UnixSocket.connect(path)
    }

    func put(_ data: Data, as name: String) throws {
        let source = tmp.url.appendingPathComponent("source-\(UUID().uuidString)")
        try data.write(to: source)
        let fd = try connection()
        defer { close(fd) }
        try GuestAgent.askToPut(source, as: name, over: fd)
    }

    @Test func putThenGetRoundTrips() throws {
        let original = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try put(original, as: "in.bundle")
        let stored = try FileManager.default.attributesOfItem(atPath: files.appendingPathComponent("in.bundle").path)
        #expect((stored[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let back = tmp.url.appendingPathComponent("back")
        let fd = try connection()
        defer { close(fd) }
        #expect(try GuestAgent.askToGet("in.bundle", to: back, over: fd) == 3_000_000)
        #expect(try Data(contentsOf: back) == original)
        server.stop()
    }

    @Test(arguments: ["../escape", ".hidden", "a/b", ""])
    func refusesNamesOutsideTheFolder(_ name: String) throws {
        #expect(throws: PaddockError.self) { try put(Data("x".utf8), as: name) }
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("escape").path))
        server.stop()
    }

    /// The store stops at once, here because a folder has the name, and the agent's next write
    /// meets a closed pipe: the agent must live through it and say the file wasn't stored.
    @Test func putThatCantBeStoredFailsWithoutKillingTheAgent() throws {
        try FileManager.default.createDirectory(at: files.appendingPathComponent("in.bundle"), withIntermediateDirectories: true)
        let error = #expect(throws: PaddockError.self) { try put(Data(count: 3_000_000), as: "in.bundle") }
        #expect(error?.message.contains("can't store 'in.bundle'") == true, "\(error?.message ?? "")")
        server.stop()
    }

    @Test func getOfAMissingFileFails() throws {
        let back = tmp.url.appendingPathComponent("back")
        let fd = try connection()
        defer { close(fd) }
        #expect(throws: PaddockError.self) { try GuestAgent.askToGet("nothing-here", to: back, over: fd) }
        #expect(!FileManager.default.fileExists(atPath: back.path))
        server.stop()
    }

    @Test func getStopsAtTheLimitAndRemovesThePartFile() throws {
        try put(Data(count: 1000), as: "big")
        let back = tmp.url.appendingPathComponent("back")
        let fd = try connection()
        defer { close(fd) }
        #expect(throws: PaddockError.self) { try GuestAgent.askToGet("big", to: back, over: fd, limit: 100) }
        #expect(!FileManager.default.fileExists(atPath: back.path))
        server.stop()
    }
}
