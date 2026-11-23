import Foundation
import Security

/// Checks the control plane's TLS certificate against the one CA this Mac trusts there, and no
/// other: while joining, the CA in the server's chain whose key has the join token's pin; after,
/// the CA saved then. The certificate must also name the host in the URL.
public final class PinnedTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public enum Anchor {
        case pin(Data)
        case authority(SecCertificate)
    }

    private let anchor: Anchor
    private let lock = NSLock()
    private var matched: SecCertificate?
    private var failed: String?
    private var taskEnded: (@Sendable (Error) -> Void)?

    public init(_ anchor: Anchor) {
        self.anchor = anchor
    }

    /// The CA the server's certificate was checked against, once a request got that far.
    public var matchedAuthority: SecCertificate? { lock.withLock { matched } }
    /// Why the server's certificate was refused, if it was.
    public var failure: String? { lock.withLock { failed } }

    /// Called once URLSession ends a task, with why.
    public func onTaskEnd(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.withLock { taskEnded = handler }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = lock.withLock { taskEnded }
        handler?(error ?? PaddockError("the link closed"))
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard accepts(trust, host: challenge.protectionSpace.host) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Whether the server's certificate, in trust, is from the anchor's CA and names host. If it
    /// is, `matchedAuthority` is that CA; if not, `failure` says why.
    public func accepts(_ trust: SecTrust, host: String) -> Bool {
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
            return false
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [authority] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "unknown"
            fail("the server at \(host) isn't the control plane this Mac trusts, or doesn't know itself as \(host) "
                + "(\(reason)): if it is the same control plane, start it with --name \(host); if not, join it with --join")
            return false
        }
        lock.withLock { matched = authority }
        return true
    }

    private func fail(_ reason: String) {
        lock.withLock { failed = reason }
    }

    public static func pin(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return ControlLink.pin(ofP256Point: point)
    }
}
