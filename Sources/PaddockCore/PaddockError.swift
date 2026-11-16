import Foundation

/// A user-facing failure with a message that says what went wrong and, where possible, what to do.
public struct PaddockError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
