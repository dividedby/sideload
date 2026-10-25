import Foundation

/// One subprocess invocation: an executable plus an argument array (never a shell string).
/// `executable` is an absolute path, or a bare name the runner resolves through `PATH`.
public struct CommandSpec: Sendable, Equatable {
    public static let defaultMaxOutputBytes = 32 * 1024 * 1024

    public let executable: String
    public let args: [String]
    public let timeout: Duration
    public let stdin: Data?
    public let cwd: String?
    public let maxOutputBytes: Int

    /// Traps on an empty executable, a non-positive timeout, or a non-positive output cap:
    /// a timeout is mandatory on every call, and these are programmer errors.
    public init(
        executable: String, args: [String] = [], timeout: Duration, stdin: Data? = nil, cwd: String? = nil,
        maxOutputBytes: Int = CommandSpec.defaultMaxOutputBytes
    ) {
        precondition(!executable.isEmpty, "CommandSpec: executable must be non-empty")
        precondition(timeout > .zero, "CommandSpec: a positive timeout is required")
        precondition(maxOutputBytes > 0, "CommandSpec: maxOutputBytes must be positive")
        self.executable = executable
        self.args = args
        self.timeout = timeout
        self.stdin = stdin
        self.cwd = cwd
        self.maxOutputBytes = maxOutputBytes
    }
}

/// What a run produced. A non-zero exit, a signal, a timeout and a spawn failure are all results, not throws.
public struct RunResult: Sendable, Equatable {
    /// Exit status when the child exited normally; nil when it was killed by a signal, never started, or its
    /// status is unknown (the child could not be reaped, including one still alive 5 s after the final
    /// SIGKILL, which the run leaves unreaped rather than block past its timeout).
    public var code: Int32?
    /// Terminating signal when the child was killed by one.
    public var signal: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var overflow: Bool
    /// Why the process was not started: an errno name such as "ENOENT" or "EMFILE", or "INTERRUPTED" when the
    /// interrupt handler had already closed the child registry.
    public var spawnError: String?

    public init(
        code: Int32? = 0, signal: Int32? = nil, stdout: String = "", stderr: String = "",
        timedOut: Bool = false, overflow: Bool = false, spawnError: String? = nil
    ) {
        self.code = code
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.overflow = overflow
        self.spawnError = spawnError
    }
}

public protocol Runner: Sendable {
    /// Never throws for a non-zero exit; see `RunResult`.
    func run(_ spec: CommandSpec) async -> RunResult
}
