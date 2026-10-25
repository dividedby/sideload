/// Design section 9, mechanism 3: `canary`, `sign`, `install`, `export-cert` and `fetch` hold a non-blocking
/// exclusive `flock` on `.op.lock` for their whole run. A second concurrent run gets `OPERATION_IN_PROGRESS`
/// instead of racing portal state or derived data. Released by `release()`, on deinit, and by the kernel
/// if the process dies.
public final class OperationLock: Sendable {
    private let lock: FileLock

    private init(lock: FileLock) {
        self.lock = lock
    }

    public static func acquire(paths: Paths) throws -> OperationLock {
        try paths.ensureHome()
        guard let lock = try FileLock.tryAcquire(path: paths.opLock) else {
            throw SideloadError(
                "OPERATION_IN_PROGRESS", "Another sideload operation is already running.",
                fix: "Wait for it to finish, then retry.")
        }
        return OperationLock(lock: lock)
    }

    /// Idempotent.
    public func release() {
        lock.release()
    }
}
