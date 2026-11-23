import Darwin
import Foundation

/// Moving files between the host and the agent's `~/paddock` folder in the guest, so a git
/// bundle can go in and come back out without a network path into the guest.
///
/// The workload account reads and writes these files, never the root agent itself, so a
/// guest that plants a symlink in the folder only reaches what that account could anyway.
extension GuestAgent {
    /// Largest file either side accepts.
    public static let maxFileSize: Int64 = 4 << 30
    static let fileChunk = 1 << 20

    /// The folder `put` and `get` use: `~/paddock` in `user`'s home.
    public static func filesDirectory(for user: String) -> String? {
        getpwnam(user).map { String(cString: $0.pointee.pw_dir) + "/paddock" }
    }

    /// One plain path component, so a request can't name anything outside the folder.
    static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    /// Agent side of `put`: stores the `size` bytes that follow the request as `name`, with
    /// owner-only permissions.
    static func put(_ name: String, size: Int64, into directory: String, as user: String?, from responder: Responder) -> Response {
        let input = Pipe()
        let process: Process
        do {
            process = try launch(["/bin/sh", "-c", #"umask 077 && mkdir -p "$1" && cat > "$1/$2""#, "sh", directory, name], as: user) {
                $0.standardInput = input
                $0.standardOutput = FileHandle.nullDevice
                $0.standardError = FileHandle.nullDevice
            }
        } catch {
            return Response(error: "can't store '\(name)': \(error.localizedDescription)")
        }
        // A store that stopped early, as on a full disk, fails the write instead of killing the agent
        // with SIGPIPE, and every command running through it.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        var remaining = size
        while remaining > 0, let chunk = responder.receive(upTo: Int(min(remaining, Int64(fileChunk)))) {
            guard (try? input.fileHandleForWriting.write(contentsOf: chunk)) != nil else { break }
            remaining -= Int64(chunk.count)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        // The store's failure first: it's why the bytes stopped, if they did.
        guard process.terminationStatus == 0 else { return Response(error: "can't store '\(name)' in the guest") }
        if remaining > 0 {
            return Response(error: "'\(name)' stopped after \(size - remaining) of \(size) bytes")
        }
        return Response(exit: 0)
    }

    /// Agent side of `get`: sends `name` as framed chunks.
    static func get(_ name: String, from directory: String, as user: String?, to responder: Responder) -> Response {
        let output = Pipe()
        let process: Process
        do {
            process = try launch(["/bin/cat", directory + "/" + name], as: user) {
                $0.standardOutput = output
                $0.standardError = FileHandle.nullDevice
            }
        } catch {
            return Response(error: "can't read '\(name)': \(error.localizedDescription)")
        }
        let reader = output.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty {
            responder.send(Response(chunk: chunk.count).line, then: chunk)
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? Response(exit: 0) : Response(error: "can't read '\(name)' in the guest")
    }

    /// Host side of `put`: sends the file at `url` over `fd`, to be stored as `name`.
    public static func askToPut(_ url: URL, as name: String, over fd: Int32) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = Int64(try file.seekToEnd())
        try file.seek(toOffset: 0)
        guard size <= maxFileSize else {
            throw PaddockError("\(url.lastPathComponent) is over the \(maxFileSize)-byte limit")
        }
        UnixSocket.configure(fd, readTimeout: nil)
        UnixSocket.writeLine(Request(op: "put", name: name, size: size).line, to: fd)
        while let chunk = try file.read(upToCount: fileChunk), !chunk.isEmpty {
            // If the agent refused or stopped, its answer says why.
            guard UnixSocket.writeAll(chunk, to: fd) else { break }
        }
        guard let answer = UnixSocket.readLine(fd, limit: 4096) else {
            throw PaddockError("the guest agent didn't confirm '\(name)'")
        }
        _ = try checked(answer)
    }

    /// Host side of `get`: saves `name` from the guest at `url`, refusing more than `limit`
    /// bytes, and returns its size. A partial file is removed.
    @discardableResult
    public static func askToGet(_ name: String, to url: URL, over fd: Int32, limit: Int64 = maxFileSize) throws -> Int64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PaddockError("can't create \(url.path)")
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        do {
            UnixSocket.configure(fd, readTimeout: 30)
            UnixSocket.writeLine(Request(op: "get", name: name).line, to: fd)
            var total: Int64 = 0
            while let answer = UnixSocket.readLine(fd, limit: 4096) {
                let response = try checked(answer)
                if response.exit != nil {
                    return total
                }
                guard let count = response.chunk, (1...fileChunk).contains(count) else {
                    throw PaddockError("unexpected answer from the guest agent while reading '\(name)'")
                }
                total += Int64(count)
                guard total <= limit else {
                    throw PaddockError("'\(name)' from the guest is over the \(limit)-byte limit")
                }
                guard let bytes = UnixSocket.readExactly(count, from: fd) else { break }
                try file.write(contentsOf: bytes)
            }
            throw PaddockError("the guest agent stopped before '\(name)' finished")
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
