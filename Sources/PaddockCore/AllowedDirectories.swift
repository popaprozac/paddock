import Foundation

/// The folders on this Mac an MCP agent may copy files from and to: those `paddock mcp` was
/// started with, and those its client offers as roots. A path counts as inside one only once
/// every symlink in it is resolved, so a link can't lead outside.
public struct AllowedDirectories: Sendable {
    public let folders: [String]

    /// `folders` resolved; one that doesn't exist, or isn't a folder, throws.
    public init(_ folders: [String]) throws {
        self.folders = try folders.map { folder in
            var isFolder: ObjCBool = false
            let resolved = URL(fileURLWithPath: folder).absoluteURL.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder), isFolder.boolValue else {
                throw PaddockError("\(folder) isn't a folder on this Mac")
            }
            return resolved
        }
    }

    /// `path`, resolved, if it's inside one of the folders; throws otherwise. `path` must be
    /// absolute. A file to be written may not exist yet: then its folder is resolved instead.
    public func check(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw PaddockError("\(path) isn't an absolute path on this Mac")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        guard folders.contains(where: { resolved.path == $0 || resolved.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
            throw PaddockError(folders.isEmpty
                ? "paddock mcp copies files only in folders it's allowed: start it with --allow-dir, or offer roots"
                : "\(path) isn't in a folder paddock mcp may copy files in: \(folders.joined(separator: ", "))")
        }
        return resolved
    }
}
