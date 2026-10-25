import Synchronization

/// The signal protocol of `export-cert` (design section 16, "Clipboard exposure"). One `Mutex` holds the phase of
/// the export; the main flow moves it forward, and the CLI's signal handler (`trip()`) makes exactly one
/// transition of its own: `idle` to `dead`. The handler never touches a file; the main flow alone cleans up.
///
///     idle -> writing -> committing -> committed(kit) -> copying(kit) -> holding(kit) -> done(kit)
///       \-> dead                                              (finish() ends any phase in done)
///
/// - `idle`: nothing written. A signal marks the export `dead`; `beginWriting()` then refuses to start, and the
///   signal takes the usual `INTERRUPTED` path.
/// - `writing` (from `beginWriting`) and `committing` (from `beginCommit`, the ledger write and kit move): every
///   signal is absorbed. A signal before `beginCommit` makes it return false, so the main flow removes the
///   `.p12`, its temporary files and the staging folder and reports the interruption; after it the move finishes
///   or rolls back. From the second absorbed signal on, `onImpatient` runs once (the CLI prints a stderr line).
/// - `committed` (the kit is in place) and `holding` (the password is on the clipboard for up to 90 s): the first
///   signal is absorbed (it skips or ends the hold; the main flow clears the clipboard and prints the normal
///   result); a later one is not absorbed and its `INTERRUPTED` object reports the kit. The handler clears the
///   clipboard only in these phases, when the copy has finished, so its clear can never run before the copy; it
///   waits for main's clear if one is in flight, for at most 500 ms.
/// - `copying` (between `beginCopy` and `copyFinished`): like `writing`, every signal is absorbed; the main flow
///   clears the clipboard once the copy is done, so no exit can precede the copy. Residual risk: an exit while that
///   clear is still running (an AppKit call slower than the handler's 500 ms bound) leaves the clipboard state
///   unknown; the `INTERRUPTED` object then says so.
/// - `done` (from `finish()`) and `dead`: nothing is absorbed. `done(kit)` makes `INTERRUPTED` report the kit
///   instead of telling the owner to run again.
public final class HoldSignal: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle, writing, committing
        case committed(String)
        case copying(String)
        case holding(String)
        case done(String?)
        case dead
    }

    public enum Disposition: Sendable, Equatable {
        case absorbed
        /// The caller takes the `INTERRUPTED` path; `kit` is where the finished kit is, if one exists.
        case notAbsorbed(kit: String?)
    }

    private struct State {
        var phase = Phase.idle
        /// Signals absorbed so far.
        var absorbed = 0
    }

    private let state = Mutex(State())
    private let events: AsyncStream<Void>
    private let trigger: AsyncStream<Void>.Continuation
    private let onImpatient: @Sendable () -> Void

    /// `onImpatient` runs (on the handler's queue, once) at the second absorbed signal while writing,
    /// committing or copying; the CLI prints "finishing cleanup; kill -9 to force" to stderr, bounded.
    public init(onImpatient: @escaping @Sendable () -> Void = {}) {
        (events, trigger) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.onImpatient = onImpatient
    }

    // MARK: main flow

    /// `idle` to `writing`. Throws `INTERRUPTED` (no kit exists) if a signal already marked the export dead.
    public func beginWriting() throws {
        let allowed = state.withLock { s -> Bool in
            switch s.phase {
            case .idle:
                s.phase = .writing
                return true
            case .dead: return false
            // Calling it twice is a bug, not a signal; keep going from wherever the flow is.
            default: return true
            }
        }
        if !allowed {
            throw SideloadError(
                "INTERRUPTED", "Interrupted before anything was written.",
                fix: "Nothing was written. Re-run the export.")
        }
    }

    /// `writing` to `committing`, unless a signal arrived since `beginWriting`: then false and the caller rolls
    /// back what it wrote.
    public func beginCommit() -> Bool {
        state.withLock { s in
            guard s.phase == .writing, s.absorbed == 0 else { return false }
            s.phase = .committing
            return true
        }
    }

    /// `committing` to `committed`, unconditionally: the kit is in place and recorded.
    public func markCommitted(kit: String) {
        state.withLock { s in
            if s.phase == .committing { s.phase = .committed(kit) }
        }
    }

    /// `committed` to `copying`, unless a signal arrived before: then false, and the caller skips the copy and
    /// the hold.
    public func beginCopy() -> Bool {
        state.withLock { s in
            guard case .committed(let kit) = s.phase, s.absorbed == 0 else { return false }
            s.phase = .copying(kit)
            return true
        }
    }

    /// `copying` to `holding` (also after a failed copy). Signals absorbed while copying end the hold at once.
    public func copyFinished() {
        let wake = state.withLock { s -> Bool in
            guard case .copying(let kit) = s.phase else { return false }
            s.phase = .holding(kit)
            return s.absorbed > 0
        }
        if wake { trigger.yield() }
    }

    /// True once any signal has been absorbed.
    public var interrupted: Bool { state.withLock { $0.absorbed > 0 } }

    /// Returns once a signal is absorbed while holding (one that arrived between `copyFinished` and here is
    /// remembered); throws `CancellationError` if the task is cancelled first.
    public func wait() async throws {
        for await _ in events { return }
        throw CancellationError()
    }

    /// Ends the export in `done`, keeping the kit if there is one. Idempotent; called from a `defer`.
    public func finish() {
        state.withLock { s in
            switch s.phase {
            case .committed(let kit), .copying(let kit), .holding(let kit): s.phase = .done(kit)
            case .done, .dead: break
            default: s.phase = .done(nil)
            }
        }
    }

    public var phase: Phase { state.withLock { $0.phase } }

    // MARK: signal handler

    /// The handler's only entry point. Its one state change is `idle` to `dead`.
    public func trip() -> Disposition {
        enum Action { case none, wake, impatient }
        let (disposition, action) = state.withLock { s -> (Disposition, Action) in
            switch s.phase {
            case .idle:
                s.phase = .dead
                return (.notAbsorbed(kit: nil), .none)
            case .dead: return (.notAbsorbed(kit: nil), .none)
            case .done(let kit): return (.notAbsorbed(kit: kit), .none)
            case .writing, .committing, .copying:
                s.absorbed += 1
                return (.absorbed, s.absorbed == 2 ? .impatient : .none)
            case .committed(let kit):
                guard s.absorbed == 0 else { return (.notAbsorbed(kit: kit), .none) }
                s.absorbed += 1
                return (.absorbed, .none)
            case .holding(let kit):
                guard s.absorbed == 0 else { return (.notAbsorbed(kit: kit), .none) }
                s.absorbed += 1
                return (.absorbed, .wake)
            }
        }
        switch action {
        case .wake: trigger.yield()
        case .impatient: onImpatient()
        case .none: break
        }
        return disposition
    }
}
