import Foundation
import Synchronization

/// Scrubbing of the saved `devicectl device install app` JSON: the value of a device-identifying key becomes `<device>`, and the device's
/// names and hostnames are replaced inside every other string and key (case and apostrophe style do not matter
/// for names of three or more characters; see `TextMatch`).
enum InstallScrubber {
    static let placeholder = "<device>"
    static let sensitiveKeys: Set<String> = [
        "deviceName", "hostname", "hostName", "dnsName", "potentialHostnames", "serialNumber", "ecid",
    ]

    /// Literals of three or more characters are replaced as substrings; shorter ones only as whole words in
    /// string values (never in keys), so a short name cannot mangle unrelated text.
    static func scrub(_ value: JSONValue, literals: [String], key: String = "", inKey: Bool = false) -> JSONValue {
        if sensitiveKeys.contains(key) && !inKey { return .string(placeholder) }
        switch value {
        case .string(let s):
            return .string(scrubString(s, literals: literals, inKey: inKey))
        case .array(let items):
            return .array(items.map { scrub($0, literals: literals, key: key) })
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            // Sorted so keys colliding after scrubbing resolve deterministically (last wins).
            for k in fields.keys.sorted() {
                out[scrubString(k, literals: literals, inKey: true)] = scrub(fields[k]!, literals: literals, key: k)
            }
            return .object(out)
        case .null, .bool, .number:
            return value
        }
    }

    static func scrubString(_ string: String, literals: [String], inKey: Bool) -> String {
        literals.reduce(string) { s, lit in
            if lit.utf16.count < 3 && inKey { return s }
            return TextMatch.replace(s, name: lit, with: placeholder)
        }
    }

    /// Names and hostnames saved in config (devices by alias, each name then its hostnames) plus whatever
    /// `devicectl list devices` shows now (best effort), longest first; equal lengths keep that insertion
    /// order. (A decoded `Config` has no file order.)
    static func literals(config: Config, listed: [ListedDevice]?) -> [String] {
        var found: [String] = []
        func add(_ l: String) { if !l.isEmpty && !found.contains(l) { found.append(l) } }
        for alias in config.devices.keys.sorted() {
            let d = config.devices[alias]!
            if let name = d.name { add(name) }
            d.hostnames.forEach(add)
        }
        for d in listed ?? [] where d.physical {
            add(d.name)
            d.hostnames.forEach(add)
        }
        // Explicit index tie-break: the order of equal lengths must not depend on the sort's stability.
        return found.enumerated().sorted { a, b in
            a.element.utf16.count != b.element.utf16.count
                ? a.element.utf16.count > b.element.utf16.count : a.offset < b.offset
        }.map(\.element)
    }

    /// Drops what carries paths and device ids (`info.environment`, `info.arguments`) and scrubs the rest.
    static func scrubbed(_ json: JSONValue?, literals: [String]) -> JSONValue {
        var copy = json ?? ["note": "devicectl wrote no JSON"]
        if case .object(var top) = copy, case .object(var info)? = top["info"] {
            info["environment"] = nil
            info["arguments"] = nil
            top["info"] = .object(info)
            copy = .object(top)
        }
        return Redactor().redact(scrub(copy, literals: literals))
    }
}

/// Tolerant text matching used by the scrubbers (`InstallScrubber`, `InstallLogScrubber`). Names of three or more characters match as substrings, ignoring case,
/// apostrophe style (`'` `’` `‘` `ʼ`) and runs of whitespace. Shorter names match only as whole words, exactly
/// (a short name must not mangle unrelated text).
enum TextMatch {
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`", "\u{00B4}"]
    private static let apostropheClass = "['\u{2019}\u{2018}\u{02BC}`\u{00B4}]"
    private static let cache = Mutex<[String: NSRegularExpression]>([:])

    private static func pattern(_ literal: String) -> String {
        var out = ""
        var inSpace = false
        for ch in literal {
            if ch.isWhitespace {
                if !inSpace { out += #"\s+"# }
                inSpace = true
                continue
            }
            inSpace = false
            out += apostrophes.contains(ch) ? apostropheClass : NSRegularExpression.escapedPattern(for: String(ch))
        }
        return out
    }

    private static let wordBefore = "(?<![A-Za-z0-9_])"
    private static let wordAfter = "(?![A-Za-z0-9_])"

    /// `wholeWord` adds word boundaries; `ignoreCase` makes the match case-insensitive.
    static func regex(_ literal: String, wholeWord: Bool, ignoreCase: Bool) -> NSRegularExpression? {
        let key = "\(wholeWord ? "w" : "p")\(ignoreCase ? "i" : "s"):\(literal)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let body = wholeWord ? wordBefore + pattern(literal) + wordAfter : pattern(literal)
        guard let re = try? NSRegularExpression(pattern: body, options: ignoreCase ? [.caseInsensitive] : []) else {
            return nil
        }
        cache.withLock { $0[key] = re }
        return re
    }

    /// The matcher for a device name or hostname.
    static func nameRegex(_ literal: String) -> NSRegularExpression? {
        let long = literal.utf16.count >= 3
        return regex(literal, wholeWord: !long, ignoreCase: long)
    }

    static func replace(_ s: String, name: String, with replacement: String) -> String {
        replace(s, regex: nameRegex(name), with: replacement)
    }

    static func replace(_ s: String, regex: NSRegularExpression?, with replacement: String) -> String {
        guard let regex, !s.isEmpty else { return s }
        return regex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func contains(_ s: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func contains(_ s: String, name: String) -> Bool {
        !name.isEmpty && contains(s, regex: nameRegex(name))
    }

    /// The forms a name takes in other places: a name with spaces also as a hostname-style `Janes-iPhone`
    /// (apostrophes dropped, spaces to hyphens); a hostname also as its first label (`jane-phone` for
    /// `jane-phone.coredevice.local`). Longest first; equal lengths keep their order.
    static func expand(_ literals: [String]) -> [String] {
        var found: [String] = []
        func add(_ s: String) { if !s.isEmpty && !found.contains(s) { found.append(s) } }
        for lit in literals {
            add(lit)
            if lit.contains(where: \.isWhitespace) {
                let hyphenated = lit.filter { !apostrophes.contains($0) }
                    .split(whereSeparator: \.isWhitespace).joined(separator: "-")
                add(hyphenated)
            } else if let dot = lit.firstIndex(of: "."), dot != lit.startIndex {
                add(String(lit[..<dot]))
            }
        }
        return found.enumerated().sorted { a, b in
            a.element.utf16.count != b.element.utf16.count
                ? a.element.utf16.count > b.element.utf16.count : a.offset < b.offset
        }.map(\.element)
    }
}

/// The masker for the local log `logs/canary-install-*.json`, which keeps the raw devicectl document shape. It is a
/// denylist (names, hostnames, IDs, the person and the signing identities are rewritten wherever they are found),
/// so it is good enough for a file that stays on this Mac and is never attached anywhere. The evidence bundle does
/// not use it and never reads that file: the bundle is built by `ErrorChain.reduce`, an allowlist.
enum InstallLogScrubber {
    /// What to look for. Raw values; the matching forms are derived.
    struct Subjects {
        var ids: [String] = []
        var names: [String] = []
        var login = ""
        var fullName = ""
        var identityNames: [String] = []

        init(_ s: EvidenceSubjects) {
            ids = s.ids
            // The Mac's own names are masked in the local log too.
            names = s.names + [s.computerName, s.localHostName].filter { !$0.isEmpty }
            login = s.login
            fullName = s.fullName
            identityNames = s.identityNames
        }

        /// Names and hostnames plus their hostname-style and first-label forms, longest first.
        var nameLiterals: [String] { TextMatch.expand(names) }

        /// An ID as written, without hyphens (MobileDevice error strings), in any case; masked to the original's last 4.
        var idForms: [(regex: NSRegularExpression, tail: String)] {
            ids.filter { !$0.isEmpty }.flatMap { id in
                [id, id.replacingOccurrences(of: "-", with: "")].compactMap { form in
                    TextMatch.regex(form, wholeWord: false, ignoreCase: true).map { ($0, Redactor.tail4(id)) }
                }
            }
        }

        /// The login name (any length, whole word), the full name and each of its words of four or more characters.
        var personRegexes: [NSRegularExpression] {
            var out: [NSRegularExpression?] = []
            if !login.isEmpty { out.append(TextMatch.regex(login, wholeWord: true, ignoreCase: true)) }
            let full = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if full.utf16.count >= 3 { out.append(TextMatch.regex(full, wholeWord: false, ignoreCase: true)) }
            for word in full.split(whereSeparator: \.isWhitespace) where word.utf16.count >= 4 {
                out.append(TextMatch.regex(String(word), wholeWord: true, ignoreCase: true))
            }
            return out.compactMap { $0 }
        }

        /// Each common name whole, plus the person's name and the 10-character personal ID inside `Apple Development: Name (ID)`.
        var identityRegexes: [NSRegularExpression] {
            var out: [NSRegularExpression?] = []
            for cn in identityNames where cn.count >= 3 {
                out.append(TextMatch.regex(cn, wholeWord: false, ignoreCase: true))
                let ns = cn as NSString
                if let m = SubjectTokens.identityShape.firstMatch(in: cn, range: NSRange(location: 0, length: ns.length)) {
                    let person = ns.substring(with: m.range(at: 1)), id = ns.substring(with: m.range(at: 2))
                    out.append(TextMatch.regex(person, wholeWord: true, ignoreCase: true))
                    out.append(TextMatch.regex(id, wholeWord: false, ignoreCase: true))
                }
            }
            return out.compactMap { $0 }
        }
    }

    private static let percentEmail = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+-]+%40[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, options: [.caseInsensitive])
    private static let lowerUsers = try! NSRegularExpression(
        pattern: #"/users/(?!<user>)[^/\s"']+"#, options: [.caseInsensitive])

    /// The text-level mask: `inKey` says the text is a JSON key (short names are never masked inside keys).
    static func masker(_ subjects: Subjects) -> (String, Bool) -> String {
        let names = subjects.nameLiterals
        let ids = subjects.idForms, people = subjects.personRegexes, identities = subjects.identityRegexes
        let redactor = Redactor(literals: subjects.ids)
        return { input, inKey in
            var out = InstallScrubber.scrubString(input, literals: names, inKey: inKey)
            for id in ids { out = TextMatch.replace(out, regex: id.regex, with: id.tail) }
            for re in identities { out = TextMatch.replace(out, regex: re, with: "<user>") }
            for re in people { out = TextMatch.replace(out, regex: re, with: "<user>") }
            out = TextMatch.replace(out, regex: percentEmail, with: "<email>")
            out = TextMatch.replace(out, regex: lowerUsers, with: "/Users/<user>")
            return redactor.redact(out)
        }
    }

    /// A devicectl document: sensitive keys, then every key and value.
    static func document(_ json: JSONValue, _ subjects: Subjects) -> JSONValue {
        mapAll(InstallScrubber.scrub(json, literals: subjects.nameLiterals), masker(subjects))
    }

    /// Keys are masked too; `f`'s flag says it is a key (short names are never masked inside keys).
    private static func mapAll(_ value: JSONValue, _ f: (String, Bool) -> String) -> JSONValue {
        switch value {
        case .string(let s): return .string(f(s, false))
        case .array(let items): return .array(items.map { mapAll($0, f) })
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for key in fields.keys.sorted() { out[f(key, true)] = mapAll(fields[key]!, f) }
            return .object(out)
        case .null, .bool, .number: return value
        }
    }
}
