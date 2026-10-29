import Darwin
import Foundation

extension FetchCommand {
    /// Entries younger than this are never swept: a folder is made before its liveness lock is taken.
    static let sweepGrace: TimeInterval = 60
    static let stagedLifetime: TimeInterval = 24 * 3600
    static let stagedPrefix = "staged-"

    /// What a killed run left in `tmp/`, with no `.op.lock`. A `fetch-*` folder is live while its `live.lock` is
    /// held (the kernel drops the lock when the process dies); one whose lock can be taken, or that has none, is
    /// stale. Age is real file time against real time (`time(nil)`), never `Services.clock`, which tests fix and
    /// which would make a running download look stale. A `staged-*` file is a verified download waiting for a
    /// re-run and goes after 24 hours. `now` is injectable for the unit test.
    static func sweepStale(in tmp: String, now: time_t = time(nil)) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] {
            let isStaged = name.hasPrefix(stagedPrefix)
            guard isStaged || name.hasPrefix("fetch-") else { continue }
            let path = tmp + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let age = TimeInterval(now - st.st_mtimespec.tv_sec)
            if isStaged {
                if age > stagedLifetime { _ = ScratchDirectory.removeTree(path) }
                continue
            }
            guard age >= sweepGrace else { continue }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                _ = ScratchDirectory.removeTree(path)
                continue
            }
            switch try? FileLock.tryAcquireExisting(path: path + "/live.lock") {
            case .missing: _ = ScratchDirectory.removeTree(path)
            case .acquired(let lock):
                unlink(path + "/live.lock")
                _ = ScratchDirectory.removeTree(path)
                lock.release()
            case .held, nil: break
            }
        }
    }
}

/// A `fetch-XXXXXX` folder plus the `live.lock` flock that tells a sweep this run is alive.
struct FetchScratch {
    let directory: ScratchDirectory
    private let lock: FileLock
    var path: String { directory.path }

    static func create(under tmp: String, registry: ScratchRegistry) throws -> FetchScratch {
        let directory = try ScratchDirectory.create(under: tmp, registry: registry, prefix: "fetch")
        do {
            // Unlinked by a sweep between mkdtemp and here (or the lock file already taken): not ours to use.
            guard let lock = try FileLock.tryAcquire(path: directory.path + "/live.lock"), lock.isLinked else {
                throw SideloadError("CANCELLED", "fetch was interrupted.", fix: "Re-run the command.")
            }
            return FetchScratch(directory: directory, lock: lock)
        } catch {
            directory.remove()
            throw error
        }
    }

    /// Removes the tree, then lets go of the lock.
    func remove() {
        directory.remove()
        lock.release()
    }
}

/// The verified downloads a busy `.op.lock` left in `tmp/` for the re-run.
enum FetchStaging {
    /// A staged file is named by its digest; only 64 lower-case hex digits may name one, so callers check with `isHex` first.
    static func path(digest: String, tmp: String) -> String {
        tmp + "/" + FetchCommand.stagedPrefix + digest + ".ipa"
    }

    /// Takes the verified file an earlier run staged when the lock was busy. The rename is atomic, so a sweep or a
    /// second re-run cannot also have it (the loser gets ENOENT and downloads). The bytes are hashed again, without
    /// following a link, because the staged name is only a claim; anything that does not match is deleted.
    static func claim(asset: ResolvedAsset, into part: String, services: Services) -> (digest: String, count: Int64)? {
        guard isHex(asset.upstreamDigest, count: 64, lowercaseOnly: true) else { return nil }
        guard rename(path(digest: asset.upstreamDigest, tmp: services.home.tmp), part) == 0 else { return nil }
        if let stored = try? FileDigest.sha256(path: part), stored.hex == asset.upstreamDigest, stored.size == asset.size {
            services.log("fetch: using the verified download kept from an earlier run")
            return (stored.hex, stored.size)
        }
        _ = ScratchDirectory.removeTree(part)
        return nil
    }
}
