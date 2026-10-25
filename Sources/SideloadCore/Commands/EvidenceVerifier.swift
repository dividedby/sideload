import Foundation

// The evidence bundle's last check. It does not trust the code that built the tree: it takes the subject words as
// plain strings, has its own matching (nothing from `TextMatch`, `MessageFilter` or `SubjectTokens`), and knows the
// closed schema. Any hit means nothing is written. Results are labels, never the matched text.

/// Every path a bundle (or a `canary.jsonl` line) may contain, and the shape of its value. Every field may also be
/// null. A key that is not listed is a failure.
enum EvidenceSchema {
    enum Shape {
        case object
        case array
        case bool
        case int
        case constInt(Int)
        case const(String)
        /// A string matching the whole pattern.
        case pattern(String)
        /// Text written by Apple (already admitted by `MessageFilter`): printable ASCII only, no subject word.
        case freeText
        /// A string of a known shape that Apple or the machine chose, and so must not carry a subject word either.
        case shapedFree(String)
        /// Exactly one of the listed strings, or else a `shapedFree` string of the given pattern.
        case knownOrShapedFree(known: Set<String>, pattern: String)
    }

    private static let version = #"\d+(\.\d+){0,2}"#
    private static let iso = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z"#
    private static let team = #"[A-Z0-9]{10}"#
    private static let hex32 = #"0x[0-9a-f]{8}"#
    private static let code = #"0x[0-9a-f]{1,8}|-?[0-9]{1,10}|[A-Za-z][A-Za-z0-9_-]{1,63}"#
    private static let tail = #"…[0-9A-Za-z]{4}"#
    private static let xcode = #"\d+(\.\d+){0,2}( \([0-9A-Za-z]{1,16}\))?"#

    /// The verifier's own list of Apple error domains accepted whole, even with a short subject token inside.
    static let knownDomains: Set<String> = [
        "com.apple.dt.CoreDeviceError", "com.apple.dt.MobileDeviceErrorDomain", "IXUserPresentableErrorDomain",
        "MIInstallerErrorDomain",
    ]

    static let fields: [String: Shape] = [
        "schema": .constInt(2), "generatedAt": .pattern(iso), "appleCase": .pattern(#"[0-9]{6,20}"#),
        "team": .pattern(team), "bundleId": .pattern(#"(?=.{1,200}$)[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*"#),
        "run": .object, "run.status": .pattern("working|blocked|error"), "run.code": .pattern(code),
        "run.reason": .freeText, "run.guard": .pattern(#"skipped|passed|failed:[A-Z_]{0,32}"#),
        "run.durationMs": .int,
        "environment": .object, "environment.macos": .object, "environment.macos.version": .pattern(version),
        "environment.macos.build": .pattern("[0-9A-Za-z]{2,12}"), "environment.xcode": .pattern(xcode),
        "environment.ios": .object, "environment.ios.version": .pattern(version),
        "environment.ios.build": .pattern("[0-9A-Za-z]{2,12}"),
        "keychainCertificate": .object, "keychainCertificate.ou": .pattern(team),
        "keychainCertificate.notBefore": .pattern(iso), "keychainCertificate.notAfter": .pattern(iso),
        "keychainCertificate.certFp": .pattern("[0-9a-f]{8}"),
        "profile": .object, "profile.team": .pattern(team), "profile.createdAt": .pattern(iso),
        "profile.expiresAt": .pattern(iso), "profile.deviceCount": .int, "profile.deviceIncluded": .bool,
        "profile.deviceTail4": .pattern(tail), "profile.signingCertInProfile": .bool,
        "codesign": .object, "codesign.teamIdentifier": .pattern(team),
        "install": .object, "install.classification": .pattern(code), "install.exitCode": .int,
        "install.timedOut": .bool, "install.outcome": .shapedFree("failed|success|succeeded"),
        "install.errorChain": .array, "install.errorChain[]": .object,
        "install.errorChain[].depth": .int,
        "install.errorChain[].domain": .knownOrShapedFree(
            known: knownDomains, pattern: #"(?=.{1,96}$)[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*"#),
        "install.errorChain[].code": .int, "install.errorChain[].codeHex": .pattern(hex32),
        "install.errorChain[].description": .freeText, "install.errorChain[].failureReason": .freeText,
        "install.errorChain[].recoverySuggestion": .freeText,
        "install.errorChain[].legacyErrorString": .shapedFree("[A-Za-z][A-Za-z0-9]{0,63}"),
        "install.errorChain[].libMISErrorNumber": .pattern("-?[0-9]{1,16}"),
        "install.errorChain[].codeSignature": .object,
        "install.errorChain[].codeSignature.code": .pattern(hex32),
        "install.errorChain[].codeSignature.message": .freeText,
        "install.errorChain[].codeSignature.appBundle": .const("Canary.app"),
        "install.stderr": .array, "install.stderr[]": .freeText,
        "install.omitted": .object, "install.omitted.nodes": .int, "install.omitted.messages": .int,
        "install.omitted.stderrLines": .int,
    ]

    /// True when `path` has a pattern shape and `value` matches it whole (used by the builder to leave out a value
    /// that is not the shape we expect, instead of writing it).
    static func accepts(_ path: String, _ value: String) -> Bool {
        guard case .pattern(let p)? = fields[path] else { return false }
        return EvidenceVerifier.matches(p, value)
    }

    /// One line of `logs/canary.jsonl`.
    static let logFields: [String: Shape] = [
        "ts": .pattern(iso), "status": .pattern("working|blocked|error"), "code": .pattern(code),
        "device": .pattern(tail), "xcodeVersion": .pattern(xcode), "guard": .pattern(#"skipped|passed|failed:[A-Z_]{0,32}"#),
        "durationMs": .int, "macosVersion": .pattern(version), "iosVersion": .pattern(version),
        "certFp": .pattern("[0-9a-f]{8}"), "certNotAfter": .pattern(#"\d{4}-\d{2}-\d{2}"#),
    ]
}

enum EvidenceVerifier {
    private static let forbiddenInText: Set<Character> = ["%", "+", "@", "/", "\\", "_", "<", ">", "#", "=", "&", "?"]

    fileprivate static func matches(_ pattern: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // MARK: A. the closed schema

    /// Labels of every schema violation: an unknown key, a wrong type, or a value outside its shape. For free-text
    /// paths this also runs check B.
    static func schemaHits(_ tree: JSONValue, fields: [String: EvidenceSchema.Shape], tokens: [String], bundleId: String) -> [String] {
        var found: [String] = []
        func add(_ label: String) { if !found.contains(label) { found.append(label) } }

        func walk(_ value: JSONValue, _ path: String) {
            guard let shape = fields[path] else {
                add("unknown-key")
                return
            }
            if value == .null { return }
            switch (shape, value) {
            case (.object, .object(let o)):
                for key in o.keys.sorted() { walk(o[key]!, path.isEmpty ? key : path + "." + key) }
            case (.array, .array(let items)):
                for item in items { walk(item, path + "[]") }
            case (.bool, .bool): break
            case (.int, .number(let n)):
                if n != n.rounded() || abs(n) >= 9_007_199_254_740_992 { add("wrong-type") }
            case (.constInt(let k), .number(let n)):
                if n != Double(k) { add("wrong-value") }
            case (.const(let k), .string(let s)):
                if s != k { add("wrong-value") }
            case (.pattern(let p), .string(let s)):
                if !matches(p, s) { add("wrong-shape") }
            case (.freeText, .string(let s)):
                if !freeTextOK(s, tokens: tokens, bundleId: bundleId) { add("free-text") }
            case (.shapedFree(let p), .string(let s)):
                if !matches(p, s) { add("wrong-shape") }
                if !freeTextOK(s, tokens: tokens, bundleId: bundleId, everyToken: true) { add("free-text") }
            case (.knownOrShapedFree(let known, let p), .string(let s)):
                if !known.contains(s) {
                    if !matches(p, s) { add("wrong-shape") }
                    if !freeTextOK(s, tokens: tokens, bundleId: bundleId, everyToken: true) { add("free-text") }
                }
            default:
                add("wrong-type")
            }
        }
        // The root is an object whose keys are top-level paths.
        guard case .object(let top) = tree else { return ["wrong-type"] }
        for key in top.keys.sorted() { walk(top[key]!, key) }
        return found
    }

    // MARK: B. free text

    /// Printable ASCII (plus the curly quotes) without `%+@/\_<>#=&?`; then, with the bundle ID and `"Canary"` set
    /// aside, no subject token of four or more characters inside the letters and digits run together, and no
    /// shorter token as a whole word. `everyToken` (for identifiers kept without a vocabulary) matches a token of any
    /// length anywhere in the letters and digits run together.
    private static func freeTextOK(_ text: String, tokens: [String], bundleId: String, everyToken: Bool = false) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar == "\u{201C}" || scalar == "\u{201D}" { continue }
            guard scalar.value >= 0x20, scalar.value <= 0x7E, !forbiddenInText.contains(Character(scalar)) else { return false }
        }
        var rest = text
        if !bundleId.isEmpty { rest = rest.replacingOccurrences(of: bundleId, with: " ") }
        for open in ["\u{201C}", "\""] {
            for close in ["\u{201D}", "\""] { rest = rest.replacingOccurrences(of: open + "Canary" + close, with: " ") }
        }
        let lower = rest.lowercased()
        let squashed = String(lower.unicodeScalars.filter { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) }.map(Character.init))
        var runs: [String] = []
        var current = ""
        for ch in lower + " " {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                current.append(ch)
            } else if !current.isEmpty {
                runs.append(current)
                if current.hasSuffix("s") { runs.append(String(current.dropLast())) }
                current = ""
            }
        }
        for token in tokens where !token.isEmpty {
            if token.count >= 4 || everyToken {
                if squashed.contains(token) { return false }
            } else if runs.contains(token) {
                return false
            }
        }
        return true
    }

    // MARK: C. both rendered files

    private static func bodyHits(_ body: String, ids: [String]) -> [String] {
        var found: [String] = []
        func add(_ label: String) { if !found.contains(label) { found.append(label) } }
        if body.contains("@") { add("at-sign") }
        if body.lowercased().contains("/users") { add("users-path") }
        var run = 0, hasDigit = false, hasLetter = false
        for scalar in Array(body.unicodeScalars) + [" "] {
            let v = scalar.value
            let digit = v >= 0x30 && v <= 0x39
            let letter = (v >= 0x41 && v <= 0x46) || (v >= 0x61 && v <= 0x66)
            if digit || letter {
                run += 1
                hasDigit = hasDigit || digit
                hasLetter = hasLetter || letter
            } else {
                if run >= 9, hasDigit, hasLetter { add("hex-run") }
                run = 0
                hasDigit = false
                hasLetter = false
            }
        }
        let squashed = body.lowercased().replacingOccurrences(of: "-", with: "")
        for id in ids where id.count >= 8 {
            if squashed.contains(id.lowercased().replacingOccurrences(of: "-", with: "")) { add("device-id") }
        }
        return found
    }

    /// `bodies` are the rendered files; `tokens` and `ids` come from the run, as plain strings.
    static func hits(tree: JSONValue, bodies: [String], tokens: [String], ids: [String], bundleId: String) -> [String] {
        var found = schemaHits(tree, fields: EvidenceSchema.fields, tokens: tokens, bundleId: bundleId)
        for body in bodies {
            for label in bodyHits(body, ids: ids) where !found.contains(label) { found.append(label) }
        }
        return found
    }

    /// Check A on a `canary.jsonl` line (every field there is generated by sideload).
    static func logLineHits(_ line: JSONValue) -> [String] {
        schemaHits(line, fields: EvidenceSchema.logFields, tokens: [], bundleId: "")
    }
}
