import Synchronization

@testable import SideloadCore

/// Records every `CommandSpec` and replays scripted results (design section 13). Later modules
/// (`DeviceCtl`, checks, commands) use it instead of spawning real processes.
final class FakeRunner: Runner {
    typealias Script = @Sendable (CommandSpec) -> RunResult

    private let script: Script
    private let recorded = Mutex<[CommandSpec]>([])

    init(_ script: @escaping Script = { _ in RunResult() }) {
        self.script = script
    }

    /// Replays `results` in order; once exhausted, repeats the last one.
    convenience init(results: [RunResult]) {
        let next = Mutex(0)
        self.init { _ in
            let i = next.withLock { n in
                defer { n += 1 }
                return n
            }
            return results.isEmpty ? RunResult() : results[min(i, results.count - 1)]
        }
    }

    var calls: [CommandSpec] { recorded.withLock { $0 } }

    func run(_ spec: CommandSpec) async -> RunResult {
        recorded.withLock { $0.append(spec) }
        return script(spec)
    }
}
