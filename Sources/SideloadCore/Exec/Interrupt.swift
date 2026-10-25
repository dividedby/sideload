import Darwin
import Dispatch
import Foundation
import Synchronization

/// The single owner of stdout and of the process exit (design sections 5 and 7). The main flow and the
/// SIGINT/SIGTERM/SIGHUP handler race for both; one `Mutex<State>` decides, so exactly one object is written
/// and exactly one thread exits.
///
/// Lock rule: the mutex is held only for O(1) state transitions. Never across a write, `killAll`, a sleep or
/// a semaphore wait, and the `LiveChildren` lock is never taken while holding it.
///
/// Truncation: an object is complete only if its write finishes within `emitTimeout`. Pipe writes up to
/// PIPE_BUF (512 B) are atomic; longer ones can be cut when the reader stalls and the handler gives up.
public final class Interrupt: Sendable {
    public enum Outcome: Sendable {
        /// The object was written; exit with this code.
        case exit(Int32)
        /// Writing (or rendering) the object failed; report on stderr and exit 70.
        case writeFailed(any Error)
        /// A signal won. The handler owns stdout and the exit; the caller must park and never return.
        case yield
    }

    private enum Writer: Equatable { case main, handler }
    private enum Stdout: Equatable { case idle, writing(Writer), done }

    private struct State {
        var stdout = Stdout.idle
        var writeFailed = false
        var signal: Int32?
        var exiting = false
    }

    private let state = Mutex(State())
    /// Signalled exactly once, by whichever thread wrote.
    private let writeDone = DispatchSemaphore(value: 0)
    private let writer: Emitter.Writer
    /// False once the reader of the default stdout writer went away (EPIPE): the object was not delivered.
    private let pipeBroken: BrokenPipe

    private final class BrokenPipe: Sendable {
        private let flag = Mutex(false)
        var isSet: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }
    private let literals: [String]
    private let children: LiveChildren
    private let emitTimeout: DispatchTimeInterval

    public init(
        writer: Emitter.Writer? = nil,
        stdoutFD: Int32 = STDOUT_FILENO,
        literals: [String] = [],
        children: LiveChildren = .shared,
        emitTimeout: DispatchTimeInterval = .seconds(1)
    ) {
        let broken = BrokenPipe()
        pipeBroken = broken
        self.writer = writer ?? Output.fileDescriptorWriter(stdoutFD, onBrokenPipe: { broken.set() })
        self.literals = literals
        self.children = children
        self.emitTimeout = emitTimeout
    }

    /// True when the main flow's object was written in full to a reader: no write error, no EPIPE. Only then may a
    /// command do work that assumes the owner has seen its envelope (`Services.postEmit`).
    public var delivered: Bool { state.withLock { $0.stdout == .done && !$0.writeFailed } && !pipeBroken.isSet }

    /// Main flow: write the one result object, unless a signal got there first.
    public func finishMain(_ envelope: Envelope) -> Outcome {
        let text: String
        do {
            text = try Output.render(envelope, redacting: literals)
        } catch {
            let yielded = state.withLock { s in
                if s.signal != nil { return true }
                s.exiting = true
                return false
            }
            return yielded ? .yield : .writeFailed(error)
        }
        let go = state.withLock { s in
            if s.signal != nil { return false }
            s.stdout = .writing(.main)
            return true
        }
        guard go else { return .yield }

        var failure: (any Error)?
        do { try writer(text) } catch { failure = error }

        let yielded = state.withLock { s in
            s.stdout = .done
            s.writeFailed = failure != nil
            if s.signal != nil { return true }
            s.exiting = true
            return false
        }
        writeDone.signal()
        if yielded { return .yield }
        if let failure { return .writeFailed(failure) }
        return .exit(envelope.exitCode)
    }

    /// Signal handler: kills every live group and makes sure one object is on stdout. Returns the code to
    /// `_exit` with (128+signo), or nil when the caller must park (a signal is already being handled, or
    /// the main flow already committed to exiting). A signal after main emitted still yields 128+signo
    /// unless main already set `exiting` (a deliberate exception to "exit 0 iff ok").
    ///
    /// `kit` is set when a command already created something the owner must not be told to redo (the
    /// `export-cert` kit): the object then reports it, with `clipboardCleared` when known, instead of "re-run".
    ///
    /// `cleanup` removes files the running command must not leave behind (`inspect`'s scratch folder). It runs
    /// after the child groups are killed, bounded to 1 s, and before the object is written; it must be idempotent,
    /// because the command's own cleanup may run at the same time.
    ///
    /// `context` is what the running command reported (`InterruptReport`): it is merged into the object's data and
    /// the message says the command had already changed things (`provision --renew` moved cached profiles).
    public func handle(
        signal signo: Int32, kit: String? = nil, clipboardCleared: Bool? = nil, context: [String: JSONValue] = [:],
        cleanup: (@Sendable () -> Void)? = nil
    ) -> Int32? {
        enum Plan { case park, write, wait, none }
        let plan = state.withLock { s -> Plan in
            if s.exiting || s.signal != nil { return .park }
            s.signal = signo
            switch s.stdout {
            case .idle:
                s.stdout = .writing(.handler)
                return .write
            case .writing(.main): return .wait
            // Unreachable: .writing(.handler) is only set together with `signal`, and main sets .done and
            // `exiting` in one critical section, so both would have returned .park above.
            case .writing(.handler), .done: return .none
            }
        }
        if plan == .park { return nil }

        // Residual risk: a posix_spawn still in flight after the 500 ms spawn wait can orphan its child
        // when the process exits.
        children.killAll(SIGKILL, closing: true)
        if let cleanup { _ = Self.bounded(timeout: .seconds(1), cleanup) }

        if plan == .write {
            let name = Self.name(of: signo)
            let envelope = Self.interrupted(name: name, kit: kit, clipboardCleared: clipboardCleared, context: context)
            // Own thread: with stdout a full pipe nobody reads the write never returns, and a signal must
            // still end the process. A failed or abandoned write is not reported.
            Thread { [self] in
                if let text = try? Output.render(envelope, redacting: literals) { try? writer(text) }
                state.withLock { $0.stdout = .done }
                writeDone.signal()
            }.start()
        }
        if plan == .write || plan == .wait {
            _ = writeDone.wait(timeout: .now() + emitTimeout)
        }
        state.withLock { $0.exiting = true }
        return 128 + signo
    }

    static func interrupted(
        name: String, kit: String?, clipboardCleared: Bool?, context: [String: JSONValue] = [:]
    ) -> Envelope {
        guard let kit else {
            // Context without the renewal's keys (a run without --renew) is just data on the plain object.
            guard !context.isEmpty else {
                return Envelope.fail(
                    "sideload", code: "INTERRUPTED", message: "Interrupted by \(name).",
                    fix: "Re-run the command; nothing was left running by sideload.")
            }
            guard context["cachedProfilesMoved"] != nil else {
                return Envelope.fail(
                    "sideload", code: "INTERRUPTED", message: "Interrupted by \(name).",
                    fix: "Re-run the command; nothing was left running by sideload.", data: context)
            }
            // Worded from the counts: "moved" only when something was.
            func count(_ key: String) -> Int {
                switch context[key] {
                case .number(let n)?: Int(n)
                case .array(let items)?: items.count
                default: 0
                }
            }
            let (moved, stray) = (count("cachedProfilesMoved"), count("cachedProfilesStrayInTmp"))
            let noun = { (n: Int) in n == 1 ? "1 cached profile" : "\(n) cached profiles" }
            let message: String
            if moved > 0 {
                message = "Interrupted by \(name) after provision --renew moved \(noun(moved)) into tmp/."
            } else if stray > 0 {
                message = "Interrupted by \(name) during provision --renew, which left \(noun(stray)) in tmp/ that could not be put back."
            } else {
                message = "Interrupted by \(name) during provision --renew; no cached profiles were moved."
            }
            let fix =
                moved + stray > 0
                ? "Nothing was deleted; the profiles are listed in cachedProfilesMovedTo and cachedProfilesStrayInTmp. Re-run the command."
                : "Nothing was deleted. Re-run the command."
            return Envelope.fail("sideload", code: "INTERRUPTED", message: message, fix: fix, data: context)
        }
        let clipboard =
            switch clipboardCleared {
            case true?: "The clipboard was cleared."
            case false?: "The clipboard was left alone (it did not hold the password)."
            case nil: "The clipboard state is unknown; copy something else to be sure."
            }
        return Envelope.fail(
            "sideload", code: "INTERRUPTED",
            message: "Interrupted by \(name) after the export finished: the kit is at \(kit) and is recorded in ledger.json. \(clipboard)",
            fix: "Nothing needs repeating; the kit is complete. Use it as it is.",
            data: [
                "kit": .string(kit), "ledgerRecorded": true, "clipboardCleared": clipboardCleared.map(JSONValue.bool) ?? .null,
            ])
    }

    /// Runs `body` on a helper thread and waits up to `timeout`. Returns false if it had not finished, in
    /// which case the thread is abandoned. Used for stderr reports that must not hold the process.
    public static func bounded(timeout: DispatchTimeInterval, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            body()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// True once a signal has been recorded. For tests, to order events without sleeping.
    var signalRecorded: Bool { state.withLock { $0.signal != nil } }

    static func name(of signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(signal)"
        }
    }
}
