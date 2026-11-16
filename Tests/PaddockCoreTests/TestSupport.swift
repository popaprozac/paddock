import Darwin
import Foundation

/// A fresh temporary directory, removed when the test finishes.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paddock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A loopback TCP server that sends one banner to each connection, for probe tests.
final class BannerServer: @unchecked Sendable {
    let port: UInt16
    private let socket: Int32
    private let thread: Thread

    init(banner: String) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw CocoaError(.fileWriteUnknown) }
        socket = fd
        port = UInt16(bigEndian: address.sin_port)
        thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = banner.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
        thread.start()
    }

    deinit {
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }
}
