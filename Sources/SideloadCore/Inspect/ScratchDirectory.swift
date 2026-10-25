import Darwin
import Foundation
import Synchronization

/// The scratch directories that exist right now, so the CLI's interrupt handler can remove them before the process
/// exits (a signal ends the process without running the command's own cleanup). Once `removeAllAndClose` has run,
/// nothing new can be registered.
public final class ScratchRegistry: Sendable {
    public static let shared = ScratchRegistry()

    private struct State {
        var paths: Set<String> = []
        var closed = false
    }

    private let state = Mutex(State())

    public init() {}

    public var isEmpty: Bool { state.withLock { $0.paths.isEmpty } }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Package-visible only so the CLI's debug test hook can exercise the interrupt path; commands go through
    /// `ScratchDirectory`.
    package func register(_ path: String) -> Bool {
        state.withLock { s in
            if s.closed { return false }
            s.paths.insert(path)
            return true
        }
    }

    func unregister(_ path: String) {
        state.withLock { _ = $0.paths.remove(path) }
    }

    /// Removes every registered directory and refuses new ones. Safe to call more than once, and while the owning
    /// command is still running: its own removal then finds nothing to do.
    public func removeAllAndClose() {
        let paths = state.withLock { s in
            s.closed = true
            defer { s.paths = [] }
            return Array(s.paths)
        }
        for path in paths { _ = ScratchDirectory.removeTree(path) }
    }
}

/// A 0700 directory made with `mkdtemp` under `$SIDELOAD_HOME/tmp`, removed again by `remove()` on every path.
struct ScratchDirectory {
    let path: String
    private let registry: ScratchRegistry

    /// `CANCELLED` when an interrupt already closed the registry. `prefix` names the folder (`inspect-XXXXXX`,
    /// or `fetch-XXXXXX` for a download in flight).
    static func create(under tmp: String, registry: ScratchRegistry, prefix: String = "inspect") throws -> ScratchDirectory {
        try makeDirectories(tmp, mode: 0o700)
        var template = Array((tmp + "/\(prefix)-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw ioError("mkdtemp") }
        let path = String(decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard registry.register(path) else {
            _ = removeTree(path)
            throw SideloadError("CANCELLED", "\(prefix) was interrupted before it started.", fix: "Re-run the command.")
        }
        return ScratchDirectory(path: path, registry: registry)
    }

    /// Idempotent. Returns false when something is left behind.
    @discardableResult
    func remove() -> Bool {
        let removed = Self.removeTree(path)
        registry.unregister(path)
        return removed
    }

    /// `rm -rf` that never follows a symlink and first makes a directory it owns readable and writable, since an
    /// extracted archive can carry directories with mode 000. Depth is bounded so a hostile tree cannot overflow
    /// the stack. Returns true when `path` no longer exists.
    static func removeTree(_ path: String) -> Bool {
        removeTree(path, depth: 0)
        var st = stat()
        return lstat(path, &st) != 0 && errno == ENOENT
    }

    private static func removeTree(_ path: String, depth: Int) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_mode & S_IFMT != S_IFDIR {
            _ = lchflags(path, 0)
            _ = unlink(path)
            return
        }
        _ = chflags(path, 0)
        if depth < 200, let children = ExtractedTree.children(of: path) {
            for name in children { removeTree(path + "/" + name, depth: depth + 1) }
        }
        _ = rmdir(path)
    }
}
