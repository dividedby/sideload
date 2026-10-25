import Foundation

/// Masks identifiers and personal data in every string and object key of a `JSONValue` tree.
/// Last step before encoding.
public struct Redactor: Sendable {
    /// Caller-supplied literals (e.g. known ids in unusual formats), masked to their last four
    /// characters. Literals shorter than 8 UTF-16 units are ignored.
    public let literals: [String]

    public init(literals: [String] = []) {
        self.literals = literals
    }

    /// `…` plus the last four characters.
    public static func tail4(_ id: String) -> String {
        "…" + String(id.suffix(4))
    }

    // ICU lookarounds keep the id patterns off longer hex runs. The identity pattern's leading
    // lookbehind reproduces JS ASCII `\b` (the next character is always a word character).
    private static let identityName = NSRegularExpression.compiled(
        #"(?<![A-Za-z0-9_])(Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution|Developer ID Application):[^"\n]*?\([A-Z0-9]{10}\)"#)
    private static let idPatterns = [
        // Modern UDID (8-16), CoreDevice UUID, legacy 40-hex UDID.
        NSRegularExpression.compiled(#"(?<![0-9A-Za-z-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}(?![0-9A-Za-z-])"#),
        NSRegularExpression.compiled(#"(?<![0-9A-Za-z-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Za-z-])"#),
        NSRegularExpression.compiled(#"(?<![0-9A-Za-z])[0-9A-Fa-f]{40}(?![0-9A-Za-z])"#),
    ]
    // Defence in depth for the portal credentials: a JWT (three base64url parts, the first two starting `eyJ`)
    // and a PEM private-key block (an unterminated one is masked to the end of the text).
    private static let jwt = NSRegularExpression.compiled(#"eyJ[\w-]+\.[\w-]+\.[\w-]*"#)
    private static let privateKeyBlock = NSRegularExpression.compiled(
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#)
    private static let email = NSRegularExpression.compiled(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    private static let userPath = NSRegularExpression.compiled(#"/Users/[^/\s"']+"#)

    public func redact(_ string: String) -> String {
        var s = string
        for lit in literals where lit.utf16.count >= 8 {
            s = s.replacingOccurrences(of: lit, with: Self.tail4(lit))
        }
        return Self.redactPatterns(s)
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(redact(s))
        case .array(let items):
            return .array(items.map(redact))
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            // Sorted so that keys colliding after redaction resolve deterministically (last wins).
            for key in fields.keys.sorted() {
                out[redact(key)] = redact(fields[key]!)
            }
            return .object(out)
        case .null, .bool, .number:
            return value
        }
    }

    /// Patterns only, no caller literals. Used for log lines.
    public static func redactPatterns(_ string: String) -> String {
        var out = replace(privateKeyBlock, in: string, template: "<private key>")
        out = replace(jwt, in: out, template: "<jwt>")
        out = replace(identityName, in: out, template: "$1 (identity hidden)")
        for re in idPatterns {
            out = replace(re, in: out) { tail4($0) }
        }
        out = replace(email, in: out, template: "<email>")
        return replace(userPath, in: out, template: "/Users/<user>")
    }

    private static func replace(_ re: NSRegularExpression, in s: String, template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, transform: (String) -> String) -> String {
        let ns = s as NSString
        let result = NSMutableString(string: s)
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            result.replaceCharacters(in: m.range, with: transform(ns.substring(with: m.range)))
        }
        return result as String
    }
}
