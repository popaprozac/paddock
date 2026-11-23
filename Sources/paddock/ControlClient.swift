import CryptoKit
import Foundation
import PaddockCore
import Security

/// Checks the control plane's TLS certificate against the one CA this Mac trusts there, and no
/// other: while joining, the CA in the server's chain whose key has the join token's pin; after,
/// the CA saved then. The certificate must also name the host in the URL.
final class PinnedTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Anchor {
        case pin(Data)
        case authority(SecCertificate)
    }

    private let anchor: Anchor
    private let lock = NSLock()
    private var matched: SecCertificate?
    private var failed: String?
    private var taskEnded: (@Sendable (Error) -> Void)?

    init(_ anchor: Anchor) {
        self.anchor = anchor
    }

    /// The CA the server's certificate was checked against, once a request got that far.
    var matchedAuthority: SecCertificate? { lock.withLock { matched } }
    /// Why the server's certificate was refused, if it was.
    var failure: String? { lock.withLock { failed } }

    /// Called once URLSession ends a task, with why.
    func onTaskEnd(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.withLock { taskEnded = handler }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = lock.withLock { taskEnded }
        handler?(error ?? PaddockError("the link closed"))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        let host = challenge.protectionSpace.host
        let authority: SecCertificate?
        switch anchor {
        case let .pin(pin):
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            authority = chain.first { Self.pin(of: $0) == pin }
        case let .authority(certificate):
            authority = certificate
        }
        guard let authority else {
            fail("the server at \(host) isn't the control plane the join token is for: its certificate isn't from that CA")
            return (.cancelAuthenticationChallenge, nil)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [authority] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "unknown"
            fail("the server at \(host) isn't the control plane this Mac trusts, or doesn't know itself as \(host) "
                + "(\(reason)): if it is the same control plane, start it with --name \(host); if not, join it with --join")
            return (.cancelAuthenticationChallenge, nil)
        }
        lock.withLock { matched = authority }
        return (.useCredential, URLCredential(trust: trust))
    }

    private func fail(_ reason: String) {
        lock.withLock { failed = reason }
    }

    static func pin(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return ControlLink.pin(ofP256Point: point)
    }
}

/// Getting the identity `paddock serve --control` links with.
enum ControlEnrollment {
    /// A control plane's URL as serve keeps it: https, a host, maybe a port, no path.
    static func url(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text), components.scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw PaddockError("--control takes the control plane's https URL, such as https://studio.local:7443")
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw PaddockError("--control: can't read \(text)") }
        return url
    }

    /// Joins with `token` and saves the identity, replacing any other; or, with no token, the
    /// identity this Mac saved when it joined, for `url`.
    static func identity(control url: URL, join token: String?, home: PaddockHome) async throws -> ControlIdentity {
        let folder = ControlIdentity.folder(in: home, for: .host)
        if let token {
            let parsed = try ControlLink.Token(token)
            guard parsed.kind == .host else {
                throw PaddockError("that's a login token, for 'paddock login'; a Mac joins with a token from "
                    + "'paddock-control join-token'")
            }
            try ControlIdentity.checkCanSave(to: folder)
            let joined = try await join(url, token: parsed, as: .host, name: ControlClient.computerName)
            try joined.save(to: folder)
            print("Joined the control plane at \(url.absoluteString) as \(joined.id)")
            return joined
        }
        guard let saved = try ControlIdentity.load(.host, from: folder) else {
            throw PaddockError("this Mac hasn't joined \(url.absoluteString) yet: add --join with a token from "
                + "'paddock-control join-token' there")
        }
        // The same control plane by another name, such as its MagicDNS name away from the LAN, is
        // fine: the link trusts only the CA saved at joining, so another control plane fails there.
        var identity = saved
        identity.url = url
        return identity
    }

    /// Makes a key and enrolls its public half as `kind`, trusting only the CA the token pins.
    static func join(_ url: URL, token: ControlLink.Token, as kind: ControlLink.Kind, name: String) async throws
        -> ControlIdentity {
        let trust = PinnedTrust(.pin(token.pin))
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let key = P256.Signing.PrivateKey()
        var request = URLRequest(url: url.appendingPathComponent("v1/enroll"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ControlLink.EnrollRequest(
            token: token.text, name: ControlLink.hostName(name), publicKey: key.publicKey.derRepresentation, as: kind))
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PaddockError("can't reach the control plane at \(url.absoluteString): \(trust.failure ?? error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(ControlLink.EnrollResponse.self, from: data)
        guard status == 200, let id = kind == .host ? decoded?.host : decoded?.client,
              let authority = trust.matchedAuthority
        else {
            throw PaddockError("the control plane didn't enroll this \(kind == .host ? "Mac" : "client"): "
                + (decoded?.error ?? "HTTP status \(status)"))
        }
        return ControlIdentity(kind: kind, url: url, id: id, authority: SecCertificateCopyData(authority) as Data, key: key)
    }
}

/// serve's side of its link to the control plane: proves it's the enrolled Mac, says what it is,
/// and reports its slots whenever they change, reconnecting while serve runs. It never holds up
/// serving: VMs go on being handed out here whether the link is up or not.
@MainActor
final class ControlClient {
    private let identity: ControlIdentity
    private let image: String
    private let slots: @MainActor () -> [ControlLink.SlotReport]
    private let diskFree: @MainActor () -> UInt64?
    private let status: @MainActor () -> MacStatus?
    private let onRequest: @MainActor (String, Responder) -> Void
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    /// The removed Mac's link is closed by the control plane, which then refuses it.
    private struct Removed: Error {}

    /// `onRequest` is serve's own handler: requests from the control plane run through it, with
    /// the same checks as one from this Mac, once `ControlLink.checkRemote` takes them.
    init(identity: ControlIdentity, image: String, slots: @escaping @MainActor () -> [ControlLink.SlotReport],
         diskFree: @escaping @MainActor () -> UInt64?, status: @escaping @MainActor () -> MacStatus?,
         onRequest: @escaping @MainActor (String, Responder) -> Void) {
        self.identity = identity
        self.image = image
        self.slots = slots
        self.diskFree = diskFree
        self.status = status
        self.onRequest = onRequest
    }

    /// The name the Mac goes by for people: its computer name, as in Sharing settings.
    nonisolated static var computerName: String {
        ControlLink.hostName(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    func start() {
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Links, and links again after a drop: 1 s, doubling to 30 s, with jitter so many Macs
    /// don't all come back at once. It says when the link goes down or comes back, not at every try.
    private func run() async {
        var delay = 1.0
        var down = false
        while !Task.isCancelled {
            let started = ContinuousClock.now
            do {
                try await link {
                    print("Linked to the control plane at \(self.identity.url.absoluteString) as \(self.identity.id)")
                    down = false
                }
            } catch is Removed {
                print("The control plane at \(identity.url.absoluteString) refused this Mac, which was removed or never "
                    + "joined it; serve goes on here alone. To link again, join with a new token: paddock-control join-token")
                return
            } catch {
                if Task.isCancelled { return }
                if !down {
                    print("No link to the control plane: \(error.localizedDescription); trying again in the background")
                    down = true
                }
            }
            if ContinuousClock.now - started > .seconds(60) {
                delay = 1  // it was up for a while: this is a new outage
            }
            try? await Task.sleep(for: .seconds(delay * Double.random(in: 0.8...1.2)))
            delay = min(delay * 2, 30)
        }
    }

    /// One link, from the challenge until it closes. It ends at the first of: its work ending,
    /// URLSession ending the socket's task, or the handshake taking over 15 s. Not on receive()
    /// alone: a WebSocket task refused at TLS ends, yet in serve its pending receive() was never
    /// resumed, even after a cancel, so a wrong or changed control plane hung the link for good.
    /// shortcut: a receive() left suspended so stays until serve exits; it happens only on
    /// failed links, at most twice a minute, so it's left rather than worked around further.
    private func link(onLinked: @escaping @MainActor () -> Void) async throws {
        guard let authority = SecCertificateCreateWithData(nil, identity.authority as CFData) else {
            throw PaddockError("the saved control plane CA can't be read; join again with --join")
        }
        let trust = PinnedTrust(.authority(authority))
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var components = URLComponents(url: identity.url.appendingPathComponent("v1/link"), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        guard let url = components?.url else { throw PaddockError("can't make the link URL") }
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1 << 20
        self.socket = socket
        defer { self.socket = nil }

        let end = LinkEnd()
        trust.onTaskEnd { end.finish($0) }
        socket.resume()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            end.finish(PaddockError("the control plane didn't answer within 15 s"))
        }
        let work = Task {
            do {
                try await self.serveLink(on: socket, linked: { watchdog.cancel(); onLinked() })
                end.finish(PaddockError("the link closed"))
            } catch {
                end.finish(error)
            }
        }
        defer {
            watchdog.cancel()
            work.cancel()
        }
        let error = await end.wait()
        abandonUploads()
        switch socket.closeCode {
        case .policyViolation: throw Removed()
        case .goingAway: throw PaddockError(Task.isCancelled ? "serve is stopping" : "the control plane stopped or restarted")
        case .invalid: break
        default: throw PaddockError("the control plane closed the link (code \(socket.closeCode.rawValue))")
        }
        if let failure = trust.failure { throw PaddockError(failure) }
        throw (error as? PaddockError) ?? PaddockError(error.localizedDescription)
    }

    /// The link's work: the challenge, the hello, then the slots until it closes.
    private func serveLink(on socket: URLSessionWebSocketTask, linked: () -> Void) async throws {
        let challenge = try await receive(socket)
        guard challenge.type == "challenge", let nonce = challenge.nonce, nonce.count == 32 else {
            throw PaddockError("the control plane didn't start with a challenge")
        }
        try await send(ControlLink.Message(type: "auth", host: identity.id,
                                           signature: ControlLink.answer(nonce, with: identity.key)), on: socket)
        let welcome = try await receive(socket)
        guard welcome.type == "welcome" else { throw PaddockError("the control plane didn't accept the link") }
        linked()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        try await send(ControlLink.Message(
            type: "hello", name: Self.computerName, version: Paddock.configuration.version,
            macos: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", image: image,
            cpus: ProcessInfo.processInfo.activeProcessorCount, memory: ProcessInfo.processInfo.physicalMemory), on: socket)
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Reading takes the control plane's requests and sees the link close.
            group.addTask {
                while true {
                    let message = try await self.receive(socket)
                    if message.type == "request", let id = message.id {
                        await self.answer(id, serve: message.serve, on: socket)
                    } else if message.type == "upload" {
                        await self.receiveUpload(message, on: socket)
                    } else if message.type == "cancel", let id = message.id {
                        await self.abandonUpload(id)
                    }
                }
            }
            group.addTask { try await self.reportSlots(on: socket) }
            group.addTask { try await self.reportUsage(on: socket) }
            _ = try await group.next()
        }
    }

    /// A task's bundle on its way from the control plane, into a file this Mac picked.
    private struct Upload {
        var request: [String: Any]
        var bundle: URL
        var handle: FileHandle
        var size = 0
    }

    private var uploads: [String: Upload] = [:]
    /// Requests whose client keeps sending, such as a view, by request ID: where their uploads go.
    private var streams: [String: ResponderPipe.Input] = [:]

    /// Runs one of the control plane's requests through serve's handler and sends its answer lines
    /// back with the request's ID, the last marked done. A request this Mac doesn't take from its
    /// link gets serve's kind of error line instead. Files a request needs are ones this Mac picks,
    /// never ones the control plane names: a screenshot's, and a task's bundle and result.
    private func answer(_ id: String, serve line: String?, on socket: URLSessionWebSocketTask) {
        do {
            let request = try ControlLink.checkRemote(line ?? "")
            guard var fields = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] else {
                throw PaddockError("that isn't one of serve's requests")
            }
            switch fields["op"] as? String {
            case let op? where ControlLink.streamingOperations.contains(op):
                try stream(fields, id: id, on: socket)
            case "acquire":
                // The control plane keeps the pool's one queue, so this Mac answers at once: a
                // warm VM, or busy, and the control plane tries another Mac or waits.
                fields["wait"] = false
                try run(fields, id: id, on: socket, sendBack: nil, required: false, cleanup: [])
            case "screenshot":
                let file = Self.temporaryFile("paddock-screen", "png")
                fields["result"] = file.path
                try run(fields, id: id, on: socket, sendBack: file, required: true, cleanup: [file])
            case "task":
                // The bundle comes next, in pieces; the task runs once it's all here.
                let bundle = Self.temporaryFile("paddock-task-in", "bundle")
                guard FileManager.default.createFile(atPath: bundle.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw PaddockError("can't make a file for the task's bundle")
                }
                uploads[id] = Upload(request: fields, bundle: bundle, handle: try FileHandle(forWritingTo: bundle))
            default:
                try run(fields, id: id, on: socket, sendBack: nil, required: false, cleanup: [])
            }
        } catch {
            refuse(id, error, on: socket)
        }
    }

    /// Takes a piece of a task's bundle; with the last, runs the task. A streaming request's pieces
    /// go straight to its handler.
    private func receiveUpload(_ message: ControlLink.Message, on socket: URLSessionWebSocketTask) {
        if let id = message.id, let input = streams[id] {
            if let data = message.data {
                input.send(data)
            }
            if message.done == true {
                streams[id] = nil
                input.finish()
            }
            return
        }
        guard let id = message.id, var upload = uploads[id] else { return }
        do {
            if let data = message.data {
                upload.size += data.count
                guard upload.size <= ControlLink.maxTransfer else {
                    throw PaddockError("the bundle is over \(ControlLink.maxTransfer >> 30) GB, the most a task takes")
                }
                try upload.handle.write(contentsOf: data)
            }
            uploads[id] = upload
            guard message.done == true else { return }
            uploads[id] = nil
            try upload.handle.close()
            let result = Self.temporaryFile("paddock-task-out", "bundle")
            var fields = upload.request
            fields["bundle"] = upload.bundle.path
            fields["result"] = result.path
            try run(fields, id: id, on: socket, sendBack: result, required: false, cleanup: [upload.bundle, result])
        } catch {
            uploads[id] = nil
            try? upload.handle.close()
            try? FileManager.default.removeItem(at: upload.bundle)
            refuse(id, error, on: socket)
        }
    }

    /// Drops the bundles of tasks that never got all their pieces, and ends streaming requests,
    /// as when the link closes.
    private func abandonUploads() {
        for id in Array(uploads.keys) + Array(streams.keys) {
            abandonUpload(id)
        }
    }

    /// Drops a task's bundle that won't be finished: its client left, or it grew too big. A
    /// streaming request's handler sees its input end, which stops it.
    private func abandonUpload(_ id: String) {
        if let input = streams.removeValue(forKey: id) {
            input.finish()
            return
        }
        guard let upload = uploads.removeValue(forKey: id) else { return }
        try? upload.handle.close()
        try? FileManager.default.removeItem(at: upload.bundle)
    }

    /// Runs the request through serve's handler and sends back its lines; then, if serve wrote
    /// `sendBack`, its bytes, before the last line. Deletes `cleanup` once done.
    private func run(_ fields: [String: Any], id: String, on socket: URLSessionWebSocketTask, sendBack: URL?, required: Bool,
                     cleanup: [URL]) throws {
        let request = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let (responder, lines) = try ResponderPipe.make()
        onRequest(request, responder)
        Task {
            defer { cleanup.forEach { try? FileManager.default.removeItem(at: $0) } }
            var last: String?
            for await answer in lines {
                if let previous = last {
                    try? await send(ControlLink.Message(type: "response", id: id, line: previous), on: socket)
                }
                last = answer
            }
            if let sendBack {
                last = await sendFile(sendBack, answered: last, required: required, id: id, on: socket)
            }
            // The last line goes out marked done, so the control plane knows the request is over.
            try? await send(ControlLink.Message(type: "response", id: id, done: true, line: last), on: socket)
        }
    }

    /// Runs a request whose client keeps sending (see `receiveUpload`) and sends each answer line
    /// as it comes, not held for the next: a view's frame can't wait for the one after it. The
    /// last message only says it's done.
    private func stream(_ fields: [String: Any], id: String, on socket: URLSessionWebSocketTask) throws {
        let request = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let (responder, lines, input) = try ResponderPipe.makeDuplex()
        streams[id] = input
        onRequest(request, responder)
        Task {
            for await answer in lines {
                try? await send(ControlLink.Message(type: "response", id: id, line: answer), on: socket)
            }
            streams.removeValue(forKey: id)?.finish()
            try? await send(ControlLink.Message(type: "response", id: id, done: true), on: socket)
        }
    }

    private func refuse(_ id: String, _ error: Error, on socket: URLSessionWebSocketTask) {
        let refusal = ServeResponse(error: error.localizedDescription).line
        Task { try? await self.send(ControlLink.Message(type: "response", id: id, done: true, line: refusal), on: socket) }
    }

    /// Sends the file serve wrote, in pieces; returns the answer line to end with, without the
    /// file's path, which is this Mac's business. A file that isn't there is an error if
    /// `required` (a screenshot), and nothing to send otherwise (a task with no new commits).
    private func sendFile(_ file: URL, answered line: String?, required: Bool, id: String,
                          on socket: URLSessionWebSocketTask) async -> String? {
        if let line, line.contains("\"error\"") {
            return line
        }
        let ending = Self.withoutResult(line) ?? "{}"
        // Read a piece at a time, not whole: a task's bundle can be gigabytes, and this runs on
        // serve's main actor.
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return required ? ServeResponse(error: "serve didn't save the file").line : ending
        }
        defer { try? handle.close() }
        do {
            while let piece = try handle.read(upToCount: ControlLink.chunkSize), !piece.isEmpty {
                try? await send(ControlLink.Message(type: "response", id: id, data: piece), on: socket)
            }
        } catch {
            return ServeResponse(error: "can't read the file serve saved: \(error.localizedDescription)").line
        }
        return ending
    }

    /// serve's answer line without its "result", which names a file on this Mac.
    private static func withoutResult(_ line: String?) -> String? {
        guard let line, var fields = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return line
        }
        fields["result"] = nil
        return (try? JSONSerialization.data(withJSONObject: fields)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func temporaryFile(_ name: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
    }

    /// Sends the slots when they change, checked every second, and free disk at least every minute.
    private func reportSlots(on socket: URLSessionWebSocketTask) async throws {
        var last: [ControlLink.SlotReport]?
        var sent = ContinuousClock.now
        while true {
            let current = slots()
            if current != last || ContinuousClock.now - sent >= .seconds(60) {
                try await send(ControlLink.Message(type: "capacity", diskFree: diskFree(), slots: current), on: socket)
                last = current
                sent = .now
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Sends what this Mac and its VMs use, every 2 s, apart from the slot reports: the control
    /// plane then keeps its view of the slots, and its queue, as they were.
    private func reportUsage(on socket: URLSessionWebSocketTask) async throws {
        while true {
            if let status = status(), let usage = status.usage {
                try await send(ControlLink.Message(type: "usage", slots: status.slots, usage: usage), on: socket)
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> ControlLink.Message {
        let data: Data
        switch try await socket.receive() {
        case let .string(text): data = Data(text.utf8)
        case let .data(bytes): data = bytes
        @unknown default: throw PaddockError("the control plane sent something unexpected")
        }
        return try JSONDecoder().decode(ControlLink.Message.self, from: data)
    }

    private func send(_ message: ControlLink.Message, on socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
    }
}

/// How a link ended, the first time it's told: resumes the one waiter, and ignores later news.
private final class LinkEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    private var waiter: CheckedContinuation<Error, Never>?

    func finish(_ error: Error) {
        let waiter: CheckedContinuation<Error, Never>? = lock.withLock {
            guard self.error == nil else { return nil }
            self.error = error
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: error)
    }

    func wait() async -> Error {
        await withCheckedContinuation { continuation in
            let ended: Error? = lock.withLock {
                if let error { return error }
                waiter = continuation
                return nil
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }
}
