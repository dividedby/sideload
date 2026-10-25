import Darwin
import Foundation

/// What the extracted tree holds, counted while it was checked.
struct TreeFacts: Equatable {
    var entries = 0
    var bytes: UInt64 = 0
    var dylibs = 0
}

/// Checks and measures the tree `ditto` wrote. Nothing here follows a symlink: every step is `lstat`.
enum ExtractedTree {
    /// Names inside `path`, sorted. Makes a directory the process owns readable first: an archive can carry mode 000.
    static func children(of path: String) -> [String]? {
        _ = chmod(path, 0o700)
        return names(in: path)?.sorted()
    }

    private static func names(in path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Refuses a symlink, a device, FIFO or socket, a hard-linked file, anything on another volume than `root`, a
    /// tree deeper than `limits.maxTreeDepth`, and one with more entries or bytes than the limits allow
    /// (`IPA_UNSAFE_TREE`, `IPA_TOO_MANY_ENTRIES`, `IPA_TOO_LARGE`).
    static func verify(root: String, limits: InspectLimits) throws -> TreeFacts {
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw unsafe("The extraction folder is not a plain directory.") }
        var facts = TreeFacts()
        var pending: [(path: String, depth: Int)] = [(root, 0)]
        while let (dirPath, depth) = pending.popLast() {
            guard depth < limits.maxTreeDepth else { throw unsafe("The extracted tree is nested too deeply.") }
            guard let names = children(of: dirPath) else { throw unsafe("A folder in the extracted tree could not be read.") }
            for name in names {
                let path = dirPath + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { throw unsafe("An extracted entry could not be examined.") }
                if st.st_dev != rootInfo.st_dev { throw unsafe("The extracted tree crosses a volume boundary.") }
                facts.entries += 1
                if facts.entries > limits.maxEntries * 2 {
                    throw SideloadError(
                        "IPA_TOO_MANY_ENTRIES", "The extracted tree has more entries than the limit.",
                        fix: "Inspect a normal IPA.")
                }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    pending.append((path, depth + 1))
                case S_IFREG:
                    if st.st_nlink > 1 { throw unsafe("The extracted tree contains a hard-linked file.") }
                    facts.bytes += UInt64(max(st.st_size, 0))
                    if facts.bytes > limits.maxTotalBytes { throw tooLarge() }
                    if name.hasSuffix(".dylib") { facts.dylibs += 1 }
                case S_IFLNK:
                    throw unsafe("The extracted tree contains a symbolic link.")
                default:
                    throw unsafe("The extracted tree contains a device, FIFO or socket.")
                }
            }
        }
        return facts
    }

    /// Bytes of regular files under `root`, counting stops once `cap` is passed or `maxEntries` entries were seen.
    /// Tolerant of anything odd (the strict pass runs afterwards); used to watch an extraction in progress.
    static func measure(root: String, cap: UInt64, maxEntries: Int) -> UInt64 {
        var bytes: UInt64 = 0
        var seen = 0
        var pending = [root]
        while let dirPath = pending.popLast() {
            guard let names = names(in: dirPath) else { continue }
            for name in names {
                var st = stat()
                guard lstat(dirPath + "/" + name, &st) == 0 else { continue }
                seen += 1
                if seen > maxEntries { return bytes }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: pending.append(dirPath + "/" + name)
                case S_IFREG:
                    bytes += UInt64(max(st.st_size, 0))
                    if bytes > cap { return bytes }
                default: break
                }
            }
        }
        return bytes
    }

    private static func unsafe(_ message: String) -> SideloadError {
        SideloadError("IPA_UNSAFE_TREE", message, fix: "Do not use this IPA; it is not a normal app archive.")
    }

    private static func tooLarge() -> SideloadError {
        SideloadError("IPA_TOO_LARGE", "The extracted data is larger than the limit.", fix: "Inspect a normal IPA.")
    }
}
