import Foundation

/// An exclusive advisory lock on a bundle's `config.json`.
///
/// `run` and `bench` hold it while their VM is running and `clone` holds it while copying, so a
/// running golden image can't be cloned mid-write. The lock is released when this value is
/// deallocated or the process exits.
public final class BundleLock {
    private let descriptor: Int32

    public init(bundle: VMBundle) throws {
        let fd = open(bundle.configURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw PaddockError("no VM bundle at \(bundle.url.path)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw PaddockError("VM '\(bundle.name)' is in use by another paddock process; stop it first")
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
