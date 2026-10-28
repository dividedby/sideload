import Testing
import Darwin
import Foundation
import Synchronization

@testable import SideloadCore

/// Fixture scripts are located through `#filePath`; there is no resource bundle.
func fixture(_ name: String, file: String = #filePath) -> String {
    URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sideload-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `pwd -P` reports /private/var/...; Foundation's URL resolution strips that prefix.
func realPath(_ path: String) -> String {
    realpath(path, nil).map { String(cString: $0) } ?? path
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Polls `condition` until it holds or `timeout` passes. Returns the final value of the condition.
@discardableResult
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The first time something happened. Runner timing tests mark it from the runner's own thread (spawn, signals) and
/// compare those marks, not the test's clock around `await run`: on a loaded machine resuming the test task can take
/// seconds, and that delay is the scheduler's, not the runner's.
final class Moment: Sendable {
    private let instant = Mutex<ContinuousClock.Instant?>(nil)

    var at: ContinuousClock.Instant? { instant.withLock { $0 } }

    func mark() {
        instant.withLock { $0 = $0 ?? .now }
    }
}

/// How late the runner's own thread may act under load, past the time its timeout or grace period sets. The lower bounds
/// (at least the timeout, at least the grace period) check the deadlines; this upper bound rules out a hang, and is far
/// below the 20 s and 60 s timeouts the overflow and cancellation tests must beat.
let runnerSlack: Duration = .seconds(5)

/// Records the signals a runner sends to child groups, and when, while still delivering them.
final class SignalLog: Sendable {
    private let entries = Mutex<[(pgid: pid_t, signal: Int32, at: ContinuousClock.Instant)]>([])

    var signals: [Int32] { entries.withLock { $0.map(\.signal) } }
    var groups: Set<pid_t> { entries.withLock { Set($0.map(\.pgid)) } }

    /// When `signal` was first sent, stamped on the runner's thread just before it is delivered.
    func sent(_ signal: Int32) -> ContinuousClock.Instant? {
        entries.withLock { $0.first { $0.signal == signal }?.at }
    }

    var send: @Sendable (pid_t, Int32) -> Int32 {
        { [self] pgid, sig in
            entries.withLock { $0.append((pgid, sig, .now)) }
            return killpg(pgid, sig)
        }
    }
}

/// A runner wired to its own registry and signal log, with a short grace period. `spawned` is marked right after
/// `posix_spawn` returns.
struct Harness {
    let children = LiveChildren()
    let log = SignalLog()
    let spawned = Moment()
    let runner: PosixSpawnRunner

    init(grace: Duration = .milliseconds(300), afterSpawn: @escaping @Sendable () -> Void = {}) {
        let spawned = spawned
        runner = PosixSpawnRunner(
            children: children, grace: grace, signalGroup: log.send,
            afterSpawn: {
                spawned.mark()
                afterSpawn()
            })
    }

    /// Runs `spec` and checks the registry is empty afterwards.
    func run(_ spec: CommandSpec, sourceLocation: SourceLocation = #_sourceLocation) async -> RunResult {
        let result = await runner.run(spec)
        #expect(children.isEmpty, "LiveChildren must be empty after a run", sourceLocation: sourceLocation)
        return result
    }
}
