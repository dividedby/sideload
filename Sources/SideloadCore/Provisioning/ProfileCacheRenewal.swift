import Darwin
import Foundation
import Synchronization

/// `provision --renew` (design section 18, spike S3): Xcode may reuse a cached valid profile instead of making a
/// fresh one, which would leave a refresh with the same expiry. This moves sideload's own cached profile out of
/// Xcode's folders into `$SIDELOAD_HOME/tmp/` before the build so Xcode has to make a new one.
///
/// "Sideload's own" is narrow on purpose. A file is moved only when it is a regular file (opened with
/// `O_NOFOLLOW`, so never a symlink), within a size cap, and the bytes read from that open descriptor (the same
/// bytes `security cms -D` decodes, piped on stdin) are a free-team profile (`TeamIdentifier` is the free team)
/// with the exact `application-identifier` `6ZU5Z6ZKK7.<bundleId>` and the expected platform. Right before the move
/// the path is `lstat`ed again and must still be the same file (device, inode, size and modification time), else
/// it is skipped and counted. A profile of the paid team, the lab's WebDriverAgent, atvloadly's apps, another
/// bundle ID or the other platform of the same ID is never touched, and neither is a file that does not decode.
///
/// Nothing is deleted or copied. A move is one `renamex_np(RENAME_EXCL)` on one volume, so it is atomic and never
/// overwrites; across volumes it is refused (`RENEW_CROSS_VOLUME`). A moved file stays in `tmp/` (0600).
///
/// The result is an `Outcome`, and `moveOwnProfiles` never throws: whatever happened, the five reporting keys
/// (`Outcome.keys`) describe it. A `RenewProgress` shares the running outcome with the signal handler, which seals it
/// so a signal during the later build still reports what was moved. Every move is written to the ledger as an intent
/// before the rename (`RenewJournal`), so a crash cannot lose track of a file.
///
/// Owner-approved for use only if S3 shows that Xcode reuses the profile.
public enum ProfileCacheRenewal {
    static let toolTimeout = Duration.seconds(30)
    /// A real profile is a few tens of kilobytes; anything near this is not one.
    static let maxProfileBytes = 1 << 20
    /// A destination name already taken (a 48-bit random collision) is retried with a new name this many times.
    static let maxNameTries = 3

    public struct Outcome: Sendable, Equatable {
        /// Files moved into `tmp/`.
        public var moved = 0
        /// Entries named `*.mobileprovision` that were not safe to read or move: a symlink or other non-regular
        /// file, too large, unreadable, or changed between the read and the move. Never moved.
        public var skipped = 0
        /// Entries named `*.mobileprovision` beyond the scan cap (`XcodeManagedProfileSource.maxFiles` per folder),
        /// which were not looked at.
        public var truncated = 0
        /// Where the moved files went, as names relative to `$SIDELOAD_HOME` (`tmp/renewed-profile-<random>.mobileprovision`).
        public var movedTo: [String] = []
        /// Files moved by mistake (not the vetted file) that could not be put back, whatever the error: reported
        /// whenever a file is not known to be back. They stay in `tmp/` for the owner to look at; never deleted.
        public var strayInTmp: [String] = []
        /// Why the renewal stopped early, if it did. It carries no data: the outcome is the data.
        public var error: SideloadError?

        public init() {}

        /// The five keys every envelope carries once the renewal started.
        public static let keys = [
            "cachedProfilesMoved", "cachedProfilesSkipped", "cachedProfilesMovedTo", "cachedProfilesStrayInTmp",
            "renewScanTruncated",
        ]

        /// The one rendering of the outcome; nothing else writes these keys.
        public var json: [String: JSONValue] {
            [
                "cachedProfilesMoved": .number(Double(moved)), "cachedProfilesSkipped": .number(Double(skipped)),
                "cachedProfilesMovedTo": .array(movedTo.map { .string($0) }),
                "cachedProfilesStrayInTmp": .array(strayInTmp.map { .string($0) }),
                "renewScanTruncated": .number(Double(truncated)),
            ]
        }
    }

    /// Whether `profile` is the one `provision` would have Xcode renew for `bundleId` on `platform`
    /// (`iOS` or `tvOS`).
    static func isOurs(_ profile: ProvisioningProfile, bundleId: String, platform: String) -> Bool {
        profile.team == Team.free && profile.applicationIdentifier == Team.free + "." + bundleId
            && profile.platforms.contains(platform)
    }

    struct Identity: Equatable {
        let dev: dev_t
        let ino: ino_t
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int

        init(_ st: stat) {
            dev = st.st_dev
            ino = st.st_ino
            size = st.st_size
            mtimeSec = st.st_mtimespec.tv_sec
            mtimeNsec = st.st_mtimespec.tv_nsec
        }
    }

    /// The bytes of a regular file opened without following a symlink, with the identity of what was opened.
    /// Nil when it is not a regular file, is too large, or cannot be read.
    static func readCandidate(_ path: String) -> (bytes: Data, identity: Identity)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= off_t(maxProfileBytes) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            data.append(buffer, count: n)
            if data.count > maxProfileBytes { return nil }
        }
        return (data, Identity(st))
    }

    /// A label for one of Xcode's folders, for the ledger and the envelope: never a path.
    static func folderLabel(_ path: String, index: Int) -> String {
        if path.hasSuffix("/Library/Developer/Xcode/UserData/Provisioning Profiles") { return "xcode-userdata" }
        if path.hasSuffix("/Library/MobileDevice/Provisioning Profiles") { return "mobiledevice" }
        return "folder-\(index + 1)"
    }

    private static func moveFailed(
        _ message: String = "A cached provisioning profile could not be moved aside.",
        fix: String = "Check the permissions of Xcode's provisioning profile folder and of $SIDELOAD_HOME/tmp; nothing was built."
    ) -> SideloadError {
        SideloadError("PROFILE_MOVE_FAILED", message, fix: fix)
    }

    private static let crossVolume = SideloadError(
        "RENEW_CROSS_VOLUME",
        "$SIDELOAD_HOME/tmp is on a different volume than Xcode's provisioning profile folder, so a cached profile cannot be moved aside without copying.",
        fix: "Put $SIDELOAD_HOME on the same volume as ~/Library (the default ~/.sideload is), or run provision without --renew. Nothing was built.")

    /// Moves every matching profile in `directories` into `tmp`. Never throws; see `Outcome.error`. The seams are for
    /// tests: `fs` is the syscalls, `beforeMove` is called with the path after the bytes were decoded and matched, and
    /// before the identity re-check; `afterCheck` after the re-check and right before the rename.
    public static func moveOwnProfiles(
        in directories: [String], bundleId: String, platform: String, to tmp: String, runner: any Runner
    ) async -> Outcome {
        await moveOwnProfiles(
            in: directories, bundleId: bundleId, platform: platform, to: tmp, runner: runner, beforeMove: { _ in },
            afterCheck: { _ in })
    }

    static func moveOwnProfiles(
        in directories: [String], bundleId: String, platform: String, to tmp: String, runner: any Runner,
        now: Date = Date(), progress: RenewProgress = RenewProgress(), fs: RenewFS = .live,
        journal: RenewJournal = .none, beforeMove: (String) -> Void, afterCheck: (String) -> Void
    ) async -> Outcome {
        func stop(_ error: SideloadError) -> Outcome {
            progress.update { $0.error = error }
            return progress.snapshot
        }

        // Setup, once: the destination folder, and its volume.
        do { try fs.mkdir(tmp) } catch { return stop(moveFailed()) }
        guard let tmpStat = fs.stat(tmp), tmpStat.st_mode & S_IFMT == S_IFDIR else { return stop(moveFailed()) }
        for dir in directories {
            if let dirStat = fs.stat(dir), dirStat.st_dev != tmpStat.st_dev { return stop(crossVolume) }
        }

        for (index, dir) in directories.enumerated() {
            let folder = folderLabel(dir, index: index)
            let names: [String]
            do {
                guard let listed = try fs.list(dir) else { continue }
                names = listed
            } catch {
                return stop(
                    SideloadError(
                        "PROFILES_UNREADABLE", "A provisioning profile folder could not be listed.",
                        fix: "Check that the folder exists and is readable."))
            }
            let profiles = names.filter { $0.hasSuffix(".mobileprovision") }.sorted()
            progress.update { $0.truncated += max(0, profiles.count - XcodeManagedProfileSource.maxFiles) }
            for name in profiles.prefix(XcodeManagedProfileSource.maxFiles) {
                let path = dir + "/" + name
                guard let candidate = readCandidate(path) else {
                    progress.update { $0.skipped += 1 }
                    continue
                }
                // Decode exactly the bytes just read (stdin), not whatever the path holds by now.
                let result = await runner.run(
                    CommandSpec(
                        executable: "/usr/bin/security", args: ["cms", "-D"], timeout: toolTimeout, stdin: candidate.bytes))
                guard result.code == 0, let profile = ProvisioningProfile.parse(result.stdout),
                    isOurs(profile, bundleId: bundleId, platform: platform)
                else { continue }
                beforeMove(path)
                guard let current = fs.lstat(path), current.st_mode & S_IFMT == S_IFREG,
                    Identity(current) == candidate.identity
                else {
                    progress.update { $0.skipped += 1 }
                    continue
                }
                afterCheck(path)
                if let error = await move(
                    path, name: name, folder: folder, tmp: tmp, identity: candidate.identity, now: now, progress: progress, fs: fs,
                    journal: journal)
                {
                    return stop(error)
                }
            }
        }
        return progress.snapshot
    }

    /// One file: intent, rename, check, and (if it is not the vetted file) the move back. Nil on to the next file;
    /// an error stops the scan. Between the intent and the end of the syscalls the progress is locked, so a signal
    /// handler's snapshot never sees half a move and a sealed progress refuses to start one.
    private static func move(
        _ path: String, name: String, folder: String, tmp: String, identity: Identity, now: Date, progress: RenewProgress, fs: RenewFS,
        journal: RenewJournal
    ) async -> SideloadError? {
        enum Step { case moved, putBack, stray, failed(Int32) }
        for attempt in 0..<maxNameTries {
            let destName = "renewed-profile-\(randomHex(bytes: 6)).mobileprovision"
            let relative = "tmp/" + destName
            let destination = tmp + "/" + destName
            let entry = LedgerFreeRenewMove(from: name, to: relative, at: now, folder: folder)
            guard await journal.intent(entry) else {
                return moveFailed(
                    "A cached provisioning profile was not moved aside because the move could not be recorded in the ledger.",
                    fix: "Check the permissions and free space of $SIDELOAD_HOME; nothing was built.")
            }
            var step = Step.failed(0)
            let ran = progress.critical { outcome in
                let code = fs.renameExcl(path, destination)
                guard code == 0 else {
                    step = .failed(code)
                    return
                }
                // rename(2) keeps the inode, so what landed in tmp can be checked against what was vetted.
                if let landed = fs.lstat(destination), landed.st_dev == identity.dev, landed.st_ino == identity.ino {
                    _ = chmod(destination, 0o600)
                    outcome.moved += 1
                    outcome.movedTo.append(relative)
                    step = .moved
                    return
                }
                // Something else was at the path when it was moved: put it back, exclusively so a profile Xcode wrote
                // at that path meanwhile is never overwritten, count it, move on. Whatever stops the move back, the
                // file stays in tmp/ and is reported.
                outcome.skipped += 1
                if fs.renameExcl(destination, path) == 0 {
                    step = .putBack
                } else {
                    outcome.strayInTmp.append(relative)
                    step = .stray
                }
            }
            guard ran else {
                await journal.remove(relative)
                return SideloadError(
                    "INTERRUPTED", "Interrupted before a cached provisioning profile was moved.",
                    fix: "Nothing was deleted. Re-run the command.")
            }
            switch step {
            case .moved:
                await journal.mark(relative, .done)
                return nil
            case .putBack:
                await journal.remove(relative)
                return nil
            case .stray:
                await journal.mark(relative, .stray)
                return nil
            case .failed(let code):
                // rename(2) is atomic: on any failure the file is still where it was.
                await journal.remove(relative)
                if code == EEXIST, attempt + 1 < maxNameTries { continue }
                return code == EXDEV ? crossVolume : moveFailed()
            }
        }
        return moveFailed()
    }
}

/// The renewal's running outcome, shared between the main flow and the signal handler. `seal()` (the handler) marks
/// it final and returns a snapshot; after that `critical` refuses to start a move, so the handler's report can never
/// miss a file that main moves afterwards. `critical` holds the lock for syscalls only (no subprocess, no ledger
/// write): microseconds.
public final class RenewProgress: Sendable {
    private struct State {
        var outcome = ProfileCacheRenewal.Outcome()
        var sealed = false
    }

    private let state = Mutex(State())

    public init() {}

    func update(_ body: (inout ProfileCacheRenewal.Outcome) -> Void) {
        state.withLock { body(&$0.outcome) }
    }

    /// Runs `body` unless sealed; false (and `body` not run) once sealed.
    func critical(_ body: (inout ProfileCacheRenewal.Outcome) -> Void) -> Bool {
        state.withLock { s in
            guard !s.sealed else { return false }
            body(&s.outcome)
            return true
        }
    }

    public func seal() -> ProfileCacheRenewal.Outcome {
        state.withLock { s in
            s.sealed = true
            return s.outcome
        }
    }

    public var snapshot: ProfileCacheRenewal.Outcome { state.withLock { $0.outcome } }
}

private func liveStat(_ path: String, followLinks: Bool) -> stat? {
    var st = stat()
    return (followLinks ? stat(path, &st) : lstat(path, &st)) == 0 ? st : nil
}

/// The syscalls of the renewal, as closures so a test can fail any of them. `renameExcl` returns 0 or the errno.
struct RenewFS: Sendable {
    /// The entries of a folder; nil when the folder does not exist, a throw when it cannot be listed.
    var list: @Sendable (String) throws -> [String]?
    var lstat: @Sendable (String) -> stat?
    var stat: @Sendable (String) -> stat?
    var mkdir: @Sendable (String) throws -> Void
    var renameExcl: @Sendable (_ from: String, _ to: String) -> Int32

    static let live = RenewFS(
        list: { dir in
            do {
                return try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
        },
        lstat: { liveStat($0, followLinks: false) },
        stat: { liveStat($0, followLinks: true) },
        mkdir: { try makeDirectories($0, mode: 0o700) },
        renameExcl: { from, to in
            renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        })
}

/// Where the renewal records each move before it makes it. `intent` returns false when the record could not be
/// written (the move is then not made). `mark` and `remove` are best effort: a failed one leaves the entry as it
/// was, which the next run reports (over-reporting is the safe side).
struct RenewJournal: Sendable {
    var intent: @Sendable (LedgerFreeRenewMove) async -> Bool
    var mark: @Sendable (_ to: String, _ state: LedgerFreeRenewMove.State) async -> Void
    var remove: @Sendable (_ to: String) async -> Void

    static let none = RenewJournal(intent: { _ in true }, mark: { _, _ in }, remove: { _ in })

    static func ledger(_ store: LedgerStore) -> RenewJournal {
        RenewJournal(
            intent: { entry in
                (try? await store.update { $0.freeRenewMoves.append(entry) }) != nil
            },
            mark: { to, state in
                _ = try? await store.update { ledger in
                    for i in ledger.freeRenewMoves.indices where ledger.freeRenewMoves[i].to == to {
                        ledger.freeRenewMoves[i].state = state
                    }
                }
            },
            remove: { to in
                _ = try? await store.update { $0.freeRenewMoves.removeAll { $0.to == to } }
            })
    }
}
