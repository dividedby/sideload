import Foundation

public struct CleanOptions: Sendable, Equatable {
    /// The owner's flag. Without it the command only reports what it would delete.
    public var yes: Bool

    public init(yes: Bool = false) {
        self.yes = yes
    }
}

/// `clean [--yes]` (design section 9, "Clean"; section 18, "App data", retention). Owner-only with `--yes`; without it a preview
/// that deletes nothing, which an agent may run. It deletes two kinds of file under `$SIDELOAD_HOME` and nothing else:
///
/// - app-data backups past their retention (`CleanBackups`), and
/// - downloaded IPAs no longer needed (`CleanDownloads`), whose manifest entries stay, marked `prunedAt`.
///
/// It takes `.op.lock` for the whole run (a busy lock is `OPERATION_IN_PROGRESS`, never waited on), and touches no device, no
/// network, no keychain, no portal and no subprocess. The output is counts and the app aliases of the downloads; no path, no
/// file or folder name, nothing from a backup. Progress lines are counts only.
///
/// With `--yes`, in order: the manifest is rewritten once with `prunedAt` on every entry about to lose its folder; then those
/// folders go; then the backups. A crash after the manifest write leaves marked entries whose folder may still exist, and a rerun
/// finishes them.
public enum CleanCommand {
    static let command = "clean"
    /// How long a backup is kept after it was restored or superseded (or, for a device that is no longer saved, after its newest
    /// timestamp).
    static let retentionDays = 14
    static let retention = TimeInterval(retentionDays) * 86_400

    public static func run(_ services: Services, _ options: CleanOptions) -> Envelope {
        run(services, options, afterMarked: nil)
    }

    /// `afterMarked` is the test hook for a crash: called once the manifest write is durable and before any file goes.
    static func run(_ services: Services, _ options: CleanOptions, afterMarked: (() throws -> Void)?) -> Envelope {
        do {
            return try execute(services, options, afterMarked: afterMarked)
        } catch {
            return .from(error, command: command)
        }
    }

    private static func execute(_ services: Services, _ options: CleanOptions, afterMarked: (() throws -> Void)?) throws -> Envelope {
        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }

        let config = try services.store.load()
        let ledger = try services.ledgerStore.load()
        let store = ManifestStore(paths: services.home)
        let manifest = try store.load()
        let now = services.clock.now()
        let migrated = SlotRule.migrated(ledger, now: now)

        let backupPlan = CleanBackups.plan(services, config: config, ledger: migrated, now: now)
        let downloadPlan = CleanDownloads.plan(services, manifest: manifest, ledger: ledger)
        let verb = options.yes ? "deleting" : "would delete"
        services.log(
            "clean: backups: \(verb) \(backupPlan.counts.deleted), keeping \(backupPlan.counts.kept), unreadable \(backupPlan.counts.unreadable)")
        services.log(
            "clean: downloads: \(verb) \(downloadPlan.deleted) version(s), keeping \(downloadPlan.kept)")

        var backups = backupPlan.counts
        var downloads = downloadPlan
        if options.yes {
            if !downloadPlan.marks.isEmpty {
                try store.save(CleanDownloads.marked(manifest, plan: downloadPlan, at: now))
            }
            try afterMarked?()
            downloads = CleanDownloads.apply(downloadPlan, services: services)
            backups = CleanBackups.apply(backupPlan, services: services)
            services.log("clean: done")
        }
        return envelope(dryRun: !options.yes, backups: backups, downloads: downloads)
    }

    // MARK: deleting

    /// Deletes the folder at `path` only if it and every part between `root` and it is a real folder (`lstat`, nothing followed).
    /// False when the chain is not plain or the removal failed.
    static func removePlainFolder(_ path: String, root: String) -> Bool {
        guard AppDataBackup.isPlain(path, root: root, regularFile: false) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    // MARK: output

    private static func envelope(dryRun: Bool, backups: CleanBackups.Counts, downloads: CleanDownloads.Plan) -> Envelope {
        var warnings: [JSONValue] = []
        if backups.unreadable > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "BACKUPS_UNREADABLE",
                    "\(backups.unreadable) backup folder(s) have a missing or unreadable manifest and were kept.",
                    "Look at backups/ under $SIDELOAD_HOME yourself; they hold session tokens."))
        }
        if backups.devicesSkippedBusy > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "DEVICE_BUSY_SKIPPED",
                    "\(backups.devicesSkippedBusy) device(s) hold a slot for the lab or have an operation in flight; their backups were skipped.",
                    "Run clean again after the lab returns the slot."))
        }
        if backups.linksSkipped + downloads.skipped > 0 {
            warnings.append(
                CanaryCommand.warning(
                    "LINKS_SKIPPED",
                    "\(backups.linksSkipped + downloads.skipped) folder(s) under backups/ or downloads/ sit behind a link (or have an unusable manifest path) and were left alone.",
                    "Check backups/ and downloads/ under $SIDELOAD_HOME."))
        }
        var data: [String: JSONValue] = [
            "dryRun": .bool(dryRun), "retentionDays": .number(Double(retentionDays)), "backups": .object(backups.json),
            "downloads": .object(downloads.json), "warnings": .array(warnings),
        ]
        if dryRun { data["next"] = .string("Nothing was deleted. The owner deletes with: sideload clean --yes") }

        let failed = backups.failed + downloads.failed
        guard failed > 0 else { return .result(command, data) }
        return Envelope(
            ok: false, command: command, data: data,
            errors: [
                .init(
                    code: "CLEAN_INCOMPLETE", message: "\(failed) folder(s) could not be deleted.",
                    fix: "Check the permissions under $SIDELOAD_HOME, then run `sideload clean --yes` again.")
            ])
    }
}
