/// A failure with a stable machine code, a message, and a human fix. Maps to one `errors[]` entry.
public struct SideloadError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let fix: String?
    public let data: [String: JSONValue]

    public init(_ code: String, _ message: String, fix: String? = nil, data: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.fix = fix
        self.data = data
    }
}
