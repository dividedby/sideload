import Darwin
import Foundation

/// `logs/refresh.jsonl`: what `refresh --auto` decided and did (design section 18), one JSON line each. Only aliases, app names,
/// codes and numbers go in (never a device ID, a device or identity name, a path or a message): `record` cleans every field
/// itself (`device` as an alias, `code` and `reason` as codes, the keys of `skipped` as codes, any other string as a plain
/// token, anything that is not a scalar not at all), so no caller can forget. A write that fails is ignored: logging never
/// breaks a run.
struct RefreshLog: Sendable {
    /// The file is moved to `refresh.jsonl.1` (replacing the older one) once it reaches this size, so the log stays near 2 MiB.
    static let rotateAt = 1 << 20

    let paths: Paths
    let clock: any WallClock
    /// Ties the lines of one invocation together.
    let run: String

    /// A short random id for one invocation.
    static func newRunId() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    func record(_ event: String, _ fields: [String: JSONValue] = [:]) {
        var line = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, Self.cleaned($0.key, $0.value)) })
        line["ts"] = .string(ProgressLog.isoTimestamp(clock.now()))
        line["run"] = .string(Self.token(run))
        line["event"] = .string(Self.token(event))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(line)) else { return }
        try? makeDirectories(paths.logs, mode: 0o700)
        rotateIfNeeded()
        try? AppendFile.appendLine(String(decoding: data, as: UTF8.self), to: paths.refreshLog)
    }

    private func rotateIfNeeded() {
        var st = stat()
        guard lstat(paths.refreshLog, &st) == 0, st.st_size >= Self.rotateAt else { return }
        _ = rename(paths.refreshLog, paths.refreshLog + ".1")
    }

    // MARK: cleaning

    /// A failure or skip code: upper case words as this code base writes them. Anything else, or anything that holds a run of
    /// hex digits long enough to be a device ID, is `OTHER`.
    static func code(_ raw: String) -> String {
        guard raw.wholeMatch(of: /[A-Z][A-Z0-9_]{1,47}/) != nil, raw.firstMatch(of: /[0-9A-F]{12}/) == nil else { return "OTHER" }
        return raw
    }

    /// A plain word or timestamp (`renewed-not-installed`, `2026-10-21T12:00:00.000Z`); anything else, or a run of hex digits
    /// long enough to be a device ID, is `?`.
    static func token(_ raw: String) -> String {
        guard raw.wholeMatch(of: /[A-Za-z0-9:.\-]{1,40}/) != nil, raw.firstMatch(of: /[0-9A-Fa-f]{12}/) == nil else { return "?" }
        return raw
    }

    /// One field as it is written: by its key, an alias, a code, a tally keyed by code, or a token; numbers and booleans as they are.
    static func cleaned(_ key: String, _ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            switch key {
            case "device": return .string(alias(text))
            case "code", "reason", "probe": return .string(code(text))
            default: return .string(token(text))
            }
        case .object(let counts) where key == "skipped":
            var tally: [String: JSONValue] = [:]
            for (name, count) in counts {
                guard case .number(let n) = count else { continue }
                let clean = code(name)
                if case .number(let before)? = tally[clean] { tally[clean] = .number(before + n) } else { tally[clean] = count }
            }
            return .object(tally)
        case .bool, .number: return value
        case .null, .array, .object: return .null
        }
    }

    /// A valid alias that is not a device ID typed by mistake.
    static func alias(_ raw: String) -> String {
        DeviceCommand.isValidAlias(raw) && raw.firstMatch(of: /[0-9A-Fa-f]{12}/) == nil ? raw : "?"
    }

    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
}
