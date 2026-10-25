import Foundation

/// Reads and mutates `config.json` (design section 9, mechanisms 1 and 2).
public struct ConfigStore: Sendable {
    public let paths: Paths
    /// How long `update` waits for the config lock before `BUSY`.
    public let lockTimeout: Duration
    let retryInterval: Duration

    public init(paths: Paths, lockTimeout: Duration = .seconds(5), retryInterval: Duration = .milliseconds(25)) {
        self.paths = paths
        self.lockTimeout = lockTimeout
        self.retryInterval = retryInterval
    }

    /// Never locks: writers rename atomically, so a reader sees the old or the new file, never a partial one.
    /// A missing file yields the defaults.
    public func load() throws -> Config {
        guard let data = try readFile(paths.config) else { return Config() }
        return try Config.parse(data)
    }

    /// Takes an exclusive `flock` on `.config.lock` (bounded `LOCK_NB` retry, then `BUSY`), re-reads the
    /// config, applies `body`, validates and atomically writes it. Nothing is written if `body` throws.
    /// The lock is released on return and by the kernel if the process dies.
    @discardableResult
    public func update<T>(_ body: (inout Config) throws -> T) async throws -> T {
        try paths.ensureHome()
        let lock = try await acquireLock()
        defer { lock.release() }
        var config = try load()
        let result = try body(&config)
        try AtomicFile.write(try config.encoded(), to: paths.config)
        return result
    }

    private func acquireLock() async throws -> FileLock {
        try await FileLock.acquire(path: paths.configLock, name: "config", timeout: lockTimeout, retryInterval: retryInterval)
    }
}
