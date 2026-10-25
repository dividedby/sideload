import Foundation

/// Pure classification of `xcodebuild` output (design section 10).
public enum BuildClassifier {
    public struct Input: Sendable, Equatable {
        public var exitCode: Int32?
        public var stderr: String
        public var stdout: String
        public var timedOut: Bool
        public var overflow: Bool
        /// Why the process did not start (`RunResult.spawnError`); nil or empty means it started.
        public var spawnError: String?

        public init(
            exitCode: Int32? = nil, stderr: String = "", stdout: String = "", timedOut: Bool = false,
            overflow: Bool = false, spawnError: String? = nil
        ) {
            self.exitCode = exitCode
            self.stderr = stderr
            self.stdout = stdout
            self.timedOut = timedOut
            self.overflow = overflow
            self.spawnError = spawnError
        }
    }

    /// Nil when the build succeeded.
    public static func classify(_ input: Input) -> Classification? {
        if input.overflow {
            return Classification(
                status: .error, code: "OUTPUT_LIMIT",
                reason: "xcodebuild produced more output than the safety limit and was stopped.")
        }
        if input.timedOut {
            return Classification(status: .error, code: "BUILD_TIMEOUT", reason: "xcodebuild timed out.")
        }
        if let spawnError = input.spawnError, !spawnError.isEmpty {
            return Classification(status: .error, code: "BUILD_FAILED", reason: "xcodebuild could not be started.")
        }
        if input.exitCode == 0 { return nil }

        var unique: [String] = []
        for line in "\(input.stderr)\n\(input.stdout)".split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: /\berror:/) else { continue }
            let message = line[match.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = String(message.prefix(300))
            if !unique.contains(clipped) { unique.append(clipped) }
            if unique.count == 3 { break }
        }
        let reason =
            unique.isEmpty
            ? "xcodebuild failed with exit code \(input.exitCode.map { String($0) } ?? "null")."
            : "xcodebuild failed: \(unique.joined(separator: " | "))"
        return Classification(status: .error, code: "BUILD_FAILED", reason: reason)
    }
}
