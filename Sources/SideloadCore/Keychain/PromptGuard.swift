import Dispatch
import Foundation
import Synchronization

/// Runs a call that may block on a keychain access dialog (a private-key export). The Security call cannot be
/// cancelled and blocks until the owner answers, so it runs on its own thread and the caller stops waiting
/// after `timeout`. The thread is left to finish or die with the process.
public enum PromptGuard {
    public static let defaultTimeout = Duration.seconds(120)

    public static func run<T: Sendable>(
        timeout: Duration = defaultTimeout, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            @Sendable func finish(_ result: Result<T, any Error>) {
                if gate.claim() { continuation.resume(with: result) }
            }
            let thread = Thread { finish(Result { try body() }) }
            thread.name = "sideload.prompt-guard"
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds(timeout)) {
                finish(.failure(KeychainFailure.promptTimeout))
            }
        }
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Lets exactly one of the call and the timer resume the continuation.
    private final class Gate: Sendable {
        private let taken = Mutex(false)

        func claim() -> Bool {
            taken.withLock { taken in
                if taken { return false }
                taken = true
                return true
            }
        }
    }
}
