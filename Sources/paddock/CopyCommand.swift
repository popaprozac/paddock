import ArgumentParser
import Foundation
import PaddockCore

struct Copy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy a file into a VM that acquire handed out, or out of one.",
        discussion: """
            One of the two is <vm>:<path>, in the VM: absolute, or relative to the guest account's \
            home, as scp's are. <vm>: alone is the home folder, and a folder, in the VM or on this \
            Mac, takes the file under its own name. The file is the account's in the VM, as if it \
            had copied it. Files only, up to 4 GB, or 1 GB through the pool.
            """)

    @Argument(help: "The file to copy: a path on this Mac, or <vm>:<path>.")
    var source: String

    @Argument(help: "Where to copy it: <vm>:<path>, or a path on this Mac.")
    var destination: String

    @OptionGroup var target: Target

    func run() throws {
        switch (GuestCopy.split(source), GuestCopy.split(destination)) {
        case let (nil, (vm, path)?):
            let file = URL(fileURLWithPath: source).absoluteURL.standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
                throw PaddockError("\(source) isn't a file on this Mac; paddock cp copies files")
            }
            _ = try ServeClient.send(ServeRequest(op: "put", vm: vm, file: file.path, path: path, name: file.lastPathComponent),
                                     local: target.local)
        case let ((vm, path)?, nil):
            guard let name = GuestCopy.lastComponent(of: path) else {
                throw PaddockError("name a file in the VM to copy, as \(vm):<path>; paddock cp copies files")
            }
            var file = URL(fileURLWithPath: destination).absoluteURL.standardizedFileURL
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), isFolder.boolValue {
                file.appendPathComponent(name)
            }
            _ = try ServeClient.send(ServeRequest(op: "get", vm: vm, result: file.path, path: path), local: target.local)
        default:
            throw ValidationError("give one path in a VM, as <vm>:<path>, and one on this Mac")
        }
    }
}

/// `paddock cp`'s two ways, through the agent's put and get and a move as the guest's account
/// (see GuestCopy).
extension HeadlessVM {
    /// Copies the file at `file` on this Mac to `path` in the guest. `name` is the file's own name,
    /// for a `path` that is a folder there.
    func copyIn(_ file: URL, to path: String, name: String) async throws {
        let windows = config.isWindows
        if let problem = GuestCopy.problem(with: path, windows: windows) ?? GuestCopy.problem(with: name, windows: windows) {
            throw PaddockError(problem)
        }
        let staging = GuestCopy.stagingName()
        try await putInGuest(file, as: staging)
        _ = try await runStep(GuestCopy.moveIn(staging, to: path, name: name, windows: windows),
                              "put the file at \(path.isEmpty ? "the home folder" : path)")
    }

    /// Copies the file at `path` in the guest to `file` on this Mac.
    func copyOut(_ path: String, to file: URL) async throws {
        let windows = config.isWindows
        if let problem = GuestCopy.problem(with: path, windows: windows) {
            throw PaddockError(problem)
        }
        let staging = GuestCopy.stagingName()
        defer {
            Task { _ = try? await self.runInGuest(GuestCopy.remove(staging, windows: windows), output: { _ in }) }
        }
        _ = try await runStep(GuestCopy.stageOut(path, as: staging, windows: windows), "read \(path)")
        try await getFromGuest(staging, to: file)
    }
}
