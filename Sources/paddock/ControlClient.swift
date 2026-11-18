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
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    /// The removed Mac's link is closed by the control plane, which then refuses it.
    private struct Removed: Error {}

    init(identity: ControlIdentity, image: String, slots: @escaping @MainActor () -> [ControlLink.SlotReport],
         diskFree: @escaping @MainActor () -> UInt64?) {
        self.identity = identity
        self.image = image
        self.slots = slots
        self.diskFree = diskFree
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
            // Reading keeps the link's pings answered and sees it close.
            group.addTask {
                while true { _ = try await socket.receive() }
            }
            group.addTask { try await self.reportSlots(on: socket) }
            _ = try await group.next()
        }
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
