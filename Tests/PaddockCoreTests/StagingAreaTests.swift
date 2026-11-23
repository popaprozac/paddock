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

    @Test func onlyTheOwnerCanReadTheVMsFolder() throws {
        let tmp = try TemporaryDirectory()
        let target = destination(in: tmp)
        let vms = target.url.deletingLastPathComponent()
        // As paddock made it before, readable by everyone.
        try FileManager.default.createDirectory(at: vms, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let staging = try StagingArea(for: target)
        let mode = try FileManager.default.attributesOfItem(atPath: vms.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        withExtendedLifetime(staging) {}
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

    @Test func leavesNoLockFileBehind() throws {
        let tmp = try TemporaryDirectory()
        let vms = tmp.url.appendingPathComponent("vms")
        do {
            let committed = try StagingArea(for: destination(in: tmp))
            try committed.commit()
        }
        do { _ = try StagingArea(for: VMBundle(url: vms.appendingPathComponent("abandoned"))) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: vms.path) == ["golden"])
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

@Suite struct StagingAreaInterruptTests {
    // removeAllInProgress() is process-wide and tests run in parallel, so this checks what it
    // would remove instead of calling it.
    @Test func tracksOnlyStagingStillInProgress() throws {
        let tmp = try TemporaryDirectory()
        let vms = tmp.url.appendingPathComponent("vms")

        let committed = try StagingArea(for: VMBundle(url: vms.appendingPathComponent("a")))
        #expect(StagingArea.inProgressURLs.contains(committed.bundle.url))
        try committed.commit()
        #expect(!StagingArea.inProgressURLs.contains(committed.bundle.url))

        var abandonedURL: URL?
        do {
            let abandoned = try StagingArea(for: VMBundle(url: vms.appendingPathComponent("b")))
            abandonedURL = abandoned.bundle.url
            #expect(StagingArea.inProgressURLs.contains(abandoned.bundle.url))
        }
        #expect(!StagingArea.inProgressURLs.contains(try #require(abandonedURL)))
    }
}
