/// Runs work one piece at a time, each piece once the one given before it has finished, whether
/// that threw or not: a VM's input goes through one, so two requests' keys never mix.
@MainActor
public final class InOrder {
    private var last: Task<Void, Error>?

    public init() {}

    public func run(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = last
        let task = Task {
            _ = await previous?.result
            try await work()
        }
        last = task
        try await task.value
    }
}
