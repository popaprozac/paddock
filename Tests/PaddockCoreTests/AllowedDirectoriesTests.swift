import Foundation
import Testing
@testable import PaddockCore

@Suite struct AllowedDirectoriesTests {
    @Test func allowsOnlyPathsInsideTheFoldersOnceSymlinksAreResolved() throws {
        let inside = try TemporaryDirectory(), outside = try TemporaryDirectory()
        let secret = outside.url.appendingPathComponent("secret")
        try Data("x".utf8).write(to: secret)
        try Data("y".utf8).write(to: inside.url.appendingPathComponent("ok"))
        try FileManager.default.createSymbolicLink(at: inside.url.appendingPathComponent("link"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: inside.url.appendingPathComponent("away"), withDestinationURL: outside.url)
        let allowed = try AllowedDirectories([inside.url.path])

        #expect(throws: Never.self) { try allowed.check(inside.url.appendingPathComponent("ok").path) }
        #expect(throws: Never.self) { try allowed.check(inside.url.appendingPathComponent("new file").path) }
        #expect(throws: PaddockError.self) { try allowed.check(secret.path) }
        #expect(throws: PaddockError.self) { try allowed.check(inside.url.appendingPathComponent("link").path) }
        #expect(throws: PaddockError.self) { try allowed.check(inside.url.appendingPathComponent("away/new").path) }
        #expect(throws: PaddockError.self) { try allowed.check(inside.url.appendingPathComponent("../escape").path) }
        #expect(throws: PaddockError.self) { try allowed.check("relative/path") }
        #expect(throws: PaddockError.self) { try AllowedDirectories([secret.path]) }
        #expect(throws: PaddockError.self) { try AllowedDirectories([]).check(secret.path) }
    }
}
