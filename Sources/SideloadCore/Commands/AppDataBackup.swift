import CryptoKit
import Darwin
import Foundation

/// Lend-time backup and return-time restore of one free-team app's data container (design section 18, "App data").
/// Apple tools only: `devicectl device info files` / `copy from` / `copy to` through `FreeDeviceCalls` and the `DeviceCtl`
/// allowlist. Backups live in `$SIDELOAD_HOME/backups/<alias>/<app>/<stamp>/` (`manifest.json` + `data/<relative path>`),
/// directories 0700 and files 0600. They hold session tokens: they are secrets-class, so no content, and no path or file
/// name, ever reaches the output, the progress lines, the ledger or the repo; those carry counts and booleans only. The one
/// place file names do appear is the `devicectl` argv that `LoggingRunner` writes to `logs/commands.log`, like every
/// subprocess, inside the 0700 home.
///
/// Neither half is a slot operation and neither can fail a command: every outcome is data (`Result`), a failure becomes a
/// warning, and the caller goes on. The backup is read-only, so a crash leaves a `.partial` folder and an untouched device.
/// A backup is tied to the lend that made it (`lendSince`, the `since` the slot record carries), so a return never restores
/// a stale one. The restore only ever follows a confirmed install; a successful, verified restore marks the manifest
/// (`restoredAt`) and is not repeated by the return. A restore that did not finish is retried by the owner with
/// `sideload slot restore` (`SlotRestore`); a newer lend marks older unrestored backups `supersededAt`, so that retry never
/// pushes data from an earlier lend.
///
/// The restore (`device copy to`) was first checked on a real device on 2026-10-25 (the app was still signed in; docs/design.md
/// section 18); everything here is still written to leave the backup in place when the restore does not work.
enum AppDataBackup {
    static let totalBudgetSec = 120
    static let listTimeoutSec = 60
    static let copyTimeoutSec = 30
    /// What one call can last past its `--timeout`, from the real constants: `DeviceCtl.runnerMarginSec` (the Runner's own timeout
    /// is the `--timeout` plus it) and `PosixSpawnRunner.worstCaseOverrunSec` (the Runner's time to stop a child after that).
    static var runnerGraceSec: Int { DeviceCtl.runnerMarginSec + PosixSpawnRunner.worstCaseOverrunSec }
    /// No call is started with a `--timeout` below this.
    static let minCallSec = 5
    static let maxFiles = 200
    static let maxBytes = 256 * 1024 * 1024
    /// Backups kept per device and app.
    static let keep = 2

    struct Entry: Codable, Equatable {
        var path: String
        var size: Int
        var sha256: String
    }

    struct Manifest: Codable, Equatable {
        var bundleId: String
        var version: String
        var lendSince: Date
        var createdAt: Date
        var complete: Bool
        var files: [Entry]
        var restoredAt: Date?
        /// Set by a later `slot lend` that started a new lend of this app (design section 18): the backup belongs to an earlier
        /// lend, so `slot restore` never pushes it. Absent in manifests written before it existed.
        var supersededAt: Date?
        /// Set once the lend that made this backup is known to have taken the app off the device (the uninstall confirmed at the
        /// lend, or the return that found the app gone). Until then the app's live data was never deleted, so the backup may be
        /// older than it, and `slot restore` does not push it. Absent in manifests written before it existed.
        var uninstalledAt: Date?
    }

    /// Why one file was not saved or not restored. A fixed set: the raw values are the `dataFailures` keys the lab reads and the
    /// words in the progress line, so they carry no path, file name or content. Declared order is the print order.
    enum FailReason: String, CaseIterable, Sendable {
        /// The listing named a path that is not a safe relative path (backup), or the manifest did (restore).
        case unsafePath
        /// The listing named a path that collides with an earlier one (case, Unicode form, or file against folder).
        case nameCollision
        /// More files than `maxFiles`.
        case fileCap
        /// Over the 256 MiB cap (by the listing, or once copied), or skipped because the cap had been reached.
        case sizeLimit
        /// No allowance left for another call, or skipped because it had run out.
        case timeLimit
        /// Something on this Mac: the folder, the destination, the permissions, the hash, or (restore) the file changed since
        /// the backup.
        case localError
        /// The copy left a link, a folder or another non-regular file at the destination.
        case notRegularFile
        /// The copied size differed from the listing on both tries.
        case sizeMismatch
        /// The `devicectl` call ran out of time, or its own `--timeout` fired.
        case copyTimeout
        /// The `devicectl` call reported a locked device.
        case copyDeviceLocked
        /// The `devicectl` call reported a device that is not connected.
        case copyDeviceNotConnected
        /// The call never ran: `devicectl` could not be started, the call threw, or the allowlist refused it.
        case copyNotRun
        /// Any other failed call: a non-zero exit, a reported `failed` outcome, an output overflow, a signal kill.
        case copyOther
        /// Restore only: the push went through but the relisting did not show the file (or showed another size).
        case notOnDevice
    }

    /// Counts per reason. The only way to count a failed file, so the counts always sum to `total`, which is `dataFilesFailed`.
    struct Failures: Sendable, Equatable {
        private var counts: [FailReason: Int] = [:]

        var total: Int { counts.values.reduce(0, +) }

        mutating func add(_ reason: FailReason, count: Int = 1) {
            guard count > 0 else { return }
            counts[reason, default: 0] += count
        }

        /// The non-zero counts in declared order.
        var nonZero: [(reason: FailReason, count: Int)] {
            FailReason.allCases.compactMap { reason in counts[reason].map { (reason, $0) } }
        }

        /// `dataFailures`: the non-zero counts by reason; nil when nothing failed.
        var json: JSONValue? {
            guard total > 0 else { return nil }
            return .object(Dictionary(uniqueKeysWithValues: nonZero.map { ($0.reason.rawValue, JSONValue.number(Double($0.count))) }))
        }

        /// ` (copyTimeout 2, notRegularFile 1)` for a progress line; empty when nothing failed. Fixed words and counts only.
        var summary: String {
            total > 0 ? " (" + nonZero.map { "\($0.reason.rawValue) \($0.count)" }.joined(separator: ", ") + ")" : ""
        }
    }

    /// What a half did, as the lab reads it: counts and booleans, and warnings (codes, counts-only messages).
    struct Result: Sendable, Equatable {
        var done = false
        var files = 0
        var failures = Failures()
        var skipped = false
        var warnings: [JSONValue] = []

        var failed: Int { failures.total }
    }

    /// `apps.<app>.backupData`: default true; anything but an explicit `false` backs up.
    static func isEnabled(_ config: Config, app: ProvisionApp) -> Bool {
        guard case .object(let entry)? = config.apps[app.rawValue], case .bool(let flag)? = entry["backupData"] else { return true }
        return flag
    }

    static func backupFields(_ result: Result) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "dataBackedUp": .bool(result.done), "dataFiles": .number(Double(result.files)),
            "dataFilesFailed": .number(Double(result.failed)),
        ]
        if result.skipped { fields["dataBackupSkipped"] = true }
        if let failures = result.failures.json { fields["dataFailures"] = failures }
        return fields
    }

    static func restoreFields(_ result: Result) -> [String: JSONValue] {
        [
            "dataRestored": .bool(result.done), "dataFilesRestored": .number(Double(result.files)),
            "dataFilesFailed": .number(Double(result.failed)),
        ]
    }

    // MARK: budget

    /// A wall-clock allowance for one half; read before every device call.
    private struct Budget {
        let clock: any WallClock
        let deadline: Date

        init(_ clock: any WallClock) {
            self.clock = clock
            deadline = clock.now().addingTimeInterval(TimeInterval(AppDataBackup.totalBudgetSec))
        }

        var left: Int { Int(deadline.timeIntervalSince(clock.now()).rounded(.down)) }

        /// The `--timeout` for the next call, or nil when it would be under `minCallSec`. The Runner kills a call only at
        /// `timeout + runnerGraceSec`, so the grace comes off what is left: the step stays within `totalBudgetSec` of wall time
        /// even when the last call hangs to the kill.
        func timeout(cap: Int) -> Int? {
            let usable = left - AppDataBackup.runnerGraceSec
            return usable >= AppDataBackup.minCallSec ? min(cap, usable) : nil
        }
    }

    /// A call counts as done only when it exited 0 and its own report does not say otherwise: devicectl can exit 0 while the
    /// JSON it wrote carries `info.outcome` of `failed` (or anything but `success`). No `info.outcome` at all is a success, as
    /// before (the copy commands print no document in some versions); `parseListing` applies the same rule to a listing.
    private static func callSucceeded(_ out: FreeDeviceCalls.Outcome) -> Bool {
        guard out.code == 0, !out.timedOut, !out.overflow, out.spawnError == nil else { return false }
        if case .object(let top)? = out.json, case .object(let info)? = top["info"], let outcome = info["outcome"] {
            return outcome == .string("success")
        }
        return true
    }

    /// Why a copy call failed, as a fixed class and nothing else. The class is best effort: it comes from
    /// `FreeInstallClassifier`, whose device-locked and not-connected patterns are loose and run over stderr, so a failure can
    /// be put in the wrong one of the two (never leaked: no text from the call is kept). A call that never ran is `copyNotRun`;
    /// the Runner's timeout and devicectl's own `--timeout` are `copyTimeout`; the rest, unclassified, is `copyOther`.
    private static func copyClass(_ out: FreeDeviceCalls.Outcome, calls: FreeDeviceCalls) -> FailReason {
        if out.spawnError != nil { return .copyNotRun }
        if out.timedOut { return .copyTimeout }
        switch calls.classify(.snapshot, out)?.code {
        case "TIMEOUT": return .copyTimeout
        case "DEVICE_LOCKED": return .copyDeviceLocked
        case "DEVICE_NOT_CONNECTED": return .copyDeviceNotConnected
        default: return .copyOther
        }
    }

    // MARK: listing

    struct DeviceFile: Equatable {
        let path: String
        let size: Int?
        /// `metadata` marks the entry as a directory (`isDirectory: true` or a `type` of `directory`).
        var isDirectory = false
    }

    /// `result.files[]` as `devicectl device info files --recurse --json-output` prints it: `name`, `relativePath`, `metadata`
    /// and `resources` per entry, directories included. The path is `relativePath`; the size is the number `metadata` carries
    /// as `size` or `fileSize`, when it carries one. Nil unless the whole document is a listing, so a bad read can never look
    /// like an empty container.
    static func parseListing(_ json: JSONValue?) -> [DeviceFile]? {
        guard case .object(let top)? = json, case .object(let result)? = top["result"], case .array(let items)? = result["files"]
        else { return nil }
        if case .object(let info)? = top["info"], let outcome = info["outcome"], outcome != .string("success") { return nil }
        var files: [DeviceFile] = []
        for item in items {
            guard case .object(let fields) = item, case .string(let path)? = fields["relativePath"], !path.isEmpty else { return nil }
            var size: Int?
            if case .object(let metadata)? = fields["metadata"] {
                for key in ["size", "fileSize"] {
                    if case .number(let value)? = metadata[key], value >= 0, value < 1e15 { size = Int(value) }
                }
            }
            var isDirectory = false
            if case .object(let metadata)? = fields["metadata"] {
                if metadata["isDirectory"] == .bool(true) { isDirectory = true }
                if case .string(let kind)? = metadata["type"], kind.lowercased() == "directory" { isDirectory = true }
            }
            files.append(DeviceFile(path: path, size: size, isDirectory: isDirectory))
        }
        return files
    }

    /// The comparison key of a path: the filesystems behind `backups/` are case-insensitive and Unicode-normalising (APFS), so two
    /// paths with the same key are the same local name.
    private static func fold(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil).decomposedStringWithCanonicalMapping
    }

    private static func isSkipped(_ path: String) -> Bool {
        let key = fold(path)
        return ["tmp", "library/caches"].contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// A listing path that may become a local path: relative, plain parts, no NUL, no backslash (nothing else is looked at or
    /// created for it). The `DeviceCtl` allowlist checks it again before a call.
    static func isSafeEntryPath(_ path: String) -> Bool {
        DeviceCtl.isSafeDevicePath(path) && !path.contains("\\")
    }

    struct Leaves {
        var files: [DeviceFile]
        /// Entries dropped for an unsafe path.
        var unsafe = 0
        /// Entries dropped for colliding with an earlier one.
        var collisions = 0
        var dropped: Int { unsafe + collisions }
    }

    /// The files worth copying, in the order they are copied, and how many entries were dropped as unusable. Cut down before any
    /// filesystem or device call. Dropped and counted: an unsafe path, and a path that collides case-insensitively and
    /// Unicode-normalised with an earlier one (or with a directory); the first in copy order is kept. Skipped, not counted:
    /// directories (an entry that is the parent of another entry, or that `metadata` marks as one) and anything under
    /// `Library/Caches` or `tmp`. Order: `Library/Preferences` first (the sign-in lives there and must not be starved), then files
    /// whose size is known, then the rest; by path within each.
    static func leaves(_ listing: [DeviceFile]) -> Leaves {
        var unsafe = 0
        var safe: [DeviceFile] = []
        for entry in listing {
            if isSafeEntryPath(entry.path) { safe.append(entry) } else { unsafe += 1 }
        }
        var directories = Set<String>()
        var foldedDirectories = Set<String>()
        for file in safe {
            var parts = file.path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            while !parts.isEmpty {
                let parent = parts.joined(separator: "/")
                directories.insert(parent)
                foldedDirectories.insert(fold(parent))
                parts = parts.dropLast()
            }
        }
        func rank(_ file: DeviceFile) -> Int {
            if file.path.hasPrefix("Library/Preferences/") { return 0 }
            return file.size == nil ? 2 : 1
        }
        let ordered = safe.filter { !$0.isDirectory && !directories.contains($0.path) && !isSkipped($0.path) }
            .sorted { (rank($0), $0.path) < (rank($1), $1.path) }
        var seen = Set<String>()
        var kept: [DeviceFile] = []
        var collisions = 0
        for file in ordered {
            let key = fold(file.path)
            if foldedDirectories.contains(key) || !seen.insert(key).inserted {
                collisions += 1
            } else {
                kept.append(file)
            }
        }
        return Leaves(files: kept, unsafe: unsafe, collisions: collisions)
    }

    /// `<base>/data/<rel>`, only when `rel` is a safe entry path and the result stays under `$SIDELOAD_HOME/backups/`.
    private static func localPath(_ base: String, _ rel: String, services: Services) -> String? {
        let path = base + "/data/" + rel
        guard isSafeEntryPath(rel), DeviceCtl.isSafeBackupPath(path, backups: services.home.backups) else { return nil }
        return path
    }

    // MARK: files

    /// Makes `path` (the backups folder `root` or a path inside it) a chain of real, owned folders of mode 0700, one part at a
    /// time, never following a link: each part is `lstat`ed, created with `mkdir` when missing, refused when it is a symlink or
    /// anything but a folder of ours, and chmodded through a descriptor opened with `O_NOFOLLOW`. So a link planted in the tree
    /// (or made by a case-insensitive name clash) can never redirect a folder creation or a chmod outside `root`.
    static func secureDirectory(_ path: String, root: String) throws {
        guard path == root || DeviceCtl.isSafeBackupPath(path, backups: root) else { throw ioError("path", EINVAL) }
        try makeDirectories(parentPath(root), mode: 0o700)
        var current = root
        try secureOne(current)
        for part in path.dropFirst(root.count).split(separator: "/") {
            current += "/" + part
            try secureOne(current)
        }
    }

    private static func secureOne(_ directory: String) throws {
        var st = stat()
        if lstat(directory, &st) != 0 {
            guard errno == ENOENT else { throw ioError("stat") }
            if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw ioError("mkdir") }
            guard lstat(directory, &st) == 0 else { throw ioError("stat") }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid() else { throw ioError("folder check", EINVAL) }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ioError("open") }
        defer { close(fd) }
        if fchmod(fd, 0o700) != 0 { throw ioError("chmod") }
    }

    /// Whether `path` (the folder `root` or a path inside it) exists with every part a real folder, not a symlink, and, when
    /// `regularFile`, the last part a regular file. Nothing is followed.
    static func isPlain(_ path: String, root: String, regularFile: Bool) -> Bool {
        guard path == root || path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var st = stat()
        func check(_ item: String, last: Bool) -> Bool {
            guard lstat(item, &st) == 0 else { return false }
            return st.st_mode & S_IFMT == (last && regularFile ? S_IFREG : S_IFDIR)
        }
        var current = root
        guard check(current, last: parts.isEmpty) else { return false }
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { return false }
            current += "/" + part
            guard check(current, last: index == parts.count - 1) else { return false }
        }
        return true
    }

    /// Mode 0600 through a descriptor opened without following a link (the caller `lstat`ed a regular file).
    private static func restrictFile(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fchmod(fd, 0o600) == 0
    }

    /// Removes whatever is at `path` without following it (a symlink goes, its target stays).
    private static func discard(_ path: String) {
        if unlink(path) != 0 { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func regularFileSize(_ path: String) -> Int? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(st.st_size)
    }

    private static func sha256(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func writeManifest(_ manifest: Manifest, in directory: String) throws {
        try AtomicFile.write(try encoder().encode(manifest), to: directory + "/manifest.json", mode: 0o600)
    }

    private static func readManifest(in directory: String) -> Manifest? {
        guard let data = try? readFile(directory + "/manifest.json") else { return nil }
        return try? decoder().decode(Manifest.self, from: data)
    }

    private static func appDirectory(_ services: Services, _ target: FreeTarget) -> String {
        "\(services.home.backups)/\(target.alias)/\(target.app.rawValue)"
    }

    private static func removeTree(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Finished backups of one app, newest first (a `.partial` folder is never one).
    private static func finished(_ directory: String) -> [String] {
        finished((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
    }

    private static func finished(_ names: [String]) -> [String] {
        names.filter { !$0.hasSuffix(".partial") && !$0.hasPrefix(".") }.sorted(by: >)
    }

    /// Keeps the newest `keep` backups of this device and app, and sweeps every `.partial` folder (the command holds
    /// `.op.lock`, so none is in progress).
    static func prune(_ services: Services, _ target: FreeTarget) {
        let directory = appDirectory(services, target)
        guard isPlain(directory, root: services.home.backups, regularFile: false) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasSuffix(".partial") { removeTree(directory + "/" + name) }
        for name in finished(directory).dropFirst(keep) { removeTree(directory + "/" + name) }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date) + "-" + randomHex(bytes: 2)
    }

    // MARK: backup

    private enum Copy {
        case copied(Entry)
        case emptyDirectory
        case failed(FailReason)
    }

    /// One file out of the device. A size that differs from the listing is retried once; anything else is failed.
    private static func copyOne(
        _ file: DeviceFile, to partial: String, calls: FreeDeviceCalls, budget: Budget, services: Services
    ) async throws -> Copy {
        guard let destination = localPath(partial, file.path, services: services) else { return .failed(.unsafePath) }
        guard budget.timeout(cap: copyTimeoutSec) != nil else { return .failed(.timeLimit) }
        try secureDirectory(parentPath(destination), root: services.home.backups)
        var existing = stat()
        if lstat(destination, &existing) == 0 || errno != ENOENT { return .failed(.localError) }  // never write over, or through, anything there
        for attempt in 0..<2 {
            guard let timeout = budget.timeout(cap: copyTimeoutSec) else { return .failed(.timeLimit) }
            let out = await calls.copyFrom(source: file.path, destination: destination, timeoutSec: timeout)
            guard callSucceeded(out) else {
                discard(destination)
                return .failed(copyClass(out, calls: calls))
            }
            // What devicectl left is looked at without following it: only a regular file stays. A symlink (or a folder, or
            // anything else) is removed and counted failed; nothing here ever opens, chmods or writes through it.
            var st = stat()
            guard lstat(destination, &st) == 0 else { return errno == ENOENT ? .emptyDirectory : .failed(.localError) }
            guard st.st_mode & S_IFMT == S_IFREG else {
                discard(destination)
                return .failed(.notRegularFile)
            }
            guard restrictFile(destination) else {
                discard(destination)
                return .failed(.localError)
            }
            let size = Int(st.st_size)
            if let expected = file.size, expected != size {
                discard(destination)
                if attempt == 0 { continue }
                return .failed(.sizeMismatch)
            }
            guard let digest = sha256(destination) else {
                discard(destination)
                return .failed(.localError)
            }
            return .copied(Entry(path: file.path, size: size, sha256: digest))
        }
        return .failed(.localError)
    }

    /// Backs up the app's data container. Never throws and never blocks the lend: a failure is `done == false` plus a warning.
    static func backup(
        _ services: Services, target: FreeTarget, calls: FreeDeviceCalls, version: String, lendSince: Date
    ) async -> Result {
        var result = Result()
        let partial = appDirectory(services, target) + "/" + stamp(services.clock.now()) + ".partial"
        do {
            try await perform(&result, services, target, calls, version, lendSince, partial)
        } catch {
            removeTree(partial)
            result = Result()
            result.warnings = [
                CanaryCommand.warning(
                    "DATA_BACKUP_FAILED", "The app's data could not be saved on this Mac, so the lend goes ahead without a backup.",
                    "Check the free space and permissions of $SIDELOAD_HOME/backups; the app signs in again after the return.")
            ]
        }
        services.log("app data backup: \(result.files) file(s) saved, \(result.failed) failed\(result.failures.summary)")
        return result
    }

    private static func perform(
        _ result: inout Result, _ services: Services, _ target: FreeTarget, _ calls: FreeDeviceCalls, _ version: String,
        _ lendSince: Date, _ partial: String
    ) async throws {
        let budget = Budget(services.clock)
        func fail(_ message: String, _ fix: String) {
            result.warnings = [CanaryCommand.warning("DATA_BACKUP_FAILED", message, fix)]
        }
        guard let listTimeout = budget.timeout(cap: listTimeoutSec) else { return }
        let listed = await calls.listFiles(timeoutSec: listTimeout)
        guard callSucceeded(listed), let listing = parseListing(listed.json) else {
            fail(
                "The app's data could not be listed on the device, so the lend goes ahead without a backup.",
                "Unlock the device and keep it awake; the app signs in again after the return.")
            return
        }
        let wanted = leaves(listing)
        var todo = Array(wanted.files.prefix(maxFiles))
        var failures = Failures()
        failures.add(.unsafePath, count: wanted.unsafe)
        failures.add(.nameCollision, count: wanted.collisions)
        failures.add(.fileCap, count: wanted.files.count - todo.count)
        try secureDirectory(partial, root: services.home.backups)
        var entries: [Entry] = []
        var bytes = 0
        var spent = false
        var spentReason = FailReason.timeLimit  // what set `spent`; the files skipped after it are counted as that
        while !todo.isEmpty {
            let file = todo.removeFirst()
            if spent {
                failures.add(spentReason)
                continue
            }
            if let size = file.size, bytes + size > maxBytes {  // too big by the listing: not even asked for
                failures.add(.sizeLimit)
                continue
            }
            // One odd entry (a name over the length limit, say) costs only itself: it is counted failed and the rest goes on.
            let copied: Copy
            do {
                copied = try await copyOne(file, to: partial, calls: calls, budget: budget, services: services)
            } catch {
                copied = .failed(.localError)
            }
            switch copied {
            case .copied(let entry):
                bytes += entry.size
                if bytes > maxBytes {
                    discard(partial + "/data/" + entry.path)
                    failures.add(.sizeLimit)
                    spent = true
                    spentReason = .sizeLimit
                } else {
                    entries.append(entry)
                }
            case .emptyDirectory: break
            case .failed(let reason):
                failures.add(reason)
                if budget.left <= 0 {
                    spent = true
                    spentReason = .timeLimit
                }
            }
        }
        let failed = failures.total
        if entries.isEmpty, failed > 0 {
            removeTree(partial)
            result.failures = failures
            fail(
                "None of the app's data files could be copied, so the lend goes ahead without a backup.",
                "Unlock the device and keep it awake; the app signs in again after the return.")
            return
        }
        let manifest = Manifest(
            bundleId: target.bundleId, version: version, lendSince: lendSince, createdAt: wholeSeconds(services.clock.now()),
            complete: failed == 0, files: entries, restoredAt: nil)
        try writeManifest(manifest, in: partial)
        let final = String(partial.dropLast(".partial".count))
        if rename(partial, final) != 0 { throw ioError("rename") }
        result.done = true
        result.files = entries.count
        result.failures = failures
        if failed > 0 {
            result.warnings = [
                CanaryCommand.warning(
                    "DATA_BACKUP_INCOMPLETE",
                    "\(failed) of \(entries.count + failed) data files were not backed up (a copy failed, or the size or time limit was reached).",
                    "The return restores what was saved; the app may ask to sign in again.")
            ]
        }
        prune(services, target)
    }

    // MARK: restore

    /// The manifest of `directory` (a finished backup folder), only when the folder and the file are real, not links, and the
    /// manifest reads and is for this app's bundle ID. Nothing is followed.
    private static func trustedManifest(in directory: String, _ services: Services, _ target: FreeTarget) -> Manifest? {
        let root = services.home.backups
        guard isPlain(directory, root: root, regularFile: false), isPlain(directory + "/manifest.json", root: root, regularFile: true),
            let manifest = readManifest(in: directory), manifest.bundleId == target.bundleId
        else { return nil }
        return manifest
    }

    /// Every finished backup of this app that passes the link-safe scan (a plain app folder, then per folder a plain folder and
    /// manifest that reads for this bundle ID), newest first. A folder that fails any check is left out; callers add their own
    /// predicate and write.
    private static func manifests(_ services: Services, _ target: FreeTarget) -> [(directory: String, manifest: Manifest)] {
        let base = appDirectory(services, target)
        guard isPlain(base, root: services.home.backups, regularFile: false) else { return [] }
        return finished(base).compactMap { name in
            let directory = base + "/" + name
            return trustedManifest(in: directory, services, target).map { (directory, $0) }
        }
    }

    /// The newest backup made for this lend and not yet restored.
    private static func candidate(_ services: Services, _ target: FreeTarget, since: Date) -> (directory: String, manifest: Manifest)? {
        manifests(services, target).first { abs($0.manifest.lendSince.timeIntervalSince(since)) < 1 && $0.manifest.restoredAt == nil }
    }

    /// Restores the backup of this lend into the reinstalled app (`push`). Never throws and never fails the return. No backup
    /// for this lend is simply `done == false` with no warning.
    static func restore(_ services: Services, target: FreeTarget, calls: FreeDeviceCalls, since: Date?) async -> Result {
        // The return marked the backup at T4, before its install, so a failed push can be retried by `slot restore`.
        guard let since, let found = candidate(services, target, since: since) else { return Result() }
        return await push(services, target: target, calls: calls, found: found)
    }

    /// What `slot restore` finds: the newest finished backup when it is still waiting to be pushed, else why not (booleans only).
    enum PendingBackup {
        case found(directory: String, manifest: Manifest)
        case none(restored: Bool, superseded: Bool, unreadable: Bool, notUninstalled: Bool)

        static func nothing(
            restored: Bool = false, superseded: Bool = false, unreadable: Bool = false, notUninstalled: Bool = false
        ) -> PendingBackup {
            .none(restored: restored, superseded: superseded, unreadable: unreadable, notUninstalled: notUninstalled)
        }
    }

    /// The newest finished backup folder of this device and app decides, and only it (an older one is never a fallback: it
    /// belongs to an earlier lend). Pending means a readable manifest for this app's bundle ID with `restoredAt` and
    /// `supersededAt` unset and `uninstalledAt` set, and every file it lists a readable regular file under real folders. Each
    /// boolean is set on its own. Nothing is followed: the folder chain is walked from `backups/` one part at a time with
    /// `lstat`, and every manifest entry's local path is checked the same way before any device call. Anything that cannot be
    /// read, listed or `lstat`ed, or that is a link at any level, is `unreadable`, never "no backup": only a real folder chain
    /// that stops at a missing part, or an app folder with no finished backup in it, is that.
    static func pending(_ services: Services, _ target: FreeTarget) -> PendingBackup {
        let base = appDirectory(services, target)
        let root = services.home.backups
        switch walk(base, root: root) {
        case .missing: return .nothing()
        case .unreadable: return .nothing(unreadable: true)
        case .plain: break
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return .nothing(unreadable: true) }
        guard let name = finished(names).first else { return .nothing() }
        let directory = base + "/" + name
        guard let manifest = trustedManifest(in: directory, services, target) else { return .nothing(unreadable: true) }
        let readable = manifest.files.allSatisfy { entry in
            guard let local = localPath(directory, entry.path, services: services) else { return false }
            return isPlain(local, root: root, regularFile: true) && canOpen(local)
        }
        let restored = manifest.restoredAt != nil
        let superseded = manifest.supersededAt != nil
        let notUninstalled = manifest.uninstalledAt == nil  // its lend never took the app off the device (or predates the mark)
        guard readable, !restored, !superseded, !notUninstalled else {
            return .nothing(restored: restored, superseded: superseded, unreadable: !readable, notUninstalled: notUninstalled)
        }
        return .found(directory: directory, manifest: manifest)
    }

    private enum Walk { case plain, missing, unreadable }

    /// How the folder `path` (`root` or a path inside it) stands, walked from `root` one part at a time with `lstat`, never
    /// following a link: every part a real folder (`plain`); real folders up to a part that does not exist (`missing`); anything
    /// else, a link or a non-folder at any level or an `lstat` failure other than ENOENT (`unreadable`).
    private static func walk(_ path: String, root: String) -> Walk {
        guard path == root || path.hasPrefix(root + "/") else { return .unreadable }
        let parts = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        func check(_ item: String) -> Walk {
            var st = stat()
            guard lstat(item, &st) == 0 else { return errno == ENOENT ? .missing : .unreadable }
            return st.st_mode & S_IFMT == S_IFDIR ? .plain : .unreadable
        }
        var current = root
        var state = check(current)
        for part in parts where state == .plain {
            guard !part.isEmpty else { return .unreadable }
            current += "/" + part
            state = check(current)
        }
        return state
    }

    /// Whether the regular file at `path` opens for reading without following a link (the caller `lstat`ed it).
    private static func canOpen(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Marks the finished backups made for the lend `since` (`lendSince` within a second) as having had their app taken off the
    /// device, so `slot restore` may push them. Called once the lend's uninstall is confirmed. Never throws; same plain checks.
    static func markUninstalled(_ services: Services, _ target: FreeTarget, since: Date) {
        for (directory, found) in manifests(services, target)
        where found.uninstalledAt == nil && abs(found.lendSince.timeIntervalSince(since)) < 1 {
            var manifest = found
            manifest.uninstalledAt = wholeSeconds(services.clock.now())
            try? writeManifest(manifest, in: directory)
        }
    }

    /// Marks every finished, unrestored backup of an earlier lend (`lendSince` at least a second before `lendSince`) as
    /// superseded, so `slot restore` can never push data older than the lend that replaced it. Never throws: an unreadable or
    /// unwritable one is left as it is. The manifest is rewritten atomically, mode 0600, and no link is followed.
    static func supersedeOlder(_ services: Services, _ target: FreeTarget, than lendSince: Date) {
        for (directory, found) in manifests(services, target)
        where found.restoredAt == nil && found.supersededAt == nil && found.lendSince.timeIntervalSince(lendSince) <= -1 {
            var manifest = found
            manifest.supersededAt = wholeSeconds(services.clock.now())
            try? writeManifest(manifest, in: directory)
        }
    }

    /// Pushes a found backup into the app's data container file by file, then relists and compares. `done` is true only when
    /// every file was pushed and the relisting matched, and only then is the manifest marked and the old backups pruned. The
    /// whole step shares one `Budget`. Safe to repeat: a push overwrites.
    static func push(
        _ services: Services, target: FreeTarget, calls: FreeDeviceCalls, found: (directory: String, manifest: Manifest)
    ) async -> Result {
        var result = Result()
        let budget = Budget(services.clock)
        let manifest = found.manifest
        var pushed: [Entry] = []
        var failed = 0
        var spent = false
        for entry in manifest.files {
            // Every part of the local path is checked without following links, so a link planted inside the backup cannot
            // make the restore read (and push) a file from outside it.
            guard !spent, let local = localPath(found.directory, entry.path, services: services),
                isPlain(local, root: services.home.backups, regularFile: true), regularFileSize(local) == entry.size, sha256(local) == entry.sha256,
                let timeout = budget.timeout(cap: copyTimeoutSec)
            else {
                failed += 1
                if budget.left <= 0 { spent = true }
                continue
            }
            let out = await calls.copyTo(source: local, destination: entry.path, timeoutSec: timeout)
            if callSucceeded(out) {
                pushed.append(entry)
            } else {
                failed += 1
                if budget.left <= 0 { spent = true }
            }
        }
        result.files = pushed.count
        result.failures.add(.copyOther, count: failed)
        var verified = false
        if failed == 0, manifest.files.isEmpty {
            verified = true  // nothing was saved, so there is nothing to push or compare
        } else if failed == 0 {
            if let timeout = budget.timeout(cap: listTimeoutSec) {
                let out = await calls.listFiles(timeoutSec: timeout)
                if callSucceeded(out), let listing = parseListing(out.json) {
                    let there = Dictionary(listing.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
                    let missing = pushed.filter { entry in
                        guard let size = there[entry.path] else { return true }
                        return size != nil && size != entry.size
                    }
                    result.files = pushed.count - missing.count
                    result.failures = Failures()
                    result.failures.add(.copyOther, count: missing.count)
                    verified = missing.isEmpty
                }
            }
            if !verified, result.failed == 0 {
                result.warnings.append(
                    CanaryCommand.warning(
                        "DATA_RESTORE_UNVERIFIED",
                        "The app's data was copied back, but the device's file list could not be read to confirm it.",
                        "Open the app and check it is signed in; the backup is kept. The owner can retry: sideload slot restore --device \(target.alias) --app \(target.app.rawValue) --yes."))
            }
        }
        if result.failed > 0 {
            result.warnings.append(
                CanaryCommand.warning(
                    "DATA_RESTORE_INCOMPLETE",
                    "\(result.failed) of \(manifest.files.count) data files were not restored (or did not verify).",
                    "The backup is kept; the app may ask to sign in again. The owner can retry: sideload slot restore --device \(target.alias) --app \(target.app.rawValue) --yes (it refuses a backup that holds a link or an unreadable file, and then the app needs signing in again)."))
        }
        if verified {
            result.done = true
            var marked = manifest
            marked.restoredAt = wholeSeconds(services.clock.now())
            if (try? writeManifest(marked, in: found.directory)) != nil { prune(services, target) }
            if !manifest.complete {
                result.warnings.append(
                    CanaryCommand.warning(
                        "DATA_RESTORE_PARTIAL_BACKUP", "The backup was incomplete, so some of the app's data was not restored.",
                        "The app may ask to sign in again."))
            }
        }
        services.log("app data restore: \(result.files) file(s) restored, \(result.failed) failed")
        return result
    }
}
