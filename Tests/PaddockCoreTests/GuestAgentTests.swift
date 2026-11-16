import Foundation
import Testing
@testable import PaddockCore

@Suite struct GuestAgentTests {
    func decode(_ line: String) throws -> GuestAgent.Response {
        try JSONDecoder().decode(GuestAgent.Response.self, from: Data(line.utf8))
    }

    @Test func healthReportsTheVersion() throws {
        let answer = GuestAgent.answer(#"{"op":"health"}"#)
        #expect(try decode(answer) == GuestAgent.Response(version: GuestAgent.version))
        #expect(!answer.contains("\n"))
    }

    @Test func unknownRequestsGetAnError() throws {
        #expect(try decode(GuestAgent.answer(#"{"op":"reboot"}"#)).error == "unknown request 'reboot'")
    }

    @Test func unreadableRequestsGetAnError() throws {
        #expect(try decode(GuestAgent.answer("not json")).error == "unreadable request")
        #expect(try decode(GuestAgent.answer(#"{"nothing":1}"#)).error == "unreadable request")
    }
}
