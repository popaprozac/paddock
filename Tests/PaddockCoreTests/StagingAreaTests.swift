import Foundation
import Testing
@testable import PaddockCore

@Suite struct StagingAreaTests {
    func destination(in tmp: TemporaryDirectory) -> VMBundle {
        VMBundle(url: tmp.url.appendingPathComponent("vms/golden"))
    }

    @Test func commitMovesTheStagedBundleIntoPlace() throws {
        let tmp = try TemporaryDirectory()
        let target = destination(in: tmp)
        let staging = try StagingArea(for: target)
        try Data("disk".utf8).write(to: staging.bundle.diskURL)
        try staging.commit()
        #expect(try Data(contentsOf: target.diskURL) == Data("disk".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.bundle.url.path))
    }

    @Test func secondStagingForTheSameNameFails() throws {
        let tmp = try TemporaryDirectory()
        let first = try StagingArea(for: destination(in: tmp))
        #expect(throws: PaddockError.self) { try StagingArea(for: destination(in: tmp)) }
        withExtendedLifetime(first) {}
    }

    @Test func abandonedStagingIsRemoved() throws {
        let tmp = try TemporaryDirectory()
        let target = destination(in: tmp)
        var stagedURL: URL?
        do {
            let staging = try StagingArea(for: target)
            stagedURL = staging.bundle.url
            try Data("partial".utf8).write(to: staging.bundle.diskURL)
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(stagedURL).path))
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        _ = try StagingArea(for: target)
    }

    @Test func refusesAnExistingDestination() throws {
        let tmp = try TemporaryDirectory()
        let target = destination(in: tmp)
        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
        #expect(throws: PaddockError.self) { try StagingArea(for: target) }
    }

    @Test func clearsStagingLeftByAKilledProcess() throws {
        let tmp = try TemporaryDirectory()
        let target = destination(in: tmp)
        let stale = StagingArea.stagingURL(for: target)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("disk.img"))
        let staging = try StagingArea(for: target)
        #expect(!FileManager.default.fileExists(atPath: staging.bundle.diskURL.path))
    }
}
