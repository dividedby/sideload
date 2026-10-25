import Synchronization

/// Bounded buffering between a download's delegate queue (which receives bytes as fast as the server sends them)
/// and the consumer (which hashes and writes them). It does two things, both under one lock so a decision and the
/// event it concerns can never be reordered:
///
/// - **Cap.** The delegate adds every received block to `total`; the first block that takes it past `maxBytes` is
///   refused and the transfer is cancelled right there, whatever the consumer is doing.
/// - **Backpressure.** `pending` is the bytes handed to the consumer and not yet finished with. Above `high` the
///   task is suspended (the socket stops being read); once the consumer has drained to `low` or less it is
///   resumed. `suspended` is only changed with `suspend`/`resume` in the same critical section, so each suspend
///   has exactly one matching resume and a wakeup cannot be lost. After `close()` nothing is resumed or
///   suspended again (the consumer has gone; the task is being cancelled, which works on a suspended task).
///
/// Memory is therefore bounded by about `high` plus whatever the system had already read when `suspend` took
/// effect, instead of the size of the file.
final class DownloadFlow: Sendable {
    enum Received: Sendable, Equatable {
        case accepted
        /// The cap was passed (now or earlier); the task has been cancelled and the block was not queued.
        case exceeded
    }

    struct Controls: Sendable {
        var suspend: @Sendable () -> Void
        var resume: @Sendable () -> Void
        var cancel: @Sendable () -> Void
    }

    private struct State {
        var controls: Controls?
        var total: Int64 = 0
        var pending = 0
        var maxPending = 0
        var suspended = false
        var closed = false
        var exceeded = false
    }

    let maxBytes: Int64
    let high: Int
    let low: Int
    private let state = Mutex(State())

    init(maxBytes: Int64, high: Int = 4 << 20, low: Int = 1 << 20) {
        precondition(low < high)
        self.maxBytes = maxBytes
        self.high = high
        self.low = low
    }

    func attach(_ controls: Controls) {
        state.withLock { $0.controls = controls }
    }

    var maxPending: Int { state.withLock { $0.maxPending } }
    var isSuspended: Bool { state.withLock { $0.suspended } }

    /// Called on the delegate queue for each block. `enqueue` hands the block to the consumer; it runs under the
    /// lock and must not block (an `AsyncStream` yield is fine).
    func received(_ count: Int, enqueue: () -> Void) -> Received {
        var cancel: (@Sendable () -> Void)?
        let outcome = state.withLock { s -> Received in
            if s.exceeded { return .exceeded }
            if s.closed { return .accepted }
            s.total += Int64(count)
            if s.total > maxBytes {
                s.exceeded = true
                cancel = s.controls?.cancel
                return .exceeded
            }
            s.pending += count
            s.maxPending = max(s.maxPending, s.pending)
            enqueue()
            if s.pending > high, !s.suspended {
                s.suspended = true
                // Under the lock on purpose: the flag and the call must change together, or a concurrent
                // `consumed` could resume before this suspend lands and leave the task suspended for good.
                s.controls?.suspend()
            }
            return .accepted
        }
        cancel?()
        return outcome
    }

    /// Called by the consumer when it has finished with a block of `count` bytes.
    func consumed(_ count: Int) {
        state.withLock { s in
            s.pending -= count
            if s.suspended, !s.closed, s.pending <= low {
                s.suspended = false
                // Under the lock for the same reason as `suspend` above: resume is ordered after its suspend.
                s.controls?.resume()
            }
        }
    }

    /// The consumer is done (finished, failed or cancelled). Idempotent.
    func close() {
        state.withLock { $0.closed = true }
    }
}
