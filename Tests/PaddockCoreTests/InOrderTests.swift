import Testing
@testable import PaddockCore

@MainActor @Suite struct InOrderTests {
    @MainActor private final class Steps {
        var list: [String] = []
    }

    private struct Failed: Error {}

    /// Two pieces started together, as two input requests can be: the second waits for all of the
    /// first, even when the first throws.
    @Test func runsEachPieceAfterTheOneBefore() async throws {
        let order = InOrder(), steps = Steps()
        // Tasks made on the main actor start there in the order they're made.
        let first = Task {
            try await order.run {
                steps.list.append("first starts")
                try await Task.sleep(for: .milliseconds(50))
                steps.list.append("first ends")
                throw Failed()
            }
        }
        let second = Task { try await order.run { steps.list.append("second") } }
        await #expect(throws: Failed.self) { try await first.value }
        try await second.value
        #expect(steps.list == ["first starts", "first ends", "second"])
    }
}
