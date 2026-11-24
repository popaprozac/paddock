import Foundation
import Testing
@testable import paddock

/// serve's lines that paddock-control reads or writes by field name, in a file its Go tests answer
/// with too, so a field renamed on either side fails a test.
@Suite struct ServeLinesTests {
    func line<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("paddock-control/testdata/serve-lines.json")
        let lines = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let fields = try #require(lines?[name])
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func requests() throws {
        let acquire = try line("acquire", as: ServeRequest.self)
        #expect(acquire.op == "acquire")
        #expect(acquire.allow == ["github.com", "*.example.org"])
        #expect(acquire.wait == false)
        let release = try line("release", as: ServeRequest.self)
        #expect(release.op == "release")
        #expect(release.vm == "golden-slot1-d07d90-a903d8")
    }

    @Test func answers() throws {
        let acquired = try line("acquired", as: ServeResponse.self)
        #expect(acquired.vm == "golden-slot1-d07d90-a903d8")
        #expect(acquired.host == "studio")
        let busy = try line("busy", as: ServeResponse.self)
        #expect(busy.busy == true)
        #expect(busy.error == "no warm VM is free on this Mac")
        #expect(try line("refused", as: ServeResponse.self).error == "unexpected")
    }
}
