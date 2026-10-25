import Synchronization

/// Work a command wants done only after its one stdout object was fully written (`provision` removing the ledger
/// entries of the moves its envelope reported). A kill, a closed pipe or a failed write skips it, and the next run
/// reports what was left. Inert until a command calls `add`; the CLI wires one shared instance into `Services` and
/// runs it from `main.swift` once the write succeeded. Tests call `runIfPending()` to play a successful emit, or
/// leave it to play a failed one.
public final class PostEmit: Sendable {
    public typealias Action = @Sendable () async -> Void

    private let action = Mutex<Action?>(nil)

    public init() {}

    /// Registers the work after whatever is already registered, so a command that makes several registrations (`refresh`
    /// runs `provision --renew` for more than one app) keeps all of them. They run in the order added.
    public func add(_ action: @escaping Action) {
        self.action.withLock { current in
            guard let earlier = current else {
                current = action
                return
            }
            current = {
                await earlier()
                await action()
            }
        }
    }

    public var isPending: Bool { action.withLock { $0 != nil } }

    /// Runs the registered work once, if any.
    public func runIfPending() async {
        let taken = action.withLock { current -> Action? in
            defer { current = nil }
            return current
        }
        await taken?()
    }
}
