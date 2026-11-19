import Foundation
import Virtualization

/// A macOS restore image (IPSW) that Apple offers for this host, not yet downloaded.
public struct RemoteRestoreImage: Sendable {
    public let url: URL
    public let version: String
    public let build: String

    public init(url: URL, version: String, build: String) {
        self.url = url
        self.version = version
        self.build = build
    }

    /// Where the image lives once downloaded, named as Apple names it.
    public func cachedFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(url.lastPathComponent)
    }
}

/// A restore image on disk that this host can install, with the hardware it requires.
public struct LocalRestoreImage: Sendable {
    public let url: URL
    public let version: String
    public let build: String
    /// `VZMacHardwareModel.dataRepresentation` of the most featureful configuration this host supports.
    public let hardwareModel: Data
    public let minimumCPUCount: Int
    public let minimumMemorySize: UInt64
}

public enum RestoreImages {
    /// Asks Apple for the newest macOS restore image this host can run.
    public static func fetchLatestSupported() async throws -> RemoteRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: RemoteRestoreImage(
                        url: image.url,
                        version: versionString(image.operatingSystemVersion),
                        build: image.buildVersion))
                case .failure(let error):
                    continuation.resume(throwing: PaddockError(
                        "couldn't find the latest supported macOS: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Opens a downloaded IPSW and checks that this host can install it.
    public static func load(from url: URL) async throws -> LocalRestoreImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PaddockError("no restore image at \(url.path)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image):
                    let version = versionString(image.operatingSystemVersion)
                    guard let requirements = image.mostFeaturefulSupportedConfiguration,
                          requirements.hardwareModel.isSupported
                    else {
                        continuation.resume(throwing: PaddockError(
                            "this Mac can't run macOS \(version) (\(image.buildVersion)); update the host or use an older image"))
                        return
                    }
                    continuation.resume(returning: LocalRestoreImage(
                        url: url,
                        version: version,
                        build: image.buildVersion,
                        hardwareModel: requirements.hardwareModel.dataRepresentation,
                        minimumCPUCount: requirements.minimumSupportedCPUCount,
                        minimumMemorySize: requirements.minimumSupportedMemorySize))
                case .failure(let error):
                    // paddock's own downloads only appear once complete, so this is usually a copy cut short.
                    continuation.resume(throwing: PaddockError(
                        "\(url.path) is not a usable macOS restore image (\(error.localizedDescription)). A copy or "
                            + "download that stopped early leaves a file like this: delete it, and paddock install "
                            + "downloads the image again"))
                }
            }
        }
    }

    /// Downloads `remote` to `destination`. The file appears at `destination` only once complete.
    /// `progress` receives bytes written and bytes expected, on a background queue.
    public static func download(
        _ remote: RemoteRestoreImage,
        to destination: URL,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await RestoreImageDownload(destination: destination, progress: progress).run(from: remote.url)
    }

    static func versionString(_ version: OperatingSystemVersion) -> String {
        var string = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { string += ".\(version.patchVersion)" }
        return string
    }
}

/// One URLSession download. Mutable state is only touched on the session's serial delegate queue.
private final class RestoreImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(from url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.addOperation {
                self.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes `location` when this returns, so move it now. Stage under a hidden,
        // unique name first: if the move crosses volumes it copies, and a half-copied file must
        // never look like a cached image.
        let fileManager = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PaddockError("download failed: HTTP \(http.statusCode)")
            }
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
            try fileManager.moveItem(at: location, to: staging)
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch where fileManager.fileExists(atPath: destination.path) {
                // Another paddock process finished the same download first; keep its copy.
                try? fileManager.removeItem(at: staging)
            }
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(PaddockError("download failed: \(error.localizedDescription)")))
        } else {
            finish(.failure(PaddockError("download ended without a file")))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
