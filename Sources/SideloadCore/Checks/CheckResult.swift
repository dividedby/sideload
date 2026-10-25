/// One row of `doctor`: a check id, severity, message and fix.
public struct CheckResult: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        case ok, warn, fail, info
    }

    public var id: String
    /// Mostly the severity's name; the Apple TV check reports `not-paired`.
    public var status: String
    public var severity: Severity
    public var message: String
    public var fix: String?
    public var daysLeft: Int?

    public init(
        id: String, severity: Severity, message: String, fix: String? = nil, daysLeft: Int? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.status = status ?? severity.rawValue
        self.severity = severity
        self.message = message
        self.fix = fix
        self.daysLeft = daysLeft
    }

    /// `fix` and `daysLeft` are omitted when absent, so the JSON has no null placeholders.
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "status": .string(status), "severity": .string(severity.rawValue),
            "message": .string(message),
        ]
        if let fix { object["fix"] = .string(fix) }
        if let daysLeft { object["daysLeft"] = .number(Double(daysLeft)) }
        return .object(object)
    }
}

/// A doctor check. Throwing is a crash: `Doctor` turns it into a `fail` row.
public protocol Check: Sendable {
    var id: String { get }
    func run(_ services: Services) async throws -> [CheckResult]
}
