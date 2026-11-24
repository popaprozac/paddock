import Darwin
import Foundation
import os
import Testing
@testable import PaddockCore

/// paddock's side of paddock-net's control socket, against a stand-in.
@Suite struct UserspaceNetworkTests {
    /// paddock's end of a socket pair whose other end answers each line it reads with `answer`,
    /// on a thread of its own, and closes once `answer` returns nil.
    func control(answer: @escaping @Sendable (String) -> String?) throws -> NetworkControl {
        var ends: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let standIn = ends[1]
        UnixSocket.configure(standIn, readTimeout: nil)
        Thread.detachNewThread {
            defer { close(standIn) }
            while let line = UnixSocket.readLine(standIn), let reply = answer(line) {
                UnixSocket.writeLine(reply, to: standIn)
            }
        }
        return NetworkControl(fd: ends[0])
    }

    @Test func sendsEachListAsOneLineOnOneSocket() throws {
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])
        let control = try control { line in
            received.withLock { $0.append(line) }
            return "{}"
        }
        try control.allow(["github.com", "*.example.org"])
        try control.allow([])
        #expect(received.withLock { $0 } == [#"{"allow":["github.com","*.example.org"]}"#, #"{"allow":[]}"#])
    }

    @Test func throwsWhenPaddockNetRefusesTheList() throws {
        let control = try control { _ in #"{"error":"\"*\" is not a host name or *.domain"}"# }
        #expect(throws: PaddockError.self) { try control.allow(["*"]) }
        #expect(throws: PaddockError.self) { try control.allow(["*"]) }  // a refusal leaves it open
    }

    /// After a missing answer, a late one could be taken for the next list's.
    @Test func takesNoMoreListsOnceAnAnswerIsMissing() throws {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let control = try control { _ in
            asked.withLock { $0 += 1 }
            return nil
        }
        #expect(throws: PaddockError.self) { try control.allow(["github.com"]) }
        let error = #expect(throws: PaddockError.self) { try control.allow(["github.com"]) }
        #expect(error?.localizedDescription.contains("no more lists") == true)
        #expect(asked.withLock { $0 } == 1)
    }

    @Test func refusesAListTooLongForPaddockNet() throws {
        let control = try control { _ in "{}" }
        let names = (0..<10_000).map { "host\($0).example.org" }
        #expect(throws: PaddockError.self) { try control.allow(names) }
        try control.allow(["github.com"])
    }
}
