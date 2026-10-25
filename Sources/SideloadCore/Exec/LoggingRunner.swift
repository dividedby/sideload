/// Logs every subprocess before it runs: `exec <file> <args joined by spaces>`. The
/// sink redacts and appends to `logs/commands.log` (`ProgressLog.makeFileOnly`), so every command (doctor,
/// device, canary, ...) leaves the same trail. Arguments never carry secrets (design section 6).
public struct LoggingRunner: Runner {
    private let base: any Runner
    private let log: @Sendable (String) -> Void

    public init(_ base: any Runner, log: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.log = log
    }

    public func run(_ spec: CommandSpec) async -> RunResult {
        log("exec \(spec.executable) \(spec.args.joined(separator: " "))")
        return await base.run(spec)
    }
}
