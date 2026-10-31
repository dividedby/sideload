import Darwin
import Foundation

/// The IPA half of `clean`: which `downloads/<app>/<version>/` folders are no longer needed. `manifest.json` keeps every entry
/// (the record of what was downloaded, with its SHA-256); the entry is marked `prunedAt` and its folder goes.
///
/// Per app, these versions stay: every version `installs[]` records for the app (on any device, present or not), the newest
/// approved version (`ManifestEntry.older` order, as `sign` picks it), the approved version before it, and the single newest
/// unapproved one while it is newer than the newest approved (it waits for the owner's approval; with nothing approved it is
/// the newest unapproved). Every other version is pruned: older approved ones, older unapproved ones, and an unapproved one
/// that a newer fetch has superseded.
enum CleanDownloads {
    struct AppCounts: Equatable {
        var deleted = 0
        var kept = 0
        var bytesFreed: Int64 = 0

        var json: JSONValue {
            .object([
                "versionsDeleted": .number(Double(deleted)), "versionsKept": .number(Double(kept)),
                "bytesFreed": .number(Double(bytesFreed)),
            ])
        }
    }

    struct Mark: Equatable {
        var app: String
        var version: String
    }

    struct Folder: Equatable {
        var app: String
        var path: String
        var bytes: Int64
    }

    struct Plan: Equatable {
        var apps: [String: AppCounts] = [:]
        /// Entries to mark `prunedAt` (not yet marked), as (app, version).
        var marks: [Mark] = []
        /// Folders to delete, including those of entries a crashed run already marked.
        var folders: [Folder] = []
        /// Pruned entries whose folder was already gone (they are only marked).
        var alreadyGone = 0
        /// Folders behind a link, and entries whose file path is not `<app>/<version>/<name>`: left alone, never marked.
        var skipped = 0
        var failed = 0

        var json: [String: JSONValue] {
            [
                "versionsDeleted": .number(Double(deleted)), "versionsKept": .number(Double(kept)),
                "bytesFreed": .number(Double(bytesFreed)), "versionsAlreadyGone": .number(Double(alreadyGone)),
                "skipped": .number(Double(skipped)), "failed": .number(Double(failed)),
                "apps": .object(apps.mapValues(\.json)),
            ]
        }

        var deleted: Int { apps.values.reduce(0) { $0 + $1.deleted } }
        var kept: Int { apps.values.reduce(0) { $0 + $1.kept } }
        var bytesFreed: Int64 { apps.values.reduce(0) { $0 + $1.bytesFreed } }
    }

    // MARK: plan

    /// Read-only.
    static func plan(_ services: Services, manifest: Manifest, ledger: Ledger) -> Plan {
        var plan = Plan()
        let store = ManifestStore(paths: services.home)
        let downloads = services.home.downloads
        for app in Set(manifest.entries.map(\.app)).sorted() {
            let entries = manifest.entries.filter { $0.app == app }
            let keep = keepSet(entries, installed: Set(ledger.installs.filter { $0.app == app }.map(\.version)))
            var counts = AppCounts()
            for entry in entries {
                if keep.contains(entry.version) {
                    if entry.prunedAt == nil { counts.kept += 1 }
                    continue
                }
                guard (try? store.path(of: entry)) != nil else {
                    plan.skipped += 1
                    continue
                }
                let folder = downloads + "/" + entry.app + "/" + entry.version
                var st = stat()
                if lstat(folder, &st) != 0 {
                    // Gone by hand (or never there): the mark is all that is left to do. Nothing is deleted.
                    if errno == ENOENT {
                        if entry.prunedAt == nil {
                            plan.marks.append(Mark(app: entry.app, version: entry.version))
                            plan.alreadyGone += 1
                        }
                    } else {
                        plan.skipped += 1
                    }
                    continue
                }
                guard st.st_mode & S_IFMT == S_IFDIR, AppDataBackup.isPlain(folder, root: downloads, regularFile: false) else {
                    plan.skipped += 1
                    continue
                }
                let bytes = treeBytes(folder)
                if entry.prunedAt == nil { plan.marks.append(Mark(app: entry.app, version: entry.version)) }
                plan.folders.append(Folder(app: entry.app, path: folder, bytes: bytes))
                counts.deleted += 1
                counts.bytesFreed += bytes
            }
            if counts != AppCounts() { plan.apps[app] = counts }
        }
        return plan
    }

    /// The versions of one app that stay.
    static func keepSet(_ entries: [ManifestEntry], installed: Set<String>) -> Set<String> {
        var keep = installed
        let approved = entries.filter(\.approved).sorted { ManifestEntry.older($1, $0) }
        for entry in approved.prefix(2) { keep.insert(entry.version) }
        if let waiting = entries.filter({ !$0.approved }).max(by: ManifestEntry.older),
            approved.first.map({ ManifestEntry.older($0, waiting) }) ?? true
        {
            keep.insert(waiting.version)
        }
        return keep
    }

    // MARK: apply

    /// The manifest with `prunedAt` set on the plan's marks.
    static func marked(_ manifest: Manifest, plan: Plan, at now: Date) -> Manifest {
        var copy = manifest
        for mark in plan.marks {
            guard let index = copy.entries.firstIndex(where: { $0.app == mark.app && $0.version == mark.version }) else { continue }
            copy.entries[index].prunedAt = now
        }
        return copy
    }

    /// Deletes the plan's folders (after the marks are on disk). A folder whose chain is no longer plain, or that cannot be removed,
    /// is `failed` and not `deleted`; its entry stays marked, and a rerun finishes it.
    static func apply(_ plan: Plan, services: Services) -> Plan {
        var result = plan
        let downloads = services.home.downloads
        for folder in plan.folders {
            if !CleanCommand.removePlainFolder(folder.path, root: downloads) {
                result.failed += 1
                result.apps[folder.app]?.deleted -= 1
                result.apps[folder.app]?.bytesFreed -= folder.bytes
            }
        }
        return result
    }

    // MARK: reading

    /// Bytes of the regular files under `path`, without following a link.
    private static func treeBytes(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return Int64(st.st_size)
        case S_IFDIR:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return names.reduce(0) { $0 + treeBytes(path + "/" + $1) }
        default: return 0
        }
    }
}
