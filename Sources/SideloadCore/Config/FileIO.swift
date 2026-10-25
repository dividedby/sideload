import Darwin
import Foundation
import Synchronization

/// Maps an errno to the error every filesystem failure in Config/ surfaces. Paths stay out of the message.
func ioError(_ operation: String, _ code: Int32 = errno) -> SideloadError {
    SideloadError(
        "IO_ERROR", "\(operation) failed: \(String(cString: strerror(code))).",
        fix: "Check the permissions and free space of $SIDELOAD_HOME.")
}

func randomHex(bytes: Int) -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
}

/// lstat-based existence: a dangling symlink exists. Only ENOENT means absent.
func pathExists(_ path: String) throws -> Bool {
    var st = stat()
    if lstat(path, &st) == 0 { return true }
    if errno == ENOENT { return false }
    throw ioError("stat")
}

/// Normalises a path: absolute, no `.`/`..`/empty components, no trailing slash.
func resolvePath(_ path: String) -> String {
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    var parts: [Substring] = []
    for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." { _ = parts.popLast(); continue }
        parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
}

func parentPath(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
}

/// `mkdir -p` where every directory it creates gets `mode` (before the umask).
func makeDirectories(_ path: String, mode: mode_t) throws {
    var current = ""
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        current += "/" + part
        if mkdir(current, mode) != 0 && errno != EEXIST { throw ioError("mkdir") }
    }
}

/// Whole-file read. Nil when the file does not exist.
func readFile(_ path: String) throws -> Data? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    if fd < 0 {
        if errno == ENOENT { return nil }
        throw ioError("open")
    }
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 {
            if errno == EINTR { continue }
            throw ioError("read")
        }
        if n == 0 { return data }
        data.append(buffer, count: n)
    }
}

/// Design section 9, mechanism 1: `<file>.<pid>.<rand>.tmp` (`O_EXCL`, 0600), write, fsync, rename.
/// Readers never lock and never see a partial file. The temp file is removed on any failure.
enum AtomicFile {
    /// `rename` is injectable so tests can fail the last step.
    static func write(
        _ data: Data, to path: String, mode: mode_t = 0o600,
        rename renamer: (String, String) -> Int32 = { Darwin.rename($0, $1) }
    ) throws {
        let tmp = "\(path).\(getpid()).\(randomHex(bytes: 4)).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        if fd < 0 { throw ioError("create temp file") }
        var committed = false
        defer { if !committed { unlink(tmp) } }
        do {
            try writeAll(fd, data)
            // The open mode is masked by the umask; the file must be exactly `mode`.
            if fchmod(fd, mode) != 0 { throw ioError("chmod") }
            if fsync(fd) != 0 { throw ioError("fsync") }
        } catch {
            close(fd)
            throw error
        }
        if close(fd) != 0 { throw ioError("close") }
        if renamer(tmp, path) != 0 { throw ioError("rename") }
        committed = true
        // Make the rename itself durable. Best effort: the data is already in place.
        let dir = open(parentPath(path), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dir >= 0 {
            _ = fsync(dir)
            close(dir)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ioError("write")
                }
                offset += n
            }
        }
    }
}

/// Design section 9, mechanism 4: append-only logs. One `write(2)` on an `O_APPEND` descriptor per line, so
/// concurrent writers never interleave a line (lines stay under the pipe-atomic size). The mode applies only
/// when the file is created.
enum AppendFile {
    static func appendLine(_ line: String, to path: String, mode: mode_t = 0o600) throws {
        let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode)
        if fd < 0 { throw ioError("open log") }
        defer { close(fd) }
        var written: Int
        repeat { written = Darwin.write(fd, bytes, bytes.count) } while written < 0 && errno == EINTR
        if written != bytes.count { throw ioError("write log", written < 0 ? errno : EIO) }
    }
}

/// An exclusive `flock` on a lock file. The kernel drops it when the descriptor closes, including when the
/// process dies. The descriptor is `O_CLOEXEC`, so spawned children (xcodebuild helpers) never inherit it.
final class FileLock: Sendable {
    private let fd: Mutex<Int32>

    private init(fd: Int32) {
        self.fd = Mutex(fd)
    }

    /// Non-blocking. Nil means another holder (this process or another) has the lock.
    static func tryAcquire(path: String) throws -> FileLock? {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 { throw ioError("open lock file") }
        // O_CREAT only applies a mode to a new file; a lock file that already exists keeps its own.
        if fchmod(fd, 0o600) != 0 {
            let code = errno
            close(fd)
            throw ioError("chmod lock file", code)
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw ioError("lock", code)
        }
        return FileLock(fd: fd)
    }

    /// Retries `tryAcquire` every `retryInterval` until `timeout`, then `BUSY`. `name` is the state file the lock
    /// guards (`config`, `ledger`), used in the messages. Cancellation while waiting is `CANCELLED`.
    static func acquire(
        path: String, name: String, timeout: Duration, retryInterval: Duration
    ) async throws -> FileLock {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let lock = try tryAcquire(path: path) { return lock }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw SideloadError(
                    "BUSY", "Another sideload process is updating \(name).json.", fix: "Wait a few seconds and retry.")
            }
            do {
                try await Task.sleep(for: min(retryInterval, remaining))
            } catch {
                throw SideloadError(
                    "CANCELLED", "Cancelled while waiting for the \(name) lock.", fix: "Retry the command.")
            }
        }
    }

    /// Idempotent.
    func release() {
        let held = fd.withLock { value in
            defer { value = -1 }
            return value
        }
        if held >= 0 {
            flock(held, LOCK_UN)
            close(held)
        }
    }

    deinit { release() }
}
