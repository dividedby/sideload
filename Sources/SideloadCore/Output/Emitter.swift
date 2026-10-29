import Darwin
import Foundation
import Synchronization

public enum Output {
    /// Redacts the envelope, then encodes it as one JSON object plus a trailing newline.
    /// Keys are sorted and `/` is not escaped (deterministic output).
    public static func render(_ envelope: Envelope, redacting literals: [String] = []) throws -> String {
        let redacted = Redactor(literals: literals, keepsUserPaths: envelope.keepsUserPaths).redact(envelope.json)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(redacted), as: UTF8.self) + "\n"
    }

    /// Writes all of `text` to a file descriptor. EPIPE (reader closed early, e.g. `| head`) is
    /// not a failure of the command; any other error is thrown. The process must ignore SIGPIPE.
    /// `onBrokenPipe` is told when the text did not reach a reader, for a caller that must know it was not delivered.
    public static func fileDescriptorWriter(
        _ fd: Int32, onBrokenPipe: @escaping @Sendable () -> Void = {}
    ) -> Emitter.Writer {
        { text in
            var bytes = Array(text.utf8)[...]
            while !bytes.isEmpty {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n >= 0 {
                    bytes = bytes.dropFirst(n)
                } else if errno == EINTR {
                    continue
                } else if errno == EPIPE {
                    onBrokenPipe()
                    return
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}

/// Writes the single result object for an invocation. A second `emit` is a programmer error.
public final class Emitter: Sendable {
    public typealias Writer = @Sendable (String) throws -> Void

    private let literals: [String]
    private let write: Writer
    private let didEmit = Mutex(false)

    public init(redacting literals: [String] = [], write: @escaping Writer = Output.fileDescriptorWriter(STDOUT_FILENO)) {
        self.literals = literals
        self.write = write
    }

    public var emitted: Bool { didEmit.withLock { $0 } }

    /// Returns the process exit code: 0 iff `ok`.
    @discardableResult
    public func emit(_ envelope: Envelope) throws -> Int32 {
        precondition(claim(), "output already emitted for this invocation")
        try write(try Output.render(envelope, redacting: literals))
        return envelope.exitCode
    }

    private func claim() -> Bool {
        didEmit.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
