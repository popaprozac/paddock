import Foundation
import Testing
@testable import PaddockCore

@Suite struct AskpassServerTests {
    @Test func handsOutThePasswordOverItsSocket() throws {
        let server = try AskpassServer(password: "correct horse", helper: "/usr/local/bin/paddock")
        defer { server.stop() }
        let socket = try #require(server.environment["PADDOCK_ASKPASS"])
        #expect(try LineClient.send("password", to: socket) == "correct horse")
        #expect(server.environment["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @Test func writesAScriptOnlyItsOwnerCanUseThatRunsTheHelper() throws {
        let server = try AskpassServer(password: "x", helper: "/tmp/it's paddock")
        defer { server.stop() }
        let script = try #require(server.environment["SSH_ASKPASS"])
        #expect(try String(contentsOfFile: script, encoding: .utf8) == "#!/bin/sh\nexec '/tmp/it'\\''s paddock' askpass\n")
        let folder = URL(fileURLWithPath: script).deletingLastPathComponent().path
        let mode = try #require(FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int)
        #expect(mode == 0o700)
    }

    @Test func leavesNothingBehindOnceStopped() throws {
        let server = try AskpassServer(password: "x", helper: "/usr/local/bin/paddock")
        let folder = URL(fileURLWithPath: try #require(server.environment["SSH_ASKPASS"])).deletingLastPathComponent().path
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: folder))
    }
}
