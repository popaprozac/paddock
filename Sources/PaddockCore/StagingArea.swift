import Darwin
import Foundation

/// A hidden working directory next to where a new bundle will live, such as `vms/.golden.partial`.
///
/// Install and clone build a bundle here and `commit()` renames it into place, so a bundle only
/// appears once it is complete. A lock file such as `vms/.golden.lock` stops two processes from
/// building the same name at once; it is left in place, empty, after use. Releasing the staging
/// area without committing deletes its directory, and the next attempt clears one left behind
/// by a killed process.
public final class StagingArea {
    public let bundle: VMBundle
    private let destination: VMBundle
    private let lockDescriptor: Int32
    private var committed = false

    public init(for destination: VMBundle) throws {
        let fileManager = FileManager.default
        let parent = destination.url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let lockPath = parent.appendingPathComponent(".\(destination.name).lock").path
        let fd = open(lockPath, O_CREAT | O_RDONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw PaddockError("can't create \(lockPath): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
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
            close(fd)
            throw error
        }
        self.destination = destination
        self.bundle = VMBundle(url: url)
        self.lockDescriptor = fd
    }

    public static func stagingURL(for destination: VMBundle) -> URL {
        destination.url.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.name).partial", isDirectory: true)
    }

    /// Moves the finished bundle into place.
    public func commit() throws {
        try FileManager.default.moveItem(at: bundle.url, to: destination.url)
        committed = true
    }

    deinit {
        if !committed {
            try? FileManager.default.removeItem(at: bundle.url)
        }
        close(lockDescriptor)
    }
}
