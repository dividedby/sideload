import CryptoKit
import Darwin
import Foundation

/// Lend-time backup and return-time restore of one free-team app's data container (design section 18, "App data").
/// Apple tools only: `devicectl device info files` / `copy from` / `copy to` through `FreeDeviceCalls` and the `DeviceCtl`
/// allowlist. Backups live in `$SIDELOAD_HOME/backups/<alias>/<app>/<stamp>/` (`manifest.json` + `data/<relative path>`),
/// directories 0700 and files 0600. They hold session tokens: they are secrets-class, so no path, file name or content
/// ever reaches the output, a log line, the ledger or the repo; the output carries counts and booleans only.
///
/// Neither half is a slot operation and neither can fail a command: every outcome is data (`Result`), a failure becomes a
/// warning, and the caller goes on. The backup is read-only, so a crash leaves a `.partial` folder and an untouched device.
/// A backup is tied to the lend that made it (`lendSince`, the `since` the slot record carries), so a return never restores
/// a stale one. The restore only ever follows a confirmed install; a successful, verified restore marks the manifest
/// (`restoredAt`) and is never repeated.
enum AppDataBackup {
    static let totalBudgetSec = 120
    static let listTimeoutSec = 60
    static let copyTimeoutSec = 30
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
    }

    /// What a half did, as the lab reads it: counts and booleans, and warnings (codes, counts-only messages).
    struct Result: Sendable, Equatable {
        var done = false
        var files = 0
        var failed = 0
        var skipped = false
        var warnings: [JSONValue] = []
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

        /// The timeout for the next call, or nil when the allowance is spent.
        func timeout(cap: Int) -> Int? {
            let remaining = left
            return remaining > 0 ? min(cap, remaining) : nil
        }
    }

    private static func callSucceeded(_ out: FreeDeviceCalls.Outcome) -> Bool {
        out.code == 0 && !out.timedOut && !out.overflow && out.spawnError == nil
    }

    // MARK: listing

    struct DeviceFile: Equatable {
        let path: String
        let size: Int?
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
            files.append(DeviceFile(path: path, size: size))
        }
        return files
    }

    private static func isSkipped(_ path: String) -> Bool {
        ["tmp", "Library/Caches"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The files worth copying: leaves of the listing (a directory is not a file), outside `Library/Caches` and `tmp`, sorted.
    static func leaves(_ listing: [DeviceFile]) -> [DeviceFile] {
        var directories = Set<String>()
        for file in listing {
            var parts = file.path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            while !parts.isEmpty {
                directories.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        var seen = Set<String>()
        return listing.filter { !directories.contains($0.path) && !isSkipped($0.path) && seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    // MARK: files

    private static func secureDirectory(_ path: String, services: Services) throws {
        let root = services.home.backups
        try makeDirectories(path, mode: 0o700)
        var current = path
        while current.count >= root.count {
            if chmod(current, 0o700) != 0 { throw ioError("chmod") }
            if current == root { break }
            current = parentPath(current)
        }
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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { !$0.hasSuffix(".partial") && !$0.hasPrefix(".") }.sorted(by: >)
    }

    /// Keeps the newest `keep` backups of this device and app, and sweeps every `.partial` folder (the command holds
    /// `.op.lock`, so none is in progress).
    static func prune(_ services: Services, _ target: FreeTarget) {
        let directory = appDirectory(services, target)
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
        case failed
    }

    /// One file out of the device. A size that differs from the listing is retried once; anything else is failed.
    private static func copyOne(
        _ file: DeviceFile, to partial: String, calls: FreeDeviceCalls, budget: Budget, services: Services
    ) async throws -> Copy {
        let destination = partial + "/data/" + file.path
        try secureDirectory(parentPath(destination), services: services)
        for attempt in 0..<2 {
            guard let timeout = budget.timeout(cap: copyTimeoutSec) else { return .failed }
            let out = await calls.copyFrom(source: file.path, destination: destination, timeoutSec: timeout)
            guard callSucceeded(out) else {
                unlink(destination)
                return .failed
            }
            guard let size = regularFileSize(destination) else { return .emptyDirectory }
            chmod(destination, 0o600)
            if let expected = file.size, expected != size {
                unlink(destination)
                if attempt == 0 { continue }
                return .failed
            }
            guard let digest = sha256(destination) else {
                unlink(destination)
                return .failed
            }
            return .copied(Entry(path: file.path, size: size, sha256: digest))
        }
        return .failed
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
        services.log("app data backup: \(result.files) file(s) saved, \(result.failed) failed")
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
        var todo = Array(wanted.prefix(maxFiles))
        var failed = wanted.count - todo.count
        try secureDirectory(partial, services: services)
        var entries: [Entry] = []
        var bytes = 0
        var spent = false
        while !todo.isEmpty {
            let file = todo.removeFirst()
            if spent {
                failed += 1
                continue
            }
            switch try await copyOne(file, to: partial, calls: calls, budget: budget, services: services) {
            case .copied(let entry):
                bytes += entry.size
                if bytes > maxBytes {
                    unlink(partial + "/data/" + entry.path)
                    failed += 1
                    spent = true
                } else {
                    entries.append(entry)
                }
            case .emptyDirectory: break
            case .failed:
                failed += 1
                if budget.left <= 0 { spent = true }
            }
        }
        if entries.isEmpty, failed > 0 {
            removeTree(partial)
            result.failed = failed
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
        result.failed = failed
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

    /// The newest backup made for this lend and not yet restored.
    private static func candidate(_ services: Services, _ target: FreeTarget, since: Date) -> (directory: String, manifest: Manifest)? {
        let base = appDirectory(services, target)
        for name in finished(base) {
            let directory = base + "/" + name
            guard let manifest = readManifest(in: directory), manifest.bundleId == target.bundleId,
                abs(manifest.lendSince.timeIntervalSince(since)) < 1, manifest.restoredAt == nil
            else { continue }
            return (directory, manifest)
        }
        return nil
    }

    /// Restores the backup of this lend into the reinstalled app, file by file, then relists and compares. Never throws and
    /// never fails the return: `done` is true only when every file was pushed and the relisting matched, and only then is
    /// the manifest marked and the old backups pruned. No backup for this lend is simply `done == false` with no warning.
    static func restore(_ services: Services, target: FreeTarget, calls: FreeDeviceCalls, since: Date?) async -> Result {
        var result = Result()
        guard let since, let found = candidate(services, target, since: since) else { return result }
        let budget = Budget(services.clock)
        let manifest = found.manifest
        var pushed: [Entry] = []
        var failed = 0
        var spent = false
        for entry in manifest.files {
            let local = found.directory + "/data/" + entry.path
            guard !spent, DeviceCtl.isSafeDevicePath(entry.path), regularFileSize(local) == entry.size, sha256(local) == entry.sha256,
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
        result.failed = failed
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
                    result.failed = missing.count
                    verified = missing.isEmpty
                }
            }
            if !verified, result.failed == 0 {
                result.warnings.append(
                    CanaryCommand.warning(
                        "DATA_RESTORE_UNVERIFIED",
                        "The app's data was copied back, but the device's file list could not be read to confirm it.",
                        "Open the app and check it is signed in; the backup is kept."))
            }
        }
        if result.failed > 0 {
            result.warnings.append(
                CanaryCommand.warning(
                    "DATA_RESTORE_INCOMPLETE",
                    "\(result.failed) of \(manifest.files.count) data files were not restored (or did not verify).",
                    "The backup is kept; the app may ask to sign in again."))
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
