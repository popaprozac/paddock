import ArgumentParser
import Foundation
import PaddockCore

/// Where a VM command goes: the logged-in control plane's pool, or this Mac's serve.
struct Target: ParsableArguments {
    @Flag(help: "Use this Mac's serve, not the pool of the control plane this Mac is logged in to. PADDOCK_LOCAL=1 does the same.")
    var local = false
}

/// serve's requests through the pool: the control plane picks the Mac and passes the request to
/// its serve. ServeClient's callers are synchronous (the CLI's commands, and paddock mcp, which
/// calls them off its async threads), so this runs the link on its own task and hands the
/// answers to the caller's thread in order.
enum PoolRoute {
    /// The client identity VM commands use the pool with, or nil for this Mac's serve.
    static func identity(local: Bool) throws -> ControlIdentity? {
        if local || ProcessInfo.processInfo.environment["PADDOCK_LOCAL"] == "1" {
            return nil
        }
        return try ControlIdentity.load(.client, from: ControlIdentity.folder(in: .fromEnvironment(), for: .client))
    }

    /// Passes each of serve's answers to `onResponse` until the request is done or `onResponse`
    /// returns false; an error answer throws. A task's bundle goes up from this Mac; a screenshot,
    /// or a task's new commits, come back as data and are saved at the request's result path.
    static func stream(_ request: ServeRequest, image: String?, as identity: ControlIdentity,
                       onResponse: (ServeResponse) throws -> Bool) throws {
        let upload = request.op == "task" ? request.bundle.map { URL(fileURLWithPath: $0) } : nil
        if let upload {
            let size = (try? upload.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ControlLink.maxTransfer else {
                throw PaddockError("the bundle is over \(ControlLink.maxTransfer >> 30) GB, the most a task takes through the pool")
            }
        }
        // Paths name files on this Mac; the pool's Macs pick their own.
        var forward = request
        forward.result = nil
        forward.bundle = nil
        let line = String(decoding: try JSONEncoder().encode(forward), as: UTF8.self)
        let saveTo = ["screenshot", "task"].contains(request.op) ? request.result : nil
        // A screenshot always has its file; a task only when it made new commits.
        let required = request.op == "screenshot"
        let answers = Answers()
        let work = Task.detached {
            do {
                let connection = try await PoolConnection.open(identity)
                answers.hold(connection)
                defer { connection.close() }
                var file = Data()
                let asked = ControlLink.Message(type: "request", image: image, op: request.op, serve: line)
                for try await answer in connection.request(asked, upload: upload) {
                    if let note = answer.note {
                        answers.put(.note(note))
                    }
                    if let data = answer.data {
                        file.append(data)
                    }
                    guard let text = answer.line, !text.isEmpty else { continue }
                    guard var response = try? JSONDecoder().decode(ServeResponse.self, from: Data(text.utf8)) else {
                        throw PaddockError("unreadable answer from the pool: \(text.prefix(200))")
                    }
                    if let saveTo, answer.done == true, response.error == nil, required || !file.isEmpty {
                        try file.write(to: URL(fileURLWithPath: saveTo), options: .atomic)
                        response.result = saveTo
                    }
                    answers.put(.response(response))
                }
                answers.put(.end)
            } catch {
                answers.put(.failure(error))
            }
        }
        defer {
            work.cancel()
            answers.close()
        }
        while true {
            switch answers.take() {
            case let .note(note):
                FileHandle.standardError.write(Data("paddock: \(note)\n".utf8))
            case let .response(response):
                if let error = response.error {
                    throw PaddockError(error)
                }
                if try !onResponse(response) {
                    return
                }
            case .end:
                return
            case let .failure(error):
                throw error
            }
        }
    }
}

/// The answers to one pool request, from the link's task to the caller's thread, in order.
private final class Answers: @unchecked Sendable {
    enum Item {
        case note(String)
        case response(ServeResponse)
        case end
        case failure(Error)
    }

    private let condition = NSCondition()
    private var items: [Item] = []
    private var connection: PoolConnection?

    func put(_ item: Item) {
        condition.withLock {
            items.append(item)
            condition.signal()
        }
    }

    func take() -> Item {
        condition.withLock {
            while items.isEmpty {
                condition.wait()
            }
            return items.removeFirst()
        }
    }

    func hold(_ connection: PoolConnection) {
        condition.withLock { self.connection = connection }
    }

    /// Closes the link if the caller stops early, so its request ends at the control plane too.
    func close() {
        let connection = condition.withLock { self.connection }
        connection?.close()
    }
}
