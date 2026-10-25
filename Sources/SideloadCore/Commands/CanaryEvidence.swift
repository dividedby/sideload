import Darwin
import Foundation

/// The opt-in canary evidence bundle (`canary --evidence`, design sections 8 and 10): one folder
/// `$SIDELOAD_HOME/evidence/canary-<ts>/` holding `evidence.json` and `evidence.txt`, rendered from the same
/// tree, for the owner to attach to an open Apple Developer Support case by hand. sideload sends nothing.

/// Everything the bundle reports. Every field is optional: what the run did not learn is null ("unavailable").
struct EvidenceInput {
    struct Install {
        /// The classifier's code for the install (`0xe8008018`, `TIMEOUT`, ...).
        var classification: String?
        var exitCode: Int32?
        var timedOut: Bool
        /// What `ErrorChain.reduce` kept of the devicectl document and stderr.
        var reduction: ErrorChain.Reduction
    }

    var generatedAt: Date
    var status: String
    var code: String
    /// Already through `MessageFilter.admit`; nil when it was not admitted.
    var reason: String?
    var guardRecord: String
    var durationMs: Int
    var bundleId: String
    var macosVersion: String?
    var macosBuild: String?
    var xcode: String?
    var iosVersion: String?
    var iosBuild: String?
    /// The keychain's selected paid certificate (not proof of what Xcode signed with) and its short fingerprint.
    var certificate: CertInfo?
    var certFp: String?
    var guardFacts: Guard.Facts?
    var deviceTail4: String
    var install: Install?
    /// The owner's `appleSupportCase` config value; left out of the bundle unless it has the schema's shape.
    var appleCase: String? = nil
}

/// Who and what must not appear in a bundle, as raw values. `SubjectTokens.make` turns them into the words the
/// reducer and the verifier look for; `InstallLogScrubber` uses them for the local log.
struct EvidenceSubjects {
    var ids: [String] = []
    /// Device names and hostnames: the saved devices' and every listed physical device's.
    var names: [String] = []
    var login = ""
    var fullName = ""
    /// Common names of every signing identity the keychain returned.
    var identityNames: [String] = []
    /// This Mac's `ComputerName` and `LocalHostName`.
    var computerName = ""
    var localHostName = ""
    /// The last component of the home directory.
    var homeName: String?
}

enum EvidenceBuilder {
    static let schema = 2

    static func iso(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(Date.ISO8601FormatStyle())) } ?? .null
    }

    /// A string we did not write ourselves, kept only if it has the schema's shape for `path`.
    private static func shaped(_ path: String, _ value: String?) -> JSONValue {
        guard let value, EvidenceSchema.accepts(path, value) else { return .null }
        return .string(value)
    }

    private static func bool(_ value: Bool?) -> JSONValue { value.map(JSONValue.bool) ?? .null }

    /// First eight lowercase hex digits of a certificate's SHA-1 fingerprint (`KeychainCertificate.reference`).
    /// Never more: no serial and no full fingerprint appear in a bundle or the log.
    static func certFp(_ reference: String) -> String {
        String(reference.prefix(8)).lowercased()
    }

    private static func count(_ n: Int) -> JSONValue { .number(Double(n)) }

    static func node(_ n: ErrorChain.Node) -> JSONValue {
        let signature: JSONValue =
            n.codeSignature.map {
                [
                    "code": .string($0.code), "message": $0.message.map(JSONValue.string) ?? .null,
                    "appBundle": $0.appBundle.map(JSONValue.string) ?? .null,
                ]
            } ?? .null
        return [
            "depth": count(n.depth), "domain": n.domain.map(JSONValue.string) ?? .null, "code": count(n.code),
            "codeHex": n.codeHex.map(JSONValue.string) ?? .null, "description": n.description.map(JSONValue.string) ?? .null,
            "failureReason": n.failureReason.map(JSONValue.string) ?? .null,
            "recoverySuggestion": n.recoverySuggestion.map(JSONValue.string) ?? .null,
            "legacyErrorString": n.legacyErrorString.map(JSONValue.string) ?? .null,
            "libMISErrorNumber": n.libMISErrorNumber.map(JSONValue.string) ?? .null, "codeSignature": signature,
        ]
    }

    static func build(_ i: EvidenceInput) -> JSONValue {
        let facts = i.guardFacts
        let install: JSONValue
        if let n = i.install {
            let r = n.reduction
            install = [
                "classification": shaped("install.classification", n.classification),
                "exitCode": n.exitCode.map { .number(Double($0)) } ?? .null,
                "timedOut": .bool(n.timedOut),
                "outcome": r.outcome.map(JSONValue.string) ?? .null,
                "errorChain": .array(r.nodes.map(node)),
                "stderr": .array(r.stderr.map(JSONValue.string)),
                "omitted": [
                    "nodes": count(r.omittedNodes), "messages": count(r.omittedMessages),
                    "stderrLines": count(r.omittedStderrLines),
                ],
            ]
        } else {
            install = .null
        }
        return [
            "schema": .number(Double(schema)),
            "generatedAt": .string(i.generatedAt.formatted(Date.ISO8601FormatStyle())),
            "appleCase": shaped("appleCase", i.appleCase),
            "team": .string(Team.id),
            "bundleId": shaped("bundleId", i.bundleId),
            "run": [
                "status": .string(i.status), "code": shaped("run.code", i.code),
                "reason": i.reason.map(JSONValue.string) ?? .null, "guard": shaped("run.guard", i.guardRecord),
                "durationMs": .number(Double(i.durationMs)),
            ],
            "environment": [
                "macos": [
                    "version": shaped("environment.macos.version", i.macosVersion),
                    "build": shaped("environment.macos.build", i.macosBuild),
                ],
                "xcode": shaped("environment.xcode", i.xcode),
                "ios": [
                    "version": shaped("environment.ios.version", i.iosVersion),
                    "build": shaped("environment.ios.build", i.iosBuild),
                ],
            ],
            "keychainCertificate": [
                "ou": shaped("keychainCertificate.ou", i.certificate?.teamOU), "notBefore": iso(i.certificate?.notBefore),
                "notAfter": iso(i.certificate?.notAfter), "certFp": shaped("keychainCertificate.certFp", i.certFp),
            ],
            "profile": [
                "team": shaped("profile.team", facts?.profileTeam), "createdAt": iso(facts?.profileCreated),
                "expiresAt": iso(facts?.profileExpires),
                "deviceCount": facts?.deviceCount.map { .number(Double($0)) } ?? .null,
                "deviceIncluded": bool(facts?.deviceIncluded), "deviceTail4": shaped("profile.deviceTail4", i.deviceTail4),
                "signingCertInProfile": bool(facts?.signingCertInProfile),
            ],
            "codesign": ["teamIdentifier": shaped("codesign.teamIdentifier", facts?.signedTeam)],
            "install": install,
        ]
    }
}

/// `evidence.txt`: sectioned `key: value` lines from the same tree as `evidence.json`.
enum EvidenceText {
    static let sections = ["run", "environment", "keychainCertificate", "profile", "codesign", "install"]
    static let header = """
        sideload canary evidence (schema \(EvidenceBuilder.schema))
        For manual attachment to an open Apple Developer Support case. sideload sends nothing; you decide what to share.
        The certificate is identified by the first 8 hex digits of its SHA-1 fingerprint only. IDs are cut to their last 4 characters.
        Apple's messages appear only when every word is on sideload's fixed list; the others are counted under install.omitted, never edited.
        "unavailable" means the run could not learn that value.


        """

    static func render(_ tree: JSONValue) -> String {
        guard case .object(let top) = tree else { return header }
        var out = header
        for key in top.keys.sorted() where !sections.contains(key) {
            out += "\(key): \(scalar(top[key]!))\n"
        }
        for key in sections {
            guard let value = top[key] else { continue }
            out += "\n[\(key)]\n"
            if case .object = value { out += lines(path: "", value) } else { out += "unavailable\n" }
        }
        return out
    }

    /// `errorChain[0].domain: ...`: objects extend the path with `.key`, arrays with `[i]`.
    private static func lines(path: String, _ value: JSONValue) -> String {
        switch value {
        case .object(let fields):
            if fields.isEmpty { return "\(path): none\n" }
            return fields.keys.sorted().map { key in
                lines(path: path.isEmpty ? key : path + "." + key, fields[key]!)
            }.joined()
        case .array(let items):
            if items.isEmpty { return "\(path): none\n" }
            return items.enumerated().map { lines(path: "\(path)[\($0.offset)]", $0.element) }.joined()
        default:
            return "\(path): \(scalar(value))\n"
        }
    }

    private static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .null: return "unavailable"
        case .bool(let b): return b ? "yes" : "no"
        case .number(let n): return n == n.rounded() && abs(n) < 9_007_199_254_740_992 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .array, .object: return "unavailable"
        }
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "unavailable"
    }
}

/// Writes the two files of one bundle, or nothing. The files go into a hidden temporary folder inside `evidence/`
/// and the folder is renamed into place without overwriting, so an interrupted run leaves no half bundle under
/// its real name.
enum EvidenceWriter {
    enum Outcome: Equatable {
        /// Home-relative `evidence/canary-<ts>`.
        case written(dir: String, files: [String])
        case redactionFailed
        case writeFailed
    }

    static let files = ["evidence.json", "evidence.txt"]

    /// `stamp` is a filesystem-safe timestamp. A bundle that already exists is a failure; nothing is overwritten.
    /// `afterFirstFile` receives the temporary folder (a test seam: fail or inspect between the two writes).
    static func write(
        _ tree: JSONValue, stamp: String, home: Paths, tokens: SubjectTokens, bundleId: String,
        afterFirstFile: (String) -> Void = { _ in }
    ) -> Outcome {
        let jsonBody = Data(EvidenceText.pretty(tree).utf8) + Data("\n".utf8)
        let textBody = Data(EvidenceText.render(tree).utf8)
        let bodies = [jsonBody, textBody].map { String(decoding: $0, as: UTF8.self) }
        let found = EvidenceVerifier.hits(
            tree: tree, bodies: bodies, tokens: tokens.tokens, ids: tokens.ids, bundleId: bundleId)
        if !found.isEmpty { return .redactionFailed }

        let dir = "\(home.evidence)/canary-\(stamp)"
        let tmp = "\(home.evidence)/.canary-\(stamp).\(getpid()).\(randomHex(bytes: 4)).tmp"
        var created = false
        do {
            try makeDirectories(home.evidence, mode: 0o700)
            if chmod(home.evidence, 0o700) != 0 { throw ioError("chmod") }
            if mkdir(tmp, 0o700) != 0 { throw ioError("mkdir") }
            created = true
            if chmod(tmp, 0o700) != 0 { throw ioError("chmod") }
            try AtomicFile.write(jsonBody, to: tmp + "/evidence.json", mode: 0o600)
            afterFirstFile(tmp)
            try AtomicFile.write(textBody, to: tmp + "/evidence.txt", mode: 0o600)
            // RENAME_EXCL: fails with EEXIST instead of replacing a bundle that is already there.
            if renamex_np(tmp, dir, UInt32(RENAME_EXCL)) != 0 { throw ioError("rename") }
        } catch {
            if created { try? FileManager.default.removeItem(atPath: tmp) }
            return .writeFailed
        }
        return .written(dir: "evidence/canary-\(stamp)", files: files)
    }
}
