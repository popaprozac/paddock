import Darwin
import Foundation
import os

/// A hidden working directory next to where a new bundle will live, such as `vms/.golden.partial`.
///
/// Install and clone build a bundle here and `commit()` renames it into place, so a bundle only
/// appears once it is complete. A lock file such as `vms/.golden.lock` stops two processes from
/// building the same name at once and is deleted when the staging area is released. Releasing
/// it without committing also deletes the staging directory, and the next attempt clears one
/// left behind by a killed process.
public final class StagingArea {
    public let bundle: VMBundle
    private let destination: VMBundle
    private let lockPath: String
    private let lockDescriptor: Int32
    private var committed = false

    /// Staging directories this process is building, for cleanup when it is interrupted.
    private static let inProgress = OSAllocatedUnfairLock(initialState: Set<URL>())

    public init(for destination: VMBundle) throws {
        let fileManager = FileManager.default
        let parent = destination.url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Only this account may read its VMs: a disk holds the image's account password and whatever
        // an agent did in it. Set every time, which also fixes a folder an earlier paddock left open.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let lockPath = parent.appendingPathComponent(".\(destination.name).lock").path
        let fd = open(lockPath, O_CREAT | O_RDONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw PaddockError("can't create \(lockPath): \(String(cString: strerror(errno)))")
        }
        // The holder deletes the lock file when done, so also check that the path still names
        // the file we locked; otherwise another process deleted it after we opened it.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, Self.isSameFile(fd, path: lockPath) else {
            close(fd)
            throw PaddockError("another paddock process is creating VM '\(destination.name)'")
        }

        let url = Self.stagingURL(for: destination)
        do {
            guard !fileManager.fileExists(atPath: destination.url.path) else {
                throw PaddockError("VM '\(destination.name)' already exists at \(destination.url.path)")
            }
            try? fileManager.removeItem(at: url)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            unlink(lockPath)
            close(fd)
            throw error
        }
        self.destination = destination
        self.lockPath = lockPath
        self.bundle = VMBundle(url: url)
        self.lockDescriptor = fd
        Self.inProgress.withLock { _ = $0.insert(url) }
    }

    public static func stagingURL(for destination: VMBundle) -> URL {
        destination.url.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.name).partial", isDirectory: true)
    }

    /// Moves the finished bundle into place.
    public func commit() throws {
        try FileManager.default.moveItem(at: bundle.url, to: destination.url)
        committed = true
        let url = bundle.url
        Self.inProgress.withLock { _ = $0.remove(url) }
    }

    static var inProgressURLs: Set<URL> {
        inProgress.withLock { $0 }
    }

    /// Deletes every staging directory this process is still building. Call it from an
    /// interrupt handler just before exiting, since `deinit` won't run then.
    public static func removeAllInProgress() {
        for url in inProgressURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit {
        if !committed {
            let url = bundle.url
            try? FileManager.default.removeItem(at: url)
            Self.inProgress.withLock { _ = $0.remove(url) }
        }
        unlink(lockPath)
        close(lockDescriptor)
    }

    private static func isSameFile(_ fd: Int32, path: String) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(fd, &opened) == 0 && stat(path, &named) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }
}
