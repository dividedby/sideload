import Foundation

/// The verdict on a canary install or build. Carries `status`, `code` and `reason`.
public struct Classification: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// Apple fixed the install block.
        case working
        /// The known account-side defect (or a provisional code with the guard passed).
        case blocked
        /// Anything unrelated to the account.
        case error
    }

    public let status: Status
    public let code: String
    public let reason: String

    public init(status: Status, code: String, reason: String) {
        self.status = status
        self.code = code
        self.reason = reason
    }
}

/// Pure classification of `devicectl device install app` results (design section 10). The failure JSON shape is unverified, so the whole document is
/// searched. No I/O.
public enum InstallClassifier {
    public struct Input: Sendable, Equatable {
        public var exitCode: Int32?
        public var json: JSONValue?
        public var stderr: String
        public var timedOut: Bool
        public var overflow: Bool
        public var guardPassed: Bool
        public var bundleId: String?
        /// The free team's `install` / `slot` / `app remove` path (`FreeInstallClassifier`). Only then are the free-team
        /// patterns (`FREE_APP_LIMIT`, `UNTRUSTED_DEVELOPER`, `DEVICE_NOT_PAIRED`) read; the paid canary's codes for every
        /// other input are unchanged.
        public var freeTeam: Bool

        public init(
            exitCode: Int32? = nil, json: JSONValue? = nil, stderr: String = "", timedOut: Bool = false,
            overflow: Bool = false, guardPassed: Bool = false, bundleId: String? = nil, freeTeam: Bool = false
        ) {
            self.freeTeam = freeTeam
            self.exitCode = exitCode
            self.json = json
            self.stderr = stderr
            self.timedOut = timedOut
            self.overflow = overflow
            self.guardPassed = guardPassed
            self.bundleId = bundleId
        }
    }

    /// The forms an OSStatus-style code can take: `0xe8008018`, signed `-402620392`, unsigned `3892346904`.
    public struct CodeForms: Sendable, Equatable {
        public let hex: String
        public let unsigned: String
        public let signed: String

        /// `hex` is a `0x`-prefixed 32-bit value.
        public init(hex: String) {
            let digits = hex.lowercased().hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            let bits = UInt32(truncatingIfNeeded: UInt64(digits, radix: 16) ?? 0)
            self.hex = "0x" + String(bits, radix: 16)
            self.unsigned = String(bits)
            self.signed = String(Int32(bitPattern: bits))
        }
    }

    static let invalidIdentity = CodeForms(hex: "0xe8008018")
    static let profileNotFound = CodeForms(hex: "0xe8008015")
    static let entitlements = CodeForms(hex: "0xe8008016")
    static let badSignature = CodeForms(hex: "0xe800801c")

    public static func classify(_ input: Input) -> Classification {
        if input.overflow {
            return Classification(
                status: .error, code: "OUTPUT_LIMIT",
                reason: "devicectl produced more output than the safety limit; the install outcome is unknown.")
        }
        let leaves = Leaf.walk(input.json)
        let all = input.stderr.isEmpty ? leaves : leaves + [Leaf(key: "stderr", value: .string(input.stderr))]

        if input.exitCode == 0, !input.timedOut, outcome(of: input.json) != "failed",
            bundleListed(leaves, input.bundleId)
        {
            return Classification(
                status: .working, code: "INSTALLED", reason: "Install succeeded; Apple has fixed the install block.")
        }

        if has(all, invalidIdentity) || hasText(all, { $0.contains(ignoringCase: "identity used to sign the executable is no longer valid") }) {
            return Classification(
                status: .blocked, code: invalidIdentity.hex,
                reason: "Device rejected the signing identity (known account-side defect; Apple support case open).")
        }

        // The free team's own limit (design section 18): installd refuses a 4th app signed with a free profile.
        if input.freeTeam, hasText(all, { $0.matches(freeAppLimitPattern) }) {
            return Classification(
                status: .error, code: "FREE_APP_LIMIT",
                reason: "The device already has the maximum number of apps signed with a free developer profile.")
        }

        let provisional: [(CodeForms, String)] = [
            (profileNotFound, "Device did not recognise the provisioning profile."),
            (entitlements, "Entitlements are not allowed by the provisioning profile."),
            (badSignature, "Device rejected the code signature."),
        ]
        for (forms, reason) in provisional where has(all, forms) {
            return input.guardPassed
                ? Classification(status: .blocked, code: forms.hex, reason: reason)
                : Classification(
                    status: .error, code: forms.hex,
                    reason: "\(reason) The pre-install guard did not pass, so this is not attributed to the account.")
        }

        if input.timedOut || input.stderr.matches(timeoutPattern) || hasText(leaves, { $0.matches(timedOutPattern) }) {
            return Classification(status: .error, code: "TIMEOUT", reason: "devicectl timed out.")
        }
        if input.freeTeam, hasText(all, { $0.matches(untrustedPattern) }) {
            return Classification(
                status: .error, code: "UNTRUSTED_DEVELOPER", reason: "The device has not trusted this developer yet.")
        }
        if input.freeTeam, hasText(all, { $0.matches(notPairedPattern) }) {
            return Classification(status: .error, code: "DEVICE_NOT_PAIRED", reason: "The device is not paired with this Mac.")
        }
        if hasText(all, { $0.matches(lockedPattern) }) {
            return Classification(
                status: .error, code: "DEVICE_LOCKED", reason: "The device appears to be locked; unlock it and retry.")
        }
        if hasText(all, { $0.matches(notConnectedPattern) }) {
            return Classification(
                status: .error, code: "DEVICE_NOT_CONNECTED", reason: "The device is not connected or not reachable.")
        }
        if hasText(all, { $0.matches(diskFullPattern) }) {
            return Classification(status: .error, code: "DISK_FULL", reason: "The device is out of storage.")
        }

        let raw = firstRawCode(leaves)
        if input.exitCode == 0, !input.timedOut {
            return Classification(
                status: .error, code: "INSTALL_UNCONFIRMED",
                reason: "devicectl exited 0 but did not report the canary as installed.")
        }
        return Classification(status: .error, code: raw ?? "UNKNOWN", reason: "Unrecognised install failure.")
    }

    // MARK: - Patterns (all case-insensitive)

    private static let timeoutPattern = "timed out|timeout"
    private static let timedOutPattern = "timed out"
    /// installd: "...reached the maximum number of installed apps using a free developer profile".
    private static let freeAppLimitPattern = "maximum number of (installed )?apps (using|with|for) (a )?free (developer |development )?profiles?"
    private static let untrustedPattern = "untrusted developer|not (been )?(explicitly )?trusted by the user|developer (app )?(is )?not trusted"
    private static let notPairedPattern = "not paired|no pairing record|pairing (is )?required|trust this computer"
    private static let lockedPattern = "locked|passcode"
    private static let notConnectedPattern =
        "not connected|unavailable|no devices? (found|matched)|could not be found|disconnected"
    private static let diskFullPattern =
        "no space|disk full|insufficient (storage|space)|not enough (storage|space)"

    // MARK: - Leaf matching

    private static func outcome(of json: JSONValue?) -> String? {
        guard case .object(let top)? = json, case .object(let info)? = top["info"],
            case .string(let outcome)? = info["outcome"]
        else { return nil }
        return outcome
    }

    private static func matchesCode(_ leaf: Leaf, _ forms: CodeForms) -> Bool {
        switch leaf.value {
        case .number(let n):
            // Bare numbers only count under a `code`-like key.
            guard leaf.key.contains(ignoringCase: "code") else { return false }
            let s = numberString(n)
            return s == forms.signed || s == forms.unsigned
        case .string(let s):
            if s.lowercased().contains(forms.hex) { return true }
            return containsUnembedded(s, forms.signed) || containsUnembedded(s, forms.unsigned)
        }
    }

    /// `needle` with no ASCII digit directly before or after it (so it is not part of a longer number).
    private static func containsUnembedded(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8)
        let n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return false }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        for start in 0...(h.count - n.count) where h[start..<(start + n.count)].elementsEqual(n) {
            if start > 0, isDigit(h[start - 1]) { continue }
            let end = start + n.count
            if end < h.count, isDigit(h[end]) { continue }
            return true
        }
        return false
    }

    private static func has(_ leaves: [Leaf], _ forms: CodeForms) -> Bool {
        leaves.contains { matchesCode($0, forms) }
    }

    private static func hasText(_ leaves: [Leaf], _ test: (String) -> Bool) -> Bool {
        leaves.contains { if case .string(let s) = $0.value { return test(s) } else { return false } }
    }

    private static func bundleListed(_ leaves: [Leaf], _ bundleId: String?) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return false }
        return leaves.contains { $0.value == .string(bundleId) }
    }

    private static func firstRawCode(_ leaves: [Leaf]) -> String? {
        for leaf in leaves {
            switch leaf.value {
            case .number(let n) where leaf.key.contains(ignoringCase: "code"):
                return numberString(n)
            case .string(let s):
                if let m = s.firstMatch(of: /0x[0-9a-fA-F]{6,8}/) { return String(m.output).lowercased() }
            default:
                break
            }
        }
        return nil
    }

    /// A JSON number as JavaScript's `String(n)` renders the cases devicectl produces (integers).
    static func numberString(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    }
}

/// A string or number found while walking a JSON document, with the nearest enclosing object key
/// (array elements inherit their array's key; the top level has the empty key).
struct Leaf: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case string(String)
        case number(Double)
    }

    let key: String
    let value: Value

    /// Depth-first. JSON objects are unordered here, so keys are visited in sorted order, so only the
    /// "first raw code" tie-break depends on key order.
    static func walk(_ json: JSONValue?) -> [Leaf] {
        var out: [Leaf] = []
        func visit(_ v: JSONValue, _ key: String) {
            switch v {
            case .string(let s): out.append(Leaf(key: key, value: .string(s)))
            case .number(let n): out.append(Leaf(key: key, value: .number(n)))
            case .array(let items): for item in items { visit(item, key) }
            case .object(let fields): for k in fields.keys.sorted() { visit(fields[k]!, k) }
            case .bool, .null: break
            }
        }
        if let json { visit(json, "") }
        return out
    }
}

extension String {
    /// Case-insensitive substring test.
    func contains(ignoringCase needle: String) -> Bool {
        range(of: needle, options: .caseInsensitive) != nil
    }

    /// Case-insensitive unanchored regular-expression test.
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
