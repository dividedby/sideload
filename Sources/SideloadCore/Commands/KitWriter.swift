import Darwin
import Foundation

/// Writes a Feather kit: a folder built under a hidden temporary name beside its destination, then moved into
/// place with `renamex_np(RENAME_EXCL)`, so the destination is either complete or absent and an existing
/// folder is never replaced (the same approach as the canary evidence bundle).
enum KitWriter {
    struct File {
        var name: String
        var data: Data
        var mode: mode_t
    }

    /// The hidden temporary folder name beside `destination`, chosen before anything is created so a caller can
    /// register it for cleanup first.
    static func stagingPath(beside destination: String) -> String {
        let leaf = destination.split(separator: "/").last.map(String.init) ?? "kit"
        return "\(parentPath(destination))/.\(leaf).\(getpid()).\(randomHex(bytes: 4)).tmp"
    }

    /// Creates `tmp` (from `stagingPath`, 0700) and fills it with `files`; `onFile` runs after each file is written.
    /// The parent is created 0700 if missing. The folder is removed again if anything fails.
    static func stage(_ files: [File], at tmp: String, onFile: (String) -> Void = { _ in }) throws {
        try makeDirectories(parentPath(tmp), mode: 0o700)
        if mkdir(tmp, 0o700) != 0 { throw ioError("mkdir") }
        do {
            if chmod(tmp, 0o700) != 0 { throw ioError("chmod") }
            for file in files {
                try AtomicFile.write(file.data, to: tmp + "/" + file.name, mode: file.mode)
                onFile(file.name)
            }
        } catch {
            discard(staged: tmp)
            throw error
        }
    }

    /// `RENAME_EXCL` fails with EEXIST instead of replacing a folder that is already there. The staged folder is
    /// removed on failure.
    static func commit(staged tmp: String, to destination: String) throws {
        if renamex_np(tmp, destination, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            discard(staged: tmp)
            throw ioError("rename", code)
        }
    }

    static func discard(staged tmp: String) {
        try? FileManager.default.removeItem(atPath: tmp)
    }
}
