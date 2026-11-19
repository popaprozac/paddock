import Foundation
import PaddockCore
import Security

/// A client's link to the control plane, for the CLI and `paddock mcp`: it proves it's the
/// logged-in client by signing the control plane's random bytes, then sends requests, each with an
/// ID, and hands each request the answers that come back with that ID.
///
/// A WebSocket task URLSession ends, at TLS or later, can leave a pending receive() never resumed,
/// as serve's link found; so the link ends every request as soon as URLSession says the task ended,
/// never by waiting on receive() alone.
final class PoolConnection: @unchecked Sendable {
    let identity: ControlIdentity
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let trust: PinnedTrust
    private let lock = NSLock()
    private var waiting: [String: AsyncThrowingStream<ControlLink.Message, Error>.Continuation] = [:]
    private var handshake: [ControlLink.Message] = []
    private var handshakeWaiter: CheckedContinuation<ControlLink.Message, Error>?
    private var ended: Error?
    private var nextID = 0

    /// The handshake's two messages, the challenge and the welcome, before requests start.
    private static let handshakeID = ""

    private init(identity: ControlIdentity, authority: SecCertificate) throws {
        self.identity = identity
        trust = PinnedTrust(.authority(authority))
        session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        var components = URLComponents(url: identity.url.appendingPathComponent("v1/client"), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url else { throw PaddockError("can't make the control plane's client URL") }
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 << 20
    }

    /// The logged-in client's identity, or why there is none.
    static func identity(in home: PaddockHome = .fromEnvironment()) throws -> ControlIdentity {
        guard let identity = try ControlIdentity.load(.client, from: ControlIdentity.folder(in: home, for: .client)) else {
            throw PaddockError("not logged in to a control plane: paddock login <url> --token <token>, with a token from "
                + "'paddock-control login-token' where it runs")
        }
        return identity
    }

    /// Opens a link as `identity` and has it accepted, within 15 s.
    static func open(_ identity: ControlIdentity) async throws -> PoolConnection {
        guard let authority = SecCertificateCreateWithData(nil, identity.authority as CFData) else {
            throw PaddockError("the saved control plane CA can't be read; log in again")
        }
        let connection = try PoolConnection(identity: identity, authority: authority)
        try await connection.start()
        return connection
    }

    private func start() async throws {
        trust.onTaskEnd { [weak self] in self?.end($0) }
        socket.resume()
        Task.detached { [self] in await self.readAll() }
        let watchdog = Task.detached { [weak self] in
            try await Task.sleep(for: .seconds(15))
            self?.end(PaddockError("the control plane didn't answer within 15 s"))
        }
        defer { watchdog.cancel() }
        do {
            let challenge = try await nextHandshakeMessage()
            guard challenge.type == "challenge", let nonce = challenge.nonce, nonce.count == 32 else {
                throw PaddockError("the control plane didn't start with a challenge")
            }
            try await send(ControlLink.Message(
                type: "auth", signature: ControlLink.answer(nonce, with: identity.key, context: ControlLink.clientContext),
                client: identity.id))
            let welcome = try await nextHandshakeMessage()
            guard welcome.type == "welcome" else { throw PaddockError("the control plane didn't accept this client") }
        } catch {
            close()
            throw explain(error)
        }
    }

    /// Sends a request, then `upload` in pieces if given, and returns its answers as they come,
    /// ending after the one marked done, or with the request's error, or with why the link ended.
    func request(_ message: ControlLink.Message, upload: URL? = nil) -> AsyncThrowingStream<ControlLink.Message, Error> {
        var message = message
        let (stream, continuation) = AsyncThrowingStream<ControlLink.Message, Error>.makeStream()
        let ended: Error? = lock.withLock {
            if let ended = self.ended { return ended }
            nextID += 1
            message.id = String(nextID)
            waiting[String(nextID)] = continuation
            return nil
        }
        if let ended {
            continuation.finish(throwing: explain(ended))
            return stream
        }
        message.type = "request"
        let id = message.id ?? ""
        // A reader that stops early leaves the link to the other requests: its answers are dropped.
        continuation.onTermination = { [weak self] _ in self?.forget(id) }
        Task { [self] in
            do {
                try await send(message)
                if let upload {
                    try await send(upload, as: id)
                }
            } catch {
                end(error)
            }
        }
        return stream
    }

    /// Sends a file after its request, in pieces, the last marked done.
    private func send(_ file: URL, as id: String) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: ControlLink.chunkSize) ?? Data()
            let last = data.count < ControlLink.chunkSize
            try await send(ControlLink.Message(type: "upload", id: id, done: last ? true : nil, data: data.isEmpty ? nil : data))
            if last { return }
        }
    }

    /// The answers to one request, all of them, or its error.
    func ask(_ message: ControlLink.Message) async throws -> [ControlLink.Message] {
        var answers: [ControlLink.Message] = []
        for try await answer in request(message) {
            answers.append(answer)
        }
        return answers
    }

    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    /// Whether the link still takes requests: it hasn't ended, from either side.
    var isOpen: Bool {
        lock.withLock { ended == nil }
    }

    private func forget(_ id: String) {
        _ = lock.withLock { waiting.removeValue(forKey: id) }
    }

    private func readAll() async {
        while true {
            let message: ControlLink.Message
            do {
                let data: Data
                switch try await socket.receive() {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: continue
                }
                message = try ControlLink.decoder().decode(ControlLink.Message.self, from: data)
            } catch {
                end(error)
                return
            }
            deliver(message)
        }
    }

    private func deliver(_ message: ControlLink.Message) {
        guard message.type == "response", let id = message.id else {
            let waiter: CheckedContinuation<ControlLink.Message, Error>? = lock.withLock {
                guard let waiter = handshakeWaiter else {
                    handshake.append(message)
                    return nil
                }
                handshakeWaiter = nil
                return waiter
            }
            waiter?.resume(returning: message)
            return
        }
        let continuation: AsyncThrowingStream<ControlLink.Message, Error>.Continuation? = lock.withLock {
            message.done == true ? waiting.removeValue(forKey: id) : waiting[id]
        }
        if let error = message.error {
            continuation?.finish(throwing: PaddockError(error))
            _ = lock.withLock { waiting.removeValue(forKey: id) }
            return
        }
        continuation?.yield(message)
        if message.done == true {
            continuation?.finish()
        }
    }

    private func nextHandshakeMessage() async throws -> ControlLink.Message {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<ControlLink.Message, Error>) in
            let ready: Result<ControlLink.Message, Error>? = lock.withLock {
                if !handshake.isEmpty { return .success(handshake.removeFirst()) }
                if let ended { return .failure(ended) }
                handshakeWaiter = waiter
                return nil
            }
            if let ready { waiter.resume(with: ready) }
        }
    }

    /// The link ended: every request still waiting fails with why, the first reason only.
    private func end(_ error: Error) {
        let (requests, waiter): ([AsyncThrowingStream<ControlLink.Message, Error>.Continuation],
                                 CheckedContinuation<ControlLink.Message, Error>?) = lock.withLock {
            guard ended == nil else { return ([], nil) }
            ended = error
            defer {
                waiting.removeAll()
                handshakeWaiter = nil
            }
            return (Array(waiting.values), handshakeWaiter)
        }
        let explained = explain(error)
        for request in requests {
            request.finish(throwing: explained)
        }
        waiter?.resume(throwing: explained)
    }

    private func send(_ message: ControlLink.Message) async throws {
        try await socket.send(.string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
    }

    /// Why the link failed, in words: refused, the certificate, or the network.
    private func explain(_ error: Error) -> Error {
        switch socket.closeCode {
        case .policyViolation:
            return PaddockError("the control plane at \(identity.url.absoluteString) refused this client, which was removed "
                + "or logged out: log in again with a new token from 'paddock-control login-token'")
        case .goingAway:
            return PaddockError("the control plane at \(identity.url.absoluteString) stopped")
        default:
            break
        }
        if let failure = trust.failure { return PaddockError(failure) }
        if error is PaddockError { return error }
        return PaddockError("can't reach the control plane at \(identity.url.absoluteString): \(error.localizedDescription)")
    }
}
