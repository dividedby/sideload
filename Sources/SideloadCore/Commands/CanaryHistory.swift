import Foundation

/// `canary history`: read-only summary of `logs/canary.jsonl` (design section 8). Runs no subprocess, takes no
/// operation lock and does no device or portal work. File order is chronological. Blank lines are ignored;
/// a non-blank line that is not a JSON object with a string `status` is skipped and counted.
public enum CanaryHistory {
    static let command = "canary history"
    static let recentCount = 10
    /// The fields compared between the last `working` run and the first `blocked` run after it.
    static let comparedFields = ["xcodeVersion", "macosVersion", "iosVersion", "certFp", "certNotAfter"]
    /// Fields shown for a run. `device` stays out: the history prints versions and dates, not identifiers.
    private static let shownFields = ["ts", "status", "code"] + comparedFields

    public static func run(_ services: Services) -> Envelope {
        do {
            return .result(command, summarize(try read(services.home.canaryLog)))
        } catch {
            return .from(error, command: command)
        }
    }

    struct Parsed {
        var records: [[String: JSONValue]] = []
        var skipped = 0
    }

    static func read(_ path: String) throws -> Parsed {
        guard let data = try readFile(path) else { return Parsed() }
        var parsed = Parsed()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            if line.allSatisfy(\.isWhitespace) { continue }
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                case .object(let fields) = value, case .string? = fields["status"]
            {
                parsed.records.append(fields)
            } else {
                parsed.skipped += 1
            }
        }
        return parsed
    }

    private static func status(_ record: [String: JSONValue]) -> String? { record["status"]?.stringValue }

    private static func compact(_ record: [String: JSONValue]?) -> JSONValue {
        guard let record else { return .null }
        var out: [String: JSONValue] = [:]
        for field in shownFields { out[field] = record[field] ?? .null }
        return .object(out)
    }

    static func summarize(_ parsed: Parsed) -> [String: JSONValue] {
        let records = parsed.records
        var counts: [String: JSONValue] = [:]
        for record in records {
            let s = status(record) ?? ""
            if case .number(let n)? = counts[s] { counts[s] = .number(n + 1) } else { counts[s] = .number(1) }
        }

        let lastWorkingIndex = records.lastIndex { status($0) == "working" }
        let firstBlocked = records.first { status($0) == "blocked" }
        // The first `blocked` run after the last `working` one; `error` runs in between say nothing about the block.
        let firstBlockedAfterWorking = lastWorkingIndex.flatMap { index in
            records[(index + 1)...].first { status($0) == "blocked" }
        }

        var changes: JSONValue = .null
        var incomparable: JSONValue = .null
        if let lastWorkingIndex, let after = firstBlockedAfterWorking {
            let before = records[lastWorkingIndex]
            var changed: [JSONValue] = []
            var missing: [JSONValue] = []
            for field in comparedFields {
                guard let from = before[field]?.stringValue, let to = after[field]?.stringValue else {
                    missing.append(.string(field))
                    continue
                }
                if from != to { changed.append(["field": .string(field), "from": .string(from), "to": .string(to)]) }
            }
            changes = .array(changed)
            incomparable = .array(missing)
        }

        return [
            "runs": .number(Double(records.count)), "skipped": .number(Double(parsed.skipped)),
            "statusCounts": .object(counts), "first": compact(records.first), "last": compact(records.last),
            "lastWorking": compact(lastWorkingIndex.map { records[$0] }),
            "firstBlocked": compact(firstBlocked),
            "firstBlockedAfterWorking": compact(firstBlockedAfterWorking),
            "changes": changes, "incomparable": incomparable,
            "recent": .array(records.suffix(recentCount).map(compact)),
        ]
    }
}

extension JSONValue {
    fileprivate var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
