import Darwin
import Foundation

/// The protocol between the host and paddock-guestd, the agent inside each macOS guest.
///
/// The agent listens only on vsock, so nothing on the VM network can reach it. Each
/// connection carries one line of JSON each way. The host treats every answer as untrusted:
/// the workload runs as admin and can replace the agent.
public enum GuestAgent {
    /// The vsock port the agent listens on inside the guest.
    public static let port: UInt32 = 52525
    public static let version = "0.1.0"

    public struct Request: Codable, Equatable, Sendable {
        public var op: String  // "health"

        public init(op: String) {
            self.op = op
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var version: String?
        public var error: String?

        public init(version: String? = nil, error: String? = nil) {
            self.version = version
            self.error = error
        }
    }

    /// The agent's one-line answer to one request line.
    public static func answer(_ line: String) -> String {
        let response = switch (try? JSONDecoder().decode(Request.self, from: Data(line.utf8)))?.op {
        case "health": Response(version: version)
        case let op?: Response(error: "unknown request '\(op.prefix(64))'")
        case nil: Response(error: "unreadable request")
        }
        return (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Opens a vsock socket listening on `port` for the host. Works only inside a VM: a macOS
    /// host has no vsock transport and reaches guests through Virtualization.framework instead.
    public static func listen(port: UInt32) throws -> Int32 {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.error("create a vsock socket") }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = VMADDR_CID_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let error = UnixSocket.error("listen on vsock port \(port)")
            close(fd)
            throw error
        }
        return fd
    }
}
