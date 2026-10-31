import Darwin
import Foundation

/// The app-data half of `clean`: which backups under `$SIDELOAD_HOME/backups/<alias>/<app>/<stamp>/` have outlived their use
/// (design section 18, "App data", retention). Backups are secrets-class: the plan holds directory paths for the deletion step
/// only; what leaves this file is counts, never a path, a folder name or anything read from a backup.
///
/// Nothing is followed. `backups/`, each alias folder, each app folder and each backup folder must be a real folder (`lstat`);
/// a link at any of those levels is counted and left alone, a stray file is ignored, and a deletion re-checks the whole chain
/// from `backups/` first. Names starting with "." are ignored, as `AppDataBackup.prune` does.
enum CleanBackups {
    enum Reason: String, CaseIterable, Sendable {
        case restored, superseded, unsavedAlias, partial
    }

    struct Doomed: Equatable {
        var directory: String
        var reason: Reason
    }

    /// Every backup or `.partial` folder met is exactly one of deleted, kept, unreadable (or, after a deletion that failed,
    /// failed), so the four add up to the folders found.
    struct Counts: Equatable {
        var deleted = 0
        var kept = 0
        var unreadable = 0
        var failed = 0
        var devicesSkippedBusy = 0
        var linksSkipped = 0
        var byReason: [Reason: Int] = [:]

        var json: [String: JSONValue] {
            var reasons: [String: JSONValue] = [:]
            for reason in Reason.allCases { reasons[reason.rawValue] = .number(Double(byReason[reason] ?? 0)) }
            return [
                "deleted": .number(Double(deleted)), "kept": .number(Double(kept)), "unreadable": .number(Double(unreadable)),
                "failed": .number(Double(failed)), "devicesSkippedBusy": .number(Double(devicesSkippedBusy)),
                "linksSkipped": .number(Double(linksSkipped)), "byReason": .object(reasons),
            ]
        }
    }

    /// What every folder of one app folder is judged against.
    struct Context {
        var services: Services
        var saved: Bool
        /// The folder `slot restore` would restore from, when it can be asked.
        var pending: String?
        var cutoff: Date
    }

    struct Plan: Equatable {
        var doomed: [Doomed] = []
        var counts = Counts()
    }

    // MARK: plan

    /// `ledger` must be the migrated one (`SlotRule.migrated`), the way `DeviceRemove` reads busy. Read-only.
    static func plan(_ services: Services, config: Config, ledger: Ledger, now: Date) -> Plan {
        var plan = Plan()
        let root = services.home.backups
        let cutoff = now.addingTimeInterval(-CleanCommand.retention)
        let aliases = folders(in: root, root: root, links: &plan.counts.linksSkipped)
        for alias in aliases {
            let aliasDir = root + "/" + alias
            let saved = config.devices[alias] != nil
            let busy = DeviceRemove.refusal(ledger.slots, alias: alias, now: now) != nil
            var found = 0
            for app in folders(in: aliasDir, root: root, links: &plan.counts.linksSkipped) {
                let appDir = aliasDir + "/" + app
                let entries = folders(in: appDir, root: root, links: &plan.counts.linksSkipped)
                found += entries.count
                if busy {
                    plan.counts.kept += entries.count
                    continue
                }
                let context = Context(
                    services: services, saved: saved,
                    pending: saved ? pendingDirectory(services, config: config, alias: alias, app: app) : nil, cutoff: cutoff)
                for name in entries {
                    decide(appDir + "/" + name, partial: name.hasSuffix(".partial"), context, plan: &plan)
                }
            }
            if busy && found > 0 { plan.counts.devicesSkippedBusy += 1 }
        }
        return plan
    }

    private static func decide(_ directory: String, partial: Bool, _ context: Context, plan: inout Plan) {
        let (saved, pending, cutoff) = (context.saved, context.pending, context.cutoff)
        func doom(_ reason: Reason) {
            plan.doomed.append(Doomed(directory: directory, reason: reason))
            plan.counts.deleted += 1
            plan.counts.byReason[reason, default: 0] += 1
        }
        let root = context.services.home.backups
        if partial {
            // Nothing writes one while the lock is held, so any left is abandoned; the age keeps the rule as cautious as the rest.
            if let stamp = modified(directory), stamp < cutoff { doom(.partial) } else { plan.counts.kept += 1 }
            return
        }
        guard AppDataBackup.isPlain(directory + "/manifest.json", root: root, regularFile: true),
            let manifest = AppDataBackup.readManifest(in: directory)
        else {
            plan.counts.unreadable += 1
            return
        }
        if saved {
            // A backup `slot restore` would still push is never touched. It has neither marker, which the rule below needs,
            // so this is a second guard rather than the only one.
            var markers: [(Date, Reason)] = []
            if let at = manifest.restoredAt { markers.append((at, .restored)) }
            if let at = manifest.supersededAt { markers.append((at, .superseded)) }
            guard directory != pending, let latest = markers.max(by: { $0.0 < $1.0 }), latest.0 < cutoff else {
                plan.counts.kept += 1
                return
            }
            doom(latest.1)
        } else {
            let newest = [manifest.createdAt, manifest.restoredAt, manifest.supersededAt, manifest.uninstalledAt].compactMap { $0 }.max()
                ?? manifest.createdAt
            if newest < cutoff { doom(.unsavedAlias) } else { plan.counts.kept += 1 }
        }
    }

    /// The folder `slot restore` would restore from for this device and app (`AppDataBackup.pending`), when it can be asked: a
    /// known free app and a valid bundle ID prefix.
    private static func pendingDirectory(_ services: Services, config: Config, alias: String, app: String) -> String? {
        guard let prefix = config.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix),
            Config.isFreeBundleId(prefix + ".free.x", prefix: prefix),
            let known = ProvisionApp.allCases.first(where: { $0.rawValue == app })
        else { return nil }
        if case .found(let directory, _) = AppDataBackup.pending(services, alias: alias, app: app, bundleId: prefix + ".free." + known.suffix) {
            return directory
        }
        return nil
    }

    // MARK: apply

    /// Deletes the plan's folders and returns the counts as they ended. A folder whose chain is no longer plain, or that cannot be
    /// removed, is `failed` and not `deleted`. Empty app and alias folders left behind are removed (`rmdir`, never recursive).
    static func apply(_ plan: Plan, services: Services) -> Counts {
        var counts = plan.counts
        let root = services.home.backups
        var parents = Set<String>()
        for item in plan.doomed {
            if CleanCommand.removePlainFolder(item.directory, root: root) {
                parents.insert(parentPath(item.directory))
            } else {
                counts.deleted -= 1
                counts.failed += 1
                counts.byReason[item.reason, default: 0] -= 1
            }
        }
        for appDir in parents {
            for dir in [appDir, parentPath(appDir)] where AppDataBackup.isPlain(dir, root: root, regularFile: false) && dir != root {
                rmdir(dir)
            }
        }
        return counts
    }

    // MARK: reading

    /// The names of the real, non-hidden folders directly inside `directory`, sorted. Counts a link met (the folder itself or an
    /// entry) in `links`. Nothing inside is opened.
    private static func folders(in directory: String, root: String, links: inout Int) -> [String] {
        if DeviceRemove.isLink(directory) {
            links += 1
            return []
        }
        guard AppDataBackup.isPlain(directory, root: root, regularFile: false) else { return [] }
        var found: [String] = []
        for name in DeviceRemove.names(in: directory) where !name.hasPrefix(".") {
            let path = directory + "/" + name
            if DeviceRemove.isRealDirectory(path) {
                found.append(name)
            } else if DeviceRemove.isLink(path) {
                links += 1
            }
        }
        return found
    }

    private static func modified(_ directory: String) -> Date? {
        var st = stat()
        guard lstat(directory, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
