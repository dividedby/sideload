/// The one object every command prints: `{ok, command, <data keys>, errors:[{code,message,fix}]}`.
/// Exit code is 0 iff `ok`.
public struct Envelope: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let code: String
        public let message: String
        public let fix: String?

        public init(code: String, message: String, fix: String?) {
            self.code = code
            self.message = message
            self.fix = fix
        }
    }

    public let ok: Bool
    public let command: String
    public let data: [String: JSONValue]
    public let errors: [Entry]

    public init(ok: Bool, command: String, data: [String: JSONValue] = [:], errors: [Entry] = []) {
        self.ok = ok
        self.command = command
        self.data = data
        self.errors = errors
    }

    public static func result(_ command: String, _ data: [String: JSONValue] = [:]) -> Envelope {
        Envelope(ok: true, command: command, data: data)
    }

    public static func fail(
        _ command: String, code: String, message: String, fix: String? = nil, data: [String: JSONValue] = [:]
    ) -> Envelope {
        Envelope(ok: false, command: command, data: data, errors: [Entry(code: code, message: message, fix: fix)])
    }

    /// `SideloadError` keeps its code; anything else becomes `INTERNAL_ERROR`.
    public static func from(_ error: any Error, command: String) -> Envelope {
        if let e = error as? SideloadError {
            return fail(command, code: e.code, message: e.message, fix: e.fix, data: e.data)
        }
        return fail(
            command, code: "INTERNAL_ERROR", message: String(describing: error),
            fix: "This is a bug in sideload; re-run and report the code.")
    }

    public var exitCode: Int32 { ok ? 0 : 1 }

    /// Envelope fields always win over same-named data keys.
    public var json: JSONValue {
        var object = data
        object["ok"] = .bool(ok)
        object["command"] = .string(command)
        object["errors"] = .array(
            errors.map { e in
                .object(["code": .string(e.code), "message": .string(e.message), "fix": e.fix.map(JSONValue.string) ?? .null])
            })
        return .object(object)
    }
}

extension Envelope: Encodable {
    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}
