import Darwin
import Foundation

/// `logs/refresh.jsonl`: what `refresh --auto` decided and did (design section 18), one JSON line each. Only aliases, app names,
/// codes and numbers go in (never a device ID, a device or identity name, a path or a message), every string is cleaned here
/// whatever the caller passes, and a write that fails is ignored: logging never breaks a run.
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
        var line = fields
        line["ts"] = .string(ProgressLog.isoTimestamp(clock.now()))
        line["run"] = .string(run)
        line["event"] = .string(event)
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

    static func alias(_ raw: String) -> String { DeviceCommand.isValidAlias(raw) ? raw : "?" }

    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
}
