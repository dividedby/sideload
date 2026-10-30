import Darwin
import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `clean` (owner-only with --yes; a preview without), against the temp homes of `InstallTestSupport`. Nothing here touches a
// device (the fake runner is never asked), the network or the real `$SIDELOAD_HOME`. Ages are counted against the world's clock
// (`testNow`); folder times are set with `utimes`, never read from the real clock.

private let sentinel = "SENTINEL-SESSION-TOKEN-c1ea"
private let secretName = "secret-file-name-77f3.json"
private let prefs = "Library/Preferences/io.github.dividedby.free.stremio.plist"

// MARK: laying files

private func write(_ text: String, to path: String) throws {
    try makeDirectories((path as NSString).deletingLastPathComponent, mode: 0o700)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private extension InstallWorld {
    /// One finished backup. `created` defaults to 90 days ago, so only the markers decide for a saved device.
    @discardableResult
    func backup(
        _ alias: String = "iphone", app: String = "stremio-ios", stamp: String, created: Double = -90, restored: Double? = nil,
        superseded: Double? = nil, uninstalled: Double? = -90, manifest: Bool = true
    ) throws -> String {
        let directory = "\(paths.backups)/\(alias)/\(app)/\(stamp)"
        try write(sentinel, to: "\(directory)/data/\(secretName)")
        if manifest {
            let suffix = ProvisionApp.allCases.first { $0.rawValue == app }?.suffix ?? app
            let record = AppDataBackup.Manifest(
                bundleId: carrierPrefix + ".free." + suffix, version: "1.2.3", lendSince: daysFromNow(created),
                createdAt: daysFromNow(created), complete: true, files: [], restoredAt: restored.map(daysFromNow),
                supersededAt: superseded.map(daysFromNow), uninstalledAt: uninstalled.map(daysFromNow))
            try encoder.encode(record).write(to: URL(fileURLWithPath: directory + "/manifest.json"))
        }
        return directory
    }

    func names(_ alias: String = "iphone", app: String = "stremio-ios") -> [String] {
        listing("\(paths.backups)/\(alias)/\(app)").sorted()
    }

    func clean(yes: Bool = false) -> Envelope { CleanCommand.run(services, CleanOptions(yes: yes)) }

    /// A manifest of entries, and a folder with a file of `bytes` bytes for each unless `files` is false.
    func downloads(_ entries: [ManifestEntry], bytes: Int = 100, files: Bool = true) throws {
        var manifest = Manifest()
        manifest.entries = entries
        try ManifestStore(paths: paths).save(manifest)
        guard files else { return }
        for entry in entries {
            try write(String(repeating: "x", count: bytes), to: "\(paths.downloads)/\(entry.file)")
        }
    }

    func manifest() throws -> Manifest { try ManifestStore(paths: paths).load() }
    func downloadFolder(_ app: String, _ version: String) -> String { "\(paths.downloads)/\(app)/\(version)" }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

private func entry(_ app: String, _ version: String, approved: Bool, days: Double, prunedAt: Date? = nil) -> ManifestEntry {
    ManifestEntry(
        app: app, version: version, file: "\(app)/\(version)/Apollo.ipa", urlHost: "example.test",
        sha256: String(repeating: "ab", count: 32), upstreamDigest: String(repeating: "ab", count: 32), size: 100,
        fetchedAt: daysFromNow(days), approved: approved, approvedAt: approved ? daysFromNow(days) : nil, build: "1",
        declaredSize: 100, minOS: nil, inspectMinOS: "15.0", prunedAt: prunedAt)
}

private func fileTree(_ root: String) -> [String: Data?] {
    var result: [String: Data?] = [:]
    for path in (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? [] {
        var st = stat()
        let isFile = lstat(root + "/" + path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
        result[path] = isFile ? (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + path))) : nil
    }
    return result
}

/// Everything `clean` may change.
private struct Snapshot: Equatable {
    var backups: [String: Data?]
    var downloads: [String: Data?]
    var manifest: Data?

    init(_ w: InstallWorld) {
        backups = fileTree(w.paths.backups)
        downloads = fileTree(w.paths.downloads)
        manifest = try? Data(contentsOf: URL(fileURLWithPath: w.paths.manifest))
    }
}

private func number(_ out: Envelope, _ section: String, _ key: String) -> JSONValue? { json(out)[section]?[key] }

private func warningCodes(_ out: Envelope) -> [String] {
    (json(out)["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
}

private func lend(_ ledger: inout Ledger, alias: String = "iphone", app: String = "stremio-ios") {
    ledger.slots = [LedgerSlot(device: alias, app: app, presence: .absent, lentTo: "lab", since: testNow)]
    ledger.installs.removeAll { $0.id == "\(alias)/\(app)" }
    SlotRule.project(&ledger)
}

// MARK: backups

@Suite("clean: backups")
struct CleanBackupsTests {
    @Test("a saved device: 14 days from the restored or superseded marker, counted from the marker and not from createdAt")
    func retentionBoundaries() async throws {
        try await withInstallWorld { w in
            try w.backup(stamp: "20260101T000001Z", restored: -13)  // kept
            try w.backup(stamp: "20260101T000002Z", restored: -15)  // deleted
            try w.backup(stamp: "20260101T000003Z", superseded: -13)  // kept
            try w.backup(stamp: "20260101T000004Z", superseded: -15)  // deleted
            try w.backup(stamp: "20260101T000005Z", restored: -14)  // exactly 14 days: not "more than"
            try w.backup(stamp: "20260101T000010Z", restored: -14 - 1.0 / 86_400)  // 14 days and a second: deleted
            try w.backup(stamp: "20260101T000006Z", created: -60, restored: -1)  // old backup, recent restore: kept
            try w.backup(stamp: "20260101T000007Z", created: -1, restored: -15)  // new backup, old marker: deleted
            try w.backup(stamp: "20260101T000008Z", restored: -20, superseded: -2)  // the later marker counts: kept
            try w.backup(stamp: "20260101T000009Z", created: -90, uninstalled: -90)  // neither marker: kept
            let out = w.clean(yes: true)
            #expect(out.ok && out.exitCode == 0, "\(out.errors)")
            #expect(w.names() == [1, 3, 5, 6, 8, 9].map { "20260101T00000\($0)Z" })
            #expect(number(out, "backups", "deleted") == 4 && number(out, "backups", "kept") == 6)
            #expect(json(out)["backups"]?["byReason"] == ["restored": 3, "superseded": 1, "unsavedAlias": 0, "partial": 0])
            #expect(number(out, "backups", "unreadable") == 0 && number(out, "backups", "devicesSkippedBusy") == 0)
            #expect(json(out)["dryRun"] == false && json(out)["command"] == "clean")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("a backup slot restore would still push is kept, and an older superseded one of the same app is not")
    func pendingRestoreKept() async throws {
        var script = DeviceScript(initial: [stremioId: true])
        script.container = [prefs: Data((sentinel + "prefs").utf8)]
        try await withInstallWorld(
            script: script, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }
        ) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok)
            var failing = script
            failing.dataFaults.copyToFails = [prefs]
            w.runner.arm(failing)
            let back = await w.slot("return", device: "iphone")
            #expect(back.ok && json(back)["dataRestored"] == false, "\(back.errors)")
            let pending = try #require(w.names().first)
            try w.backup(stamp: "20260101T000000Z", superseded: -30)
            w.clock.advance(20 * 86_400)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(w.names() == [pending], "only the pending one is left")
            #expect(number(out, "backups", "deleted") == 1 && number(out, "backups", "kept") == 1)
        }
    }

    @Test("a device the lab holds is skipped and counted, whole; another device is cleaned")
    func busyDevice() async throws {
        try await withInstallWorld(ledger: { lend(&$0) }) { w in
            try w.backup(stamp: "20260101T000000Z", restored: -20)
            try w.backup(stamp: "20260101T000001Z", restored: -20, manifest: false)
            try w.backup("appletv", app: "stremio-tvos", stamp: "20260101T000000Z", restored: -20)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(w.names().count == 2, "nothing of the lent device was touched")
            #expect(w.names("appletv", app: "stremio-tvos").isEmpty)
            #expect(number(out, "backups", "devicesSkippedBusy") == 1 && number(out, "backups", "deleted") == 1)
            #expect(number(out, "backups", "kept") == 2 && number(out, "backups", "unreadable") == 0)
            #expect(warningCodes(out) == ["DEVICE_BUSY_SKIPPED"])
        }
    }

    @Test("a device with an operation inside its window is skipped too, and cleaned once the window has passed")
    func operationInWindow() async throws {
        try await withInstallWorld(ledger: { ledger in
            let op = LedgerSlotOp(kind: .reinstall, by: .install, startedAt: testNow, window: SlotRule.window(.reinstall))
            ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .unknown, op: op)]
            SlotRule.project(&ledger)
        }) { w in
            try w.backup(stamp: "20260101T000000Z", restored: -20)
            let busy = w.clean(yes: true)
            #expect(number(busy, "backups", "devicesSkippedBusy") == 1 && w.names().count == 1)
            w.clock.advance(Double(SlotRule.window(.reinstall)) + 5)
            let later = w.clean(yes: true)
            #expect(number(later, "backups", "devicesSkippedBusy") == 0 && number(later, "backups", "deleted") == 1)
            #expect(w.names().isEmpty)
        }
    }

    @Test("an alias that is no longer saved: the newest of createdAt, restoredAt, supersededAt and uninstalledAt decides, and emptied folders go")
    func unsavedAlias() async throws {
        try await withInstallWorld { w in
            try w.backup("oldphone", stamp: "20260101T000001Z", created: -13)  // kept
            try w.backup("oldphone", stamp: "20260101T000002Z", created: -15)  // deleted
            try w.backup("oldphone", stamp: "20260101T000003Z", created: -20, uninstalled: -20)  // waiting for a restore that cannot run: deleted
            try w.backup("oldphone", stamp: "20260101T000004Z", created: -40, superseded: -2)  // kept
            try w.backup("oldphone", stamp: "20260101T000005Z", created: -40, restored: -3)  // kept
            try w.backup("oldphone", stamp: "20260101T000006Z", created: -40, uninstalled: -2)  // uninstalledAt counts: kept
            try w.backup("gone", stamp: "20260101T000000Z", created: -30)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(w.names("oldphone") == [1, 4, 5, 6].map { "20260101T00000\($0)Z" })
            #expect(!w.exists(w.paths.backups + "/gone"), "the emptied app and alias folders are removed")
            #expect(w.exists(w.paths.backups + "/oldphone/stremio-ios") && w.exists(w.paths.backups))
            #expect(json(out)["backups"]?["byReason"] == ["restored": 0, "superseded": 0, "unsavedAlias": 3, "partial": 0])
            #expect(number(out, "backups", "deleted") == 3 && number(out, "backups", "kept") == 4)
        }
    }

    @Test("a saved device's backups are never judged by the unsaved rule")
    func savedIsNotUnsaved() async throws {
        try await withInstallWorld { w in
            try w.backup(stamp: "20260101T000000Z", created: -100)
            try w.backup("appletv", app: "stremio-tvos", stamp: "20260101T000000Z", created: -100)
            let out = w.clean(yes: true)
            #expect(number(out, "backups", "deleted") == 0 && number(out, "backups", "kept") == 2)
        }
    }

    @Test("a manifest that is missing, unreadable or a link is kept and counted, for a saved and for an unsaved alias")
    func unreadable() async throws {
        try await withInstallWorld { w in
            try w.backup(stamp: "20260101T000001Z", manifest: false)
            let garbage = try w.backup(stamp: "20260101T000002Z")
            try write("{ not json", to: garbage + "/manifest.json")
            let linked = try w.backup(stamp: "20260101T000003Z", restored: -30)
            let real = w.paths.home + "/elsewhere-manifest.json"
            try FileManager.default.moveItem(atPath: linked + "/manifest.json", toPath: real)
            try FileManager.default.createSymbolicLink(atPath: linked + "/manifest.json", withDestinationPath: real)
            try w.backup("oldphone", stamp: "20260101T000001Z", manifest: false)
            let before = Snapshot(w)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(Snapshot(w) == before)
            #expect(number(out, "backups", "unreadable") == 4 && number(out, "backups", "deleted") == 0)
            #expect(warningCodes(out) == ["BACKUPS_UNREADABLE"])
        }
    }

    @Test(".partial folders: deleted when more than 14 days old, kept when newer")
    func partials() async throws {
        try await withInstallWorld { w in
            let old = try w.backup(stamp: "20260101T000001Z.partial", manifest: false)
            let recent = try w.backup(stamp: "20260101T000002Z.partial", manifest: false)
            for (path, days) in [(old, -15.0), (recent, -13.0)] {
                let stamp = timeval(tv_sec: Int(daysFromNow(days).timeIntervalSince1970), tv_usec: 0)
                var times = [stamp, stamp]
                #expect(utimes(path, &times) == 0)
            }
            let out = w.clean(yes: true)
            #expect(out.ok && w.names() == ["20260101T000002Z.partial"], "\(out.errors)")
            #expect(json(out)["backups"]?["byReason"]?["partial"] == 1 && number(out, "backups", "unreadable") == 0)
        }
    }

    @Test("links are never followed: a linked alias, app or backup folder is left alone with what it points at")
    func symlinks() async throws {
        try await withInstallWorld { w in
            let target = w.paths.home + "/outside"
            try write("{}", to: target + "/stremio-ios/20260101T000000Z/keep.txt")
            try write(sentinel, to: target + "/stremio-ios/20260101T000000Z/data/\(secretName)")
            let record = AppDataBackup.Manifest(
                bundleId: carrierPrefix + ".free.stremio", version: "1", lendSince: daysFromNow(-90), createdAt: daysFromNow(-90),
                complete: true, files: [], restoredAt: daysFromNow(-60), supersededAt: nil, uninstalledAt: nil)
            try encoder.encode(record).write(to: URL(fileURLWithPath: target + "/stremio-ios/20260101T000000Z/manifest.json"))
            try w.backup(stamp: "20260101T000001Z", restored: -1)
            try makeDirectories(w.paths.backups + "/iphone", mode: 0o700)
            let links = [
                (w.paths.backups + "/ghostlink", target),
                (w.paths.backups + "/iphone/linkedapp", target + "/stremio-ios"),
                (w.paths.backups + "/iphone/stremio-ios/20250101T000000Z", target + "/stremio-ios/20260101T000000Z"),
            ]
            for (link, to) in links { try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: to) }
            let outside = fileTree(target)
            for yes in [false, true] {
                let out = w.clean(yes: yes)
                #expect(out.ok, "\(out.errors)")
                #expect(number(out, "backups", "linksSkipped") == 3 && number(out, "backups", "deleted") == 0)
                #expect(warningCodes(out) == ["LINKS_SKIPPED"])
                #expect(fileTree(target) == outside, "the targets are untouched")
                for (link, _) in links {
                    var st = stat()
                    #expect(lstat(link, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK, "the link itself stays")
                }
            }
        }
    }

    @Test("a linked backups folder is not entered")
    func linkedRoot() async throws {
        try await withInstallWorld { w in
            let elsewhere = w.paths.home + "/elsewhere"
            try write(sentinel, to: elsewhere + "/oldphone/stremio-ios/20260101T000000Z/manifest.json")
            try FileManager.default.createSymbolicLink(atPath: w.paths.backups, withDestinationPath: elsewhere)
            let before = fileTree(elsewhere)
            let out = w.clean(yes: true)
            #expect(out.ok && number(out, "backups", "linksSkipped") == 1 && fileTree(elsewhere) == before)
        }
    }
}

// MARK: downloads

@Suite("clean: downloads")
struct CleanDownloadsTests {
    private func set() -> [ManifestEntry] {
        [
            entry("apollo", "0.5", approved: false, days: -60),  // older unapproved: pruned
            entry("apollo", "1.0", approved: true, days: -50),  // pruned
            entry("apollo", "2.0", approved: true, days: -40),  // pruned
            entry("apollo", "3.0", approved: true, days: -30),  // the approved one before the newest: kept
            entry("apollo", "4.0", approved: true, days: -20),  // newest approved: kept
            entry("apollo", "5.0", approved: false, days: -5),  // newer than the newest approved, waiting: kept
            entry("apollo", "1.2.3", approved: true, days: -70),  // installed on another device: kept
            entry("stremio-ios", "s1", approved: false, days: -10),  // superseded unapproved: pruned
            entry("stremio-ios", "s2", approved: false, days: -5),  // nothing approved, the newest unapproved: kept
        ]
    }

    @Test("keeps what is installed anywhere, the newest two approved and the newest unapproved while it waits; marks and deletes the rest")
    func keepSet() async throws {
        try await withInstallWorld(ledger: { $0.installs = [installRecord(.apollo, alias: "appletv")] }) { w in
            let entries = set()
            try w.downloads(entries)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            for version in ["0.5", "1.0", "2.0"] { #expect(!w.exists(w.downloadFolder("apollo", version)), "\(version) pruned") }
            for version in ["3.0", "4.0", "5.0", "1.2.3"] { #expect(w.exists(w.downloadFolder("apollo", version)), "\(version) kept") }
            #expect(!w.exists(w.downloadFolder("stremio-ios", "s1")) && w.exists(w.downloadFolder("stremio-ios", "s2")))

            let manifest = try w.manifest()
            #expect(manifest.entries.count == entries.count, "every entry stays in the manifest")
            for kept in manifest.entries {
                let pruned = ["0.5", "1.0", "2.0", "s1"].contains(kept.version)
                #expect(kept.prunedAt == (pruned ? testNow : nil), "\(kept.version)")
                #expect(kept.sha256 == String(repeating: "ab", count: 32), "the record of the download is untouched")
            }
            #expect(number(out, "downloads", "versionsDeleted") == 4 && number(out, "downloads", "versionsKept") == 5)
            #expect(number(out, "downloads", "bytesFreed") == 400)
            #expect(json(out)["downloads"]?["apps"]?["apollo"] == ["versionsDeleted": 3, "versionsKept": 4, "bytesFreed": 300])
            #expect(json(out)["downloads"]?["apps"]?["stremio-ios"] == ["versionsDeleted": 1, "versionsKept": 1, "bytesFreed": 100])
        }
    }

    @Test("an unapproved version older than the newest approved one is pruned, not kept as waiting")
    func olderUnapproved() async throws {
        try await withInstallWorld { w in
            try w.downloads([
                entry("apollo", "1.0", approved: true, days: -20), entry("apollo", "0.9", approved: false, days: -30),
            ])
            let out = w.clean(yes: true)
            #expect(number(out, "downloads", "versionsDeleted") == 1)
            #expect(!w.exists(w.downloadFolder("apollo", "0.9")) && w.exists(w.downloadFolder("apollo", "1.0")))
        }
    }

    @Test("prunedAt is on disk before any folder goes; a run that died there is finished by a rerun, without re-marking")
    func markedBeforeDeleted() async throws {
        try await withInstallWorld { w in
            try w.downloads([
                entry("apollo", "1.0", approved: true, days: -50), entry("apollo", "2.0", approved: true, days: -40),
                entry("apollo", "3.0", approved: true, days: -30),
            ])
            struct Crash: Error {}
            let seen = Box<[String]>([])
            let stillThere = Box(false)
            let crashed = CleanCommand.run(w.services, CleanOptions(yes: true)) {
                seen.value = try ManifestStore(paths: w.paths).load().entries.filter { $0.prunedAt != nil }.map(\.version)
                stillThere.value = w.exists(w.downloadFolder("apollo", "1.0"))
                throw Crash()
            }
            #expect(!crashed.ok)
            #expect(seen.value == ["1.0"], "marked first")
            #expect(stillThere.value, "and the file was still there at that point")
            #expect(w.exists(w.downloadFolder("apollo", "1.0")), "a crash leaves a marked entry whose file may still exist")
            #expect(try w.manifest().entry(app: "apollo", version: "1.0")?.prunedAt == testNow)
            expectLockFree(w.paths)

            w.clock.advance(600)
            let rerun = w.clean(yes: true)
            #expect(rerun.ok && number(rerun, "downloads", "versionsDeleted") == 1, "\(rerun.errors)")
            #expect(!w.exists(w.downloadFolder("apollo", "1.0")))
            #expect(try w.manifest().entry(app: "apollo", version: "1.0")?.prunedAt == testNow, "the first mark stands")
            // Once it is done, a further run has nothing to do.
            #expect(number(w.clean(yes: true), "downloads", "versionsDeleted") == 0)
        }
    }

    @Test("a pruned entry whose folder is already gone is only marked, never counted as freed")
    func alreadyGone() async throws {
        try await withInstallWorld { w in
            try w.downloads(
                [entry("apollo", "1.0", approved: true, days: -50), entry("apollo", "2.0", approved: true, days: -40),
                 entry("apollo", "3.0", approved: true, days: -30)], files: false)
            let out = w.clean(yes: true)
            #expect(out.ok && number(out, "downloads", "versionsDeleted") == 0 && number(out, "downloads", "bytesFreed") == 0)
            #expect(json(out)["downloads"]?["versionsAlreadyGone"] == 1)
            #expect(try w.manifest().entry(app: "apollo", version: "1.0")?.prunedAt == testNow)
        }
    }

    @Test("a folder behind a link is left alone and its entry is not marked")
    func linkedFolder() async throws {
        try await withInstallWorld { w in
            try w.downloads([
                entry("apollo", "1.0", approved: true, days: -50), entry("apollo", "2.0", approved: true, days: -40),
                entry("apollo", "3.0", approved: true, days: -30),
            ])
            let real = w.paths.home + "/moved"
            try FileManager.default.moveItem(atPath: w.downloadFolder("apollo", "1.0"), toPath: real)
            try FileManager.default.createSymbolicLink(atPath: w.downloadFolder("apollo", "1.0"), withDestinationPath: real)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(w.exists(real + "/Apollo.ipa"), "what the link points at is untouched")
            #expect(try w.manifest().entry(app: "apollo", version: "1.0")?.prunedAt == nil)
            #expect(warningCodes(out) == ["LINKS_SKIPPED"])
        }
    }

    @Test("builds, tmp, profiles and secrets are out of scope")
    func outOfScope() async throws {
        try await withInstallWorld { w in
            try w.downloads([
                entry("apollo", "1.0", approved: true, days: -50), entry("apollo", "2.0", approved: true, days: -40),
                entry("apollo", "3.0", approved: true, days: -30),
            ])
            let renewed = w.paths.tmp + "/renewed-profile-1/old.mobileprovision"
            try write("p", to: renewed)
            try write("s", to: w.paths.secrets + "/p12/x.p12")
            try write("b", to: w.paths.builds + "/signed/old/thing")
            try write("p", to: w.paths.freeProfiles + "/apollo/iphone/x.mobileprovision")
            let before = ["tmp", "secrets", "builds", "profiles"].map { fileTree(w.paths.home + "/" + $0) }
            _ = w.clean(yes: true)
            #expect(["tmp", "secrets", "builds", "profiles"].map { fileTree(w.paths.home + "/" + $0) } == before)
        }
    }
}

// MARK: pruned entries elsewhere

@Suite("clean: pruned entries in sign, refresh and fetch")
struct CleanPrunedEntryTests {
    @Test("sign refuses a pruned version, with the file gone or still there, and names fetch")
    func signRefuses() async throws {
        try await withSignWorld { w in
            let store = ManifestStore(paths: w.paths)
            var manifest = try store.load()
            manifest.entries[0].prunedAt = testNow
            try store.save(manifest)
            let still = await w.run()
            #expect(still.errors.first?.code == "IPA_PRUNED")
            #expect(still.errors.first?.fix?.contains("sideload fetch --app") == true)
            let version = manifest.entries[0].version
            #expect(await w.run(version: version).errors.first?.code == "IPA_PRUNED")

            try FileManager.default.removeItem(atPath: try store.path(of: manifest.entries[0]))
            #expect(await w.run().errors.first?.code == "IPA_PRUNED")
        }
    }

    @Test("a pruned entry is not on disk for refresh, even if the file is still there")
    func hasFile() async throws {
        try await withInstallWorld { w in
            try w.downloads([entry("apollo", "1.0", approved: true, days: -5)])
            let store = ManifestStore(paths: w.paths)
            var manifest = try w.manifest()
            #expect(store.hasFile(manifest.entries[0]))
            manifest.entries[0].prunedAt = testNow
            #expect(!store.hasFile(manifest.entries[0]))
            // The field survives the manifest file, and an old manifest without it reads as not pruned.
            try store.save(manifest)
            #expect(try w.manifest().entries[0].prunedAt == testNow)
            manifest.entries[0].prunedAt = nil
            try store.save(manifest)
            #expect(!String(decoding: try Data(contentsOf: URL(fileURLWithPath: w.paths.manifest)), as: UTF8.self).contains("prunedAt"))
            #expect(try w.manifest().entries[0].prunedAt == nil)
        }
    }

    @Test("the menu's Add app / Update confirm stops on a pruned entry instead of approving it")
    func menuStops() async throws {
        try await withInstallWorld { w in
            try w.downloads([entry("apollo", "1.0", approved: false, days: -5)])
            let fetched = MenuFetched(
                version: "1.0", build: nil, sha256: String(repeating: "ab", count: 32), size: 100, minOS: nil, extensionCount: 0,
                alreadyApproved: false)
            #expect(MenuActionRunner.addStop(app: "apollo", fetched: fetched, services: w.services) == nil)
            let store = ManifestStore(paths: w.paths)
            var manifest = try w.manifest()
            manifest.entries[0].prunedAt = testNow
            try store.save(manifest)
            #expect(MenuActionRunner.addStop(app: "apollo", fetched: fetched, services: w.services)?.contains("Fetch it again") == true)
        }
    }

    @Test("a later fetch of the same version stores the file again, clears prunedAt and keeps the approval; approving a pruned one says so")
    func fetchClears() async throws {
        let ipa = try await SampleIPAs.shared.data("plain")
        try await withTestHome(config: Config(approvedSources: apolloApproved)) { paths, _ in
            let transport = apolloTransport(ipa: ipa)
            let services = fetchServices(paths, http: transport, runner: RecordingRunner())
            func fetch(_ options: FetchOptions) async -> Envelope {
                await FetchCommand.run(services, options, registry: ScratchRegistry())
            }
            #expect(await fetch(FetchOptions(app: "apollo")).ok)
            #expect(await fetch(FetchOptions(app: "apollo", approve: true, version: "3.9.0")).ok)
            let store = ManifestStore(paths: paths)
            var manifest = try store.load()
            let original = manifest.entries[0]
            let folder = paths.downloads + "/apollo/3.9.0"

            // The state a crashed `clean` leaves: marked, file still there. Fetch does not trust it.
            manifest.entries[0].prunedAt = testNow
            try store.save(manifest)
            #expect(await fetch(FetchOptions(app: "apollo", approve: true, version: "3.9.0")).firstCode == "IPA_PRUNED")

            try FileManager.default.removeItem(atPath: folder)
            let again = await fetch(FetchOptions(app: "apollo"))
            #expect(again.ok, "\(again.errors)")
            #expect(try again.printed().json["downloaded"] == true, "it was downloaded again")
            let after = try #require(try store.load().entries.first)
            #expect(after.prunedAt == nil && after.sha256 == original.sha256, "the same file")
            #expect(after.approved && after.approvedAt == original.approvedAt, "approval carries over for the same SHA-256")
            #expect(FileManager.default.fileExists(atPath: folder + "/Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa"))
        }
    }
}

// MARK: preview, lock, output

@Suite("clean: preview, lock and output")
struct CleanRunTests {
    private func populate(_ w: InstallWorld) throws {
        try w.backup(stamp: "20260101T000001Z", restored: -20)
        try w.backup(stamp: "20260101T000002Z", superseded: -2)
        try w.backup("oldphone", stamp: "20260101T000001Z", created: -30)
        try w.backup(stamp: "20260101T000003Z", manifest: false)
        try w.downloads([
            entry("apollo", "1.0", approved: true, days: -50), entry("apollo", "2.0", approved: true, days: -40),
            entry("apollo", "3.0", approved: true, days: -30),
        ])
    }

    @Test("without --yes nothing is deleted or written, and the numbers are those a --yes run then produces")
    func preview() async throws {
        try await withInstallWorld { w in
            try populate(w)
            let before = Snapshot(w)
            let preview = w.clean()
            #expect(preview.ok && preview.exitCode == 0, "\(preview.errors)")
            #expect(json(preview)["dryRun"] == true && json(preview)["next"]?.string?.contains("clean --yes") == true)
            #expect(Snapshot(w) == before)
            #expect(w.runner.calls.isEmpty)
            expectLockFree(w.paths)

            let real = w.clean(yes: true)
            #expect(json(real)["dryRun"] == false && Snapshot(w) != before)
            for key in ["backups", "downloads"] { #expect(json(preview)[key] == json(real)[key], "\(key)") }
            #expect(number(preview, "backups", "deleted") == 2 && number(preview, "downloads", "versionsDeleted") == 1)
        }
    }

    @Test("a busy lock is OPERATION_IN_PROGRESS for the preview and for --yes; nothing is changed and the lock is not touched")
    func busyLock() async throws {
        try await withInstallWorld { w in
            try populate(w)
            let before = Snapshot(w)
            let held = try OperationLock.acquire(paths: w.paths)
            for yes in [false, true] {
                let out = w.clean(yes: yes)
                #expect(out.errorCodes == ["OPERATION_IN_PROGRESS"] && out.exitCode == 1)
            }
            #expect(Snapshot(w) == before)
            held.release()
            #expect(w.clean(yes: true).ok, "the lock file was not deleted or broken")
            expectLockFree(w.paths)
        }
    }

    @Test("the output holds no path, folder or file name, and nothing from a backup")
    func noPathsOrNames() async throws {
        try await withInstallWorld { w in
            try populate(w)
            try w.backup(stamp: "20260101T000004Z.partial", manifest: false)
            let lines = Box<[String]>([])
            var services = w.services
            services.log = { line in lines.value.append(line) }
            for yes in [false, true] {
                let out = CleanCommand.run(services, CleanOptions(yes: yes))
                #expect(out.ok, "\(out.errors)")
                let raw = String(decoding: try JSONEncoder().encode(out), as: UTF8.self)
                let text = raw + (try out.printed().text) + lines.value.joined(separator: "\n")
                let home = URL(fileURLWithPath: w.paths.home).lastPathComponent
                for secret in [
                    w.paths.home, home, sentinel, secretName, "20260101T", ".partial", "manifest.json", "oldphone", "/backups", "/downloads",
                    ".ipa", "Apollo.ipa", prefs, "Preferences",
                ] {
                    #expect(!text.contains(secret), "\(secret) leaked (yes \(yes))")
                }
                try w.expectClean(out)
            }
            #expect(!lines.value.isEmpty && lines.value.allSatisfy { $0.hasPrefix("clean:") })
        }
    }

    @Test("a deletion that cannot be done is CLEAN_INCOMPLETE with the counts, and the rest is still cleaned")
    func incomplete() async throws {
        try await withInstallWorld { w in
            let locked = try w.backup(stamp: "20260101T000001Z", restored: -20)
            try w.backup(stamp: "20260101T000002Z", restored: -20)
            // A folder inside the backup whose parent cannot be written makes the removal fail.
            let inner = locked + "/data"
            #expect(chmod(inner, 0o500) == 0)
            defer { chmod(inner, 0o700) }
            let out = w.clean(yes: true)
            #expect(out.errorCodes == ["CLEAN_INCOMPLETE"] && out.exitCode == 1)
            #expect(number(out, "backups", "failed") == 1 && number(out, "backups", "deleted") == 1)
        }
    }

    @Test("the CLI lists clean as built, runs it with and without --yes, and rejects other arguments")
    func wiring() async throws {
        try await withInstallWorld { w in
            try populate(w)
            let help = await run(argv: ["help"], services: w.services)
            #expect(help.data["built"]?.array?.contains("clean") == true && help.data["commands"]?.array?.contains("clean") == true)
            #expect(help.data["commands"]?.array?.count == 17, "clean is the seventeenth command")
            #expect(help.data["usage"]?.array?.contains { $0.string == "clean [--yes]" } == true)

            let before = Snapshot(w)
            let preview = await run(argv: ["clean"], services: w.services)
            #expect(preview.command == "clean" && preview.ok && json(preview)["dryRun"] == true && Snapshot(w) == before)
            #expect(await run(argv: ["clean", "extra"], services: w.services).errorCodes == ["USAGE"])
            #expect(await run(argv: ["clean", "--device", "iphone"], services: w.services).errorCodes == ["USAGE"])
            #expect(await run(argv: ["clean", "--force"], services: w.services).errorCodes == ["USAGE"])
            #expect(Snapshot(w) == before)
            let real = await run(argv: ["clean", "--yes"], services: w.services)
            #expect(real.ok && json(real)["dryRun"] == false && Snapshot(w) != before)
        }
    }
}
