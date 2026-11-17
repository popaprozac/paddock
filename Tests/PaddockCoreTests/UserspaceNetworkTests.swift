import Dispatch
import Foundation
import os
import Testing
@testable import PaddockCore

/// UserspaceNetwork's side of paddock-net's control socket, against a stand-in server.
@Suite struct UserspaceNetworkTests {
    let queue = DispatchQueue(label: "userspace-network-tests")

    func socketPath() -> String {
        "/tmp/paddock-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func sendsTheListAsOneLine() throws {
        let path = socketPath()
        let received = OSAllocatedUnfairLock<String?>(initialState: nil)
        let server = try LineServer(path: path, queue: queue) { line, responder in
            received.withLock { $0 = line }
            responder.finish("{}")
        }
        try UserspaceNetwork.allow(["github.com", "*.example.org"], at: path)
        #expect(received.withLock { $0 } == #"{"allow":["github.com","*.example.org"]}"#)
        withExtendedLifetime(server) {}
    }

    @Test func throwsWhenPaddockNetRefusesTheList() throws {
        let path = socketPath()
        let server = try LineServer(path: path, queue: queue) { _, responder in
            responder.finish(#"{"error":"\"*\" is not a host name or *.domain"}"#)
        }
        #expect(throws: PaddockError.self) { try UserspaceNetwork.allow(["*"], at: path) }
        withExtendedLifetime(server) {}
    }

    @Test func throwsWhenNothingIsListening() {
        #expect(throws: (any Error).self) { try UserspaceNetwork.allow(["github.com"], at: socketPath()) }
    }
}
