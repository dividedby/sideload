/// A string that must never reach output: the API key's PEM and the bearer token. It prints as `<redacted>`
/// in every description, debug description and dump, and is not `Codable` or `Equatable`. The text is
/// reachable only through `reveal`.
public struct ASCSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func reveal<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(value)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
