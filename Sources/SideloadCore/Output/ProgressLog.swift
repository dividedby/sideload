import Darwin
import Foundation

/// Progress goes to stderr and to `logs/commands.log`, always redacted (design section 7). Logging never breaks a command.
public enum ProgressLog {
    public static func make(
        home: Paths, clock: any WallClock, stderrFD: Int32 = STDERR_FILENO
    ) -> @Sendable (String) -> Void {
        let writeStderr = Output.fileDescriptorWriter(stderrFD)
        let toFile = makeFileOnly(home: home, clock: clock)
        return { message in
            try? writeStderr(Redactor.redactPatterns(message) + "\n")
            toFile(message)
        }
    }

    /// The redacted line goes to `logs/commands.log` only.
    public static func makeFileOnly(home: Paths, clock: any WallClock) -> @Sendable (String) -> Void {
        { message in
            try? AppendFile.appendLine(
                "\(isoTimestamp(clock.now())) \(Redactor.redactPatterns(message))", to: home.commandsLog)
        }
    }

    /// `2026-10-19T12:00:00.000Z`, as JavaScript's `Date#toISOString`.
    public static func isoTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
