import Foundation

/// Reads and mutates `ledger.json`, the same way `ConfigStore` handles `config.json`: readers never lock
/// (writers rename atomically), writers hold `flock` on `.ledger.lock`.
public struct LedgerStore: Sendable {
    public let paths: Paths
    /// How long `update` waits for the ledger lock before `BUSY`.
    public let lockTimeout: Duration
    let retryInterval: Duration
    /// The final write; injectable so tests can fail it.
    let writer: @Sendable (Data, String) throws -> Void

    public init(paths: Paths, lockTimeout: Duration = .seconds(5), retryInterval: Duration = .milliseconds(25)) {
        self.init(paths: paths, lockTimeout: lockTimeout, retryInterval: retryInterval) { data, path in
            try AtomicFile.write(data, to: path)
        }
    }

    init(
        paths: Paths, lockTimeout: Duration = .seconds(5), retryInterval: Duration = .milliseconds(25),
        writer: @escaping @Sendable (Data, String) throws -> Void
    ) {
        self.paths = paths
        self.lockTimeout = lockTimeout
        self.retryInterval = retryInterval
        self.writer = writer
    }

    /// A missing file is an empty ledger. A file that does not parse is `LEDGER_INVALID`; its content is never echoed.
    public func load() throws -> Ledger {
        guard let data = try readFile(paths.ledger) else { return Ledger() }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Ledger {
        do {
            return try Self.decoder.decode(Ledger.self, from: data)
        } catch {
            throw SideloadError(
                "LEDGER_INVALID", "ledger.json is not a valid schema \(Ledger.schema) ledger.",
                fix: "Move $SIDELOAD_HOME/ledger.json aside, then run `sideload ledger refresh` to start a new one.")
        }
    }

    /// Takes an exclusive `flock` on `.ledger.lock` (bounded `LOCK_NB` retry, then `BUSY`), re-reads the ledger,
    /// applies `body` and atomically writes it. Nothing is written if `body` throws; a failed write is
    /// `LEDGER_WRITE_FAILED`. The lock is released on return and by the kernel if the process dies.
    @discardableResult
    public func update<T>(_ body: (inout Ledger) throws -> T) async throws -> T {
        try paths.ensureHome()
        let lock = try await acquireLock()
        defer { lock.release() }
        var ledger = try load()
        let result = try body(&ledger)
        do {
            try writer(try Self.encode(ledger), paths.ledger)
        } catch {
            throw SideloadError(
                "LEDGER_WRITE_FAILED", "ledger.json could not be written.",
                fix: "Check the permissions and free space of $SIDELOAD_HOME.")
        }
        return result
    }

    static func encode(_ ledger: Ledger) throws -> Data {
        try encoder.encode(ledger) + Data("\n".utf8)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func acquireLock() async throws -> FileLock {
        try await FileLock.acquire(path: paths.ledgerLock, name: "ledger", timeout: lockTimeout, retryInterval: retryInterval)
    }
}
