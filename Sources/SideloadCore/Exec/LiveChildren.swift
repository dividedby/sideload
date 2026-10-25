import Darwin
import Synchronization

/// Process groups of children that are currently running. The CLI's interrupt handler kills them all.
/// A `Mutex` makes this `Sendable` without `@unchecked`.
public final class LiveChildren: Sendable {
    public static let shared = LiveChildren()

    private struct State {
        var groups: Set<pid_t> = []
        var inFlight = 0
        var closed = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Call before `posix_spawn`. Returns false once the registry is closed (an interrupt ran): do not
    /// spawn. Every true result must be paired with `endSpawn`, so the interrupt handler can wait for
    /// spawns that are mid-flight instead of exiting under them.
    public func beginSpawn() -> Bool {
        state.withLock { s in
            if s.closed { return false }
            s.inFlight += 1
            return true
        }
    }

    /// Ends a spawn started with `beginSpawn`; pass the new group, or nil when the spawn failed. If the
    /// registry closed while the spawn was in flight, the new group is killed at once.
    public func endSpawn(pgid: pid_t?) {
        let kill = state.withLock { s in
            s.inFlight -= 1
            guard let pgid else { return false }
            if s.closed { return true }
            s.groups.insert(pgid)
            return false
        }
        if kill, let pgid { _ = killpg(pgid, SIGKILL) }
    }

    public func remove(_ pgid: pid_t) {
        state.withLock { _ = $0.groups.remove(pgid) }
    }

    public var count: Int { state.withLock { $0.groups.count } }
    public var isEmpty: Bool { count == 0 }

    /// Sends `signal` to every registered group. Groups that are already gone are ignored. With `closing`
    /// (the interrupt handler, which is about to exit), new spawns are refused, and this waits up to
    /// `spawnWait` for spawns already in flight to finish, since `endSpawn` kills their groups.
    public func killAll(_ signal: Int32, closing: Bool = false, spawnWait: Duration = .milliseconds(500)) {
        let snapshot = state.withLock { s in
            if closing { s.closed = true }
            return Array(s.groups)
        }
        for pgid in snapshot {
            _ = killpg(pgid, signal)
        }
        guard closing else { return }
        let deadline = ContinuousClock.now + spawnWait
        while state.withLock({ $0.inFlight }) > 0 && ContinuousClock.now < deadline {
            usleep(2000)
        }
    }
}
