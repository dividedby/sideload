import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Lend-time backup and return-time restore of the lent app's data (docs/design.md section 18, "App data"), against the
// simulated device of `InstallTestSupport`: its container, its `info files` / `copy from` / `copy to`.

private let sentinel = "SENTINEL-SESSION-TOKEN-7c41"
private let prefs = "Library/Preferences/io.github.dividedby.free.stremio.plist"
private let library = "Documents/library-9b2e.json"

private func data(_ text: String) -> Data { Data((sentinel + text).utf8) }

private let container: [String: Data] = [
    prefs: data("prefs"), library: data("library"), "Library/Caches/img/thumb.bin": data("cache"), "tmp/scratch": data("tmp"),
]

private func script(_ faults: DataFaults = DataFaults(), files: [String: Data] = container) -> DeviceScript {
    var script = DeviceScript(initial: [stremioId: true])
    script.container = files
    script.dataFaults = faults
    return script
}

private func warningCodes(_ out: Envelope) -> [String] {
    (json(out)["warnings"]?.array ?? []).compactMap { $0["code"]?.string }.filter { $0.hasPrefix("DATA_") }
}

private func prepare(_ ledger: inout Ledger) { ledger.installs = [installRecord(.stremioIOS)] }

private extension InstallWorld {
    var appBackups: String { paths.backups + "/iphone/stremio-ios" }
    var backupNames: [String] { listing(appBackups).sorted() }
    var finishedBackups: [String] { backupNames.filter { !$0.hasSuffix(".partial") } }
    func manifest(_ name: String) throws -> AppDataBackup.Manifest {
        let raw = try Data(contentsOf: URL(fileURLWithPath: "\(appBackups)/\(name)/manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppDataBackup.Manifest.self, from: raw)
    }
    func lend() async -> Envelope { await slot("lend", device: "iphone", to: "lab") }
    func giveBack() async -> Envelope { await slot("return", device: "iphone") }
    var dataWords: [String] { runner.dataCalls.map { DeviceSimRunner.words($0) } }
}

@Suite("app data backup and restore")
struct AppDataBackupTests {
    // MARK: lend

    @Test("lend backs up the data before the intent and the uninstall: files copied, caches and tmp skipped, counts only in the output")
    func lendBacksUp() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let seen = Mutex<[String]>([])
            let services = w.services
            let watched = DeviceSimRunnerWatch(inner: w.runner) { spec in
                seen.withLock { $0.append(DeviceSimRunner.words(spec)) }
            }
            var withWatch = services
            withWatch.runner = watched
            withWatch.afterDurableWrite = { point in seen.withLock { $0.append("write:" + point) } }
            let out = await SlotCommand.run(withWatch, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
            let order = seen.withLock { $0 }
            #expect(out.ok, "\(out.errors)")
            let printed = json(out)
            #expect(printed["dataBackedUp"] == true && printed["dataFiles"] == 2 && printed["dataFilesFailed"] == 0)
            #expect(printed["dataBackupSkipped"] == nil && printed["freed"] == 1)
            #expect(warningCodes(out).isEmpty, "a clean backup warns about nothing")
            let backup = try #require(order.firstIndex(of: "device copy from"))
            #expect(order.firstIndex(of: "device info files")! < backup)
            #expect(backup < order.firstIndex(of: "write:lend.intent")!, "the backup precedes the durable intent")
            #expect(order.firstIndex(of: "write:lend.intent")! < order.firstIndex(of: "device uninstall app")!)
            #expect(w.dataWords == ["device info files", "device copy from", "device copy from"])
            // On disk: the two files (not the caches), a finished folder, no leftovers.
            let name = try #require(w.finishedBackups.first)
            #expect(w.backupNames == [name])
            let base = "\(w.appBackups)/\(name)/data/"
            #expect(try Data(contentsOf: URL(fileURLWithPath: base + library)) == container[library])
            #expect(try Data(contentsOf: URL(fileURLWithPath: base + prefs)) == container[prefs])
            #expect(!FileManager.default.fileExists(atPath: base + "Library/Caches") && !FileManager.default.fileExists(atPath: base + "tmp"))
            let manifest = try w.manifest(name)
            #expect(manifest.bundleId == w.bundleId && manifest.version == "1.2.3" && manifest.complete)
            #expect(manifest.lendSince == testNow && manifest.restoredAt == nil)
            #expect(manifest.files.map(\.path).sorted() == [library, prefs].sorted())
            #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
            let l0 = try w.ledger()
            #expect(l0.lent == [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: testNow)])
            try w.expectClean(out)
        }
    }

    @Test("backups are secrets-class: dirs 0700, files 0600, and no content, file name or path reaches the output, the log or the ledger")
    func secretsClass() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let lines = Mutex<[String]>([])
            var services = w.services
            services.log = { line in lines.withLock { $0.append(line) } }
            let lend = await SlotCommand.run(services, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
            let back = await SlotCommand.run(services, SlotOptions(sub: "return", device: "iphone"))
            #expect(lend.ok && back.ok)
            // Modes.
            let name = try #require(w.finishedBackups.first)
            let root = "\(w.appBackups)/\(name)"
            for dir in [w.paths.backups, w.paths.backups + "/iphone", w.appBackups, root, root + "/data", root + "/data/Documents", root + "/data/Library/Preferences"] {
                #expect(modeOf(dir) == 0o700, "\(dir.dropFirst(w.paths.home.count)) is \(String(modeOf(dir), radix: 8))")
            }
            for file in [root + "/manifest.json", root + "/data/" + library, root + "/data/" + prefs] {
                #expect(modeOf(file) == 0o600, "\(file.dropFirst(w.paths.home.count)) is \(String(modeOf(file), radix: 8))")
            }
            // Nothing leaks: not the sentinel content, not a file name from the container, not the backup folder.
            var text = try lend.printed().text + (try back.printed().text) + lines.withLock { $0 }.joined(separator: "\n")
            text += String(decoding: try Data(contentsOf: URL(fileURLWithPath: w.paths.ledger)), as: UTF8.self)
            for secret in [sentinel, "library-9b2e", "Preferences", "Documents", "Library", "backups", "thumb", name] {
                #expect(!text.contains(secret), "\(secret) leaked")
            }
            // The only output keys added are counts and booleans.
            let added = ["dataBackedUp", "dataFiles", "dataFilesFailed", "dataRestored", "dataFilesRestored"]
            for key in added {
                let value = json(lend)[key] ?? json(back)[key]
                switch value {
                case .bool?, .number?: break
                default: Issue.record("\(key) is not a bool or a count")
                }
            }
        }
    }

    @Test("a failed or partial backup never fails the lend: warnings, dataBackedUp reflects what was saved")
    func backupFailures() async throws {
        // The listing fails.
        try await withInstallWorld(script: script(DataFaults(listFails: true)), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1)
            #expect(json(out)["dataBackedUp"] == false && json(out)["dataFiles"] == 0)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.backupNames.isEmpty, "nothing, not even an empty folder")
            let l1 = try w.ledger()
            #expect(l1.lent.first?.state == "lent")
        }
        // The listing is not a listing (never an empty container).
        try await withInstallWorld(script: script(DataFaults(listMalformed: true)), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == false)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.dataWords == ["device info files"])
        }
        // Every copy fails.
        let all = DataFaults(copyFromFails: [prefs, library])
        try await withInstallWorld(script: script(all), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == false && json(out)["dataFilesFailed"] == 2)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.backupNames.isEmpty)
        }
        // One copy fails: the rest is kept.
        try await withInstallWorld(script: script(DataFaults(copyFromFails: [prefs])), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == true)
            #expect(json(out)["dataFiles"] == 1 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(!manifest.complete && manifest.files.map(\.path) == [library])
        }
    }

    @Test("a copy that exits 0 but reports a failed outcome is a failed copy, not a quiet empty file")
    func copyFromReportedFailure() async throws {
        // One file: counted failed, the rest kept, the backup incomplete; nothing is left at the destination.
        try await withInstallWorld(
            script: script(DataFaults(copyFromReportsFailed: [prefs])), lendable: "stremio-ios", ledger: prepare
        ) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == true)
            #expect(json(out)["dataFiles"] == 1 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(!manifest.complete && manifest.files.map(\.path) == [library])
        }
        // Every file: no backup, as with exit code 1.
        try await withInstallWorld(
            script: script(DataFaults(copyFromReportsFailed: [prefs, library])), lendable: "stremio-ios", ledger: prepare
        ) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == false && json(out)["dataFilesFailed"] == 2)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.backupNames.isEmpty)
        }
        // A reported success is still a success.
        try await withInstallWorld(
            script: script(DataFaults(copyFromReportsSuccess: [prefs, library])), lendable: "stremio-ios", ledger: prepare
        ) { w in
            let out = await w.lend()
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 2 && json(out)["dataFilesFailed"] == 0)
            #expect(warningCodes(out).isEmpty)
        }
    }

    @Test("a listing that exits 0 but reports a failed outcome is no listing")
    func listReportedFailure() async throws {
        try await withInstallWorld(script: script(DataFaults(listReportsFailed: true)), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == false && json(out)["dataFiles"] == 0)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.backupNames.isEmpty, "never taken for an empty container")
        }
    }

    @Test("an empty container is a complete backup of nothing")
    func emptyContainer() async throws {
        try await withInstallWorld(script: script(files: [:]), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 0 && warningCodes(out).isEmpty)
            let m2 = try w.manifest(try #require(w.finishedBackups.first))
            #expect(m2.files.isEmpty)
            let back = await w.giveBack()
            #expect(json(back)["dataRestored"] == true && json(back)["dataFilesRestored"] == 0)
            #expect(w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" }.isEmpty)
        }
    }

    @Test("a size that differs from the listing is retried once, then counted failed")
    func sizeMismatch() async throws {
        try await withInstallWorld(script: script(DataFaults(copyFromShort: [library])), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataFiles"] == 1 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let copies = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy from" }
            #expect(copies.filter { $0.args.contains(library) }.count == 2, "one retry")
            let name = try #require(w.finishedBackups.first)
            #expect(!FileManager.default.fileExists(atPath: "\(w.appBackups)/\(name)/data/\(library)"), "the short copy is not kept")
        }
    }

    @Test("the 120 s allowance is checked before every call and each copy is capped at what is left")
    func backupBudget() async throws {
        var files: [String: Data] = [:]
        for index in 1...4 { files["Documents/f\(index).json"] = data("\(index)") }
        try await withInstallWorld(script: script(DataFaults(callTakes: 50), files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1, "a spent allowance never blocks the lend")
            // list 50 s (70 left); copy 1 gets 30 s (20 left); copy 2 would get 20 - 23 s (the Runner's margin and worst-case
            // overrun) < 5 s, so it is not started.
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 1 && json(out)["dataFilesFailed"] == 3)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let timeouts = w.runner.dataCalls.map { spec in spec.args[spec.args.firstIndex(of: "--timeout")! + 1] }
            #expect(timeouts == ["60", "30"])
            #expect(w.dataWords.count == 2)
        }
    }

    @Test("more than 200 files: the first 200 are saved, the rest counted failed")
    func fileCap() async throws {
        var files: [String: Data] = [:]
        for index in 0..<203 { files[String(format: "Documents/f%03d.json", index)] = Data([UInt8(index % 251)]) }
        try await withInstallWorld(script: script(files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataFiles"] == 200 && json(out)["dataFilesFailed"] == 3)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
        }
    }

    @Test("apps.<app>.backupData false: no device data call, dataBackedUp false, skipped, no warning; return restores nothing")
    func optOut() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.store.update { $0.apps["stremio-ios"] = ["backupData": false] }
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == false && json(out)["dataBackupSkipped"] == true)
            #expect(json(out)["dataFiles"] == 0 && warningCodes(out).isEmpty)
            #expect(w.runner.dataCalls.isEmpty && !FileManager.default.fileExists(atPath: w.paths.backups))
            let back = await w.giveBack()
            #expect(back.ok && json(back)["dataRestored"] == false && warningCodes(back).isEmpty)
            #expect(w.runner.dataCalls.isEmpty)
        }
        // Anything but an explicit false backs up (also a wrong type).
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.store.update { $0.apps["stremio-ios"] = ["backupData": "no"] }
            #expect(json(await w.lend())["dataBackedUp"] == true)
        }
    }

    // MARK: return

    @Test("return restores after the confirmed install and before the success JSON; the container matches the backup")
    func returnRestores() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            #expect(w.runner.container(stremioId).isEmpty, "the uninstall deleted the app's data")
            let out = await w.giveBack()
            #expect(out.ok, "\(out.errors)")
            let printed = json(out)
            #expect(printed["reinstalled"] == true && printed["dataRestored"] == true)
            #expect(printed["dataFilesRestored"] == 2 && printed["dataFilesFailed"] == 0 && warningCodes(out).isEmpty)
            #expect(w.runner.container(stremioId) == [library: container[library]!, prefs: container[prefs]!])
            // Order on the device: install, then the pushes, then the relisting.
            let words = w.runner.calls.filter { $0.executable == "xcrun" }.map { DeviceSimRunner.words($0) }
            let install = try #require(words.firstIndex(of: "device install app"))
            let pushes = words.indices.filter { words[$0] == "device copy to" }
            #expect(pushes.count == 2 && pushes.allSatisfy { $0 > install })
            #expect(words.lastIndex(of: "device info files")! > pushes.last!, "relisted to compare")
            // The backup is marked restored, and kept.
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.restoredAt == testNow)
            let l3 = try w.ledger()
            #expect(l3.lent.isEmpty)
            try w.expectClean(out)
            // A second return is a no-op: nothing lent, no data call.
            let before = w.runner.dataCalls.count
            let again = await w.giveBack()
            #expect(json(again)["nothingLent"] == true && w.runner.dataCalls.count == before)
        }
    }

    @Test("a restore that fails keeps the backup and the return still succeeds; nothing marks it restored")
    func restoreFailureKeepsBackup() async throws {
        var faults = DataFaults()
        faults.copyToFails = [prefs]
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(faults))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["reinstalled"] == true, "\(out.errors)")
            #expect(json(out)["dataRestored"] == false && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_RESTORE_INCOMPLETE"])
            let m4 = try w.manifest(try #require(w.finishedBackups.first))
            #expect(m4.restoredAt == nil)
            let l5 = try w.ledger()
            #expect(l5.lent.isEmpty, "the slot model is untouched")
            #expect(w.runner.deviceApps.keys.contains(stremioId))
        }
    }

    @Test("a push that exits 0 but reports a failed outcome is a failed push; the backup is kept")
    func pushReportedFailure() async throws {
        var faults = DataFaults()
        faults.copyToReportsFailed = [prefs]
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(faults))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["reinstalled"] == true, "\(out.errors)")
            #expect(json(out)["dataRestored"] == false && json(out)["dataFilesRestored"] == 1 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_RESTORE_INCOMPLETE"])
            #expect(w.runner.container(stremioId) == [library: container[library]!])
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.restoredAt == nil)
        }
    }

    @Test("a push the device drops, or a relisting that cannot be read, is not a verified restore")
    func restoreVerification() async throws {
        var drops = DataFaults()
        drops.copyToDrops = true
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(drops))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false && json(out)["dataFilesFailed"] == 2)
            #expect(warningCodes(out) == ["DATA_RESTORE_INCOMPLETE"])
            let m6 = try w.manifest(try #require(w.finishedBackups.first))
            #expect(m6.restoredAt == nil)
        }
        var unreadable = DataFaults()
        unreadable.listFailsOn = [2]  // the lend's listing is the first
        try await withInstallWorld(script: script(unreadable), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false)
            #expect(json(out)["dataFilesRestored"] == 2 && json(out)["dataFilesFailed"] == 0)
            #expect(warningCodes(out) == ["DATA_RESTORE_UNVERIFIED"])
            let m7 = try w.manifest(try #require(w.finishedBackups.first))
            #expect(m7.restoredAt == nil)
        }
    }

    @Test("a file changed on this Mac since the backup is not pushed")
    func tamperedBackup() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let name = try #require(w.finishedBackups.first)
            let file = "\(w.appBackups)/\(name)/data/\(library)"
            try Data("tampered".utf8).write(to: URL(fileURLWithPath: file))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_RESTORE_INCOMPLETE"])
            #expect(w.runner.container(stremioId).keys.sorted() == [prefs])
            #expect(!w.runner.dataCalls.contains { $0.args.contains(library) && DeviceSimRunner.words($0) == "device copy to" })
        }
    }

    @Test("a partial backup is restored (what was saved), with a warning")
    func partialRestore() async throws {
        try await withInstallWorld(script: script(DataFaults(copyFromFails: [prefs])), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let out = await w.giveBack()
            #expect(json(out)["dataRestored"] == true && json(out)["dataFilesRestored"] == 1)
            #expect(warningCodes(out) == ["DATA_RESTORE_PARTIAL_BACKUP"])
            #expect(w.runner.container(stremioId).keys.sorted() == [library])
        }
    }

    @Test("a return with no backup of this lend restores nothing and warns of nothing")
    func noBackup() async throws {
        try await withInstallWorld(script: script(DataFaults(listFails: true)), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false && json(out)["dataFilesRestored"] == 0)
            #expect(warningCodes(out).isEmpty)
            #expect(w.dataWords == ["device info files"], "only the lend's listing")
        }
    }

    // MARK: ties to the lend, crashes, retention

    @Test("a backup of an earlier lend is never restored after a later lend that saved nothing")
    func staleBackup() async throws {
        var failing = DataFaults()
        failing.copyToFails = [prefs, library]
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(failing))
            let first = await w.giveBack()  // its restore fails: the backup stays unrestored
            #expect(first.ok && json(first)["dataRestored"] == false)
            let m8 = try w.manifest(try #require(w.finishedBackups.first))
            #expect(m8.restoredAt == nil)
            // Later: lend again; this time the backup cannot be made.
            w.clock.advance(86_400)
            w.runner.arm(script(DataFaults(listFails: true)))
            #expect(await w.lend().ok)
            let before = w.runner.dataCalls.count
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false && warningCodes(out).isEmpty)
            #expect(w.runner.dataCalls.count == before, "the old backup (another lend) is not pushed")
            #expect(w.runner.container(stremioId).isEmpty)
        }
    }

    @Test("a crash mid-backup leaves a .partial folder: never restored, swept by the next backup; the device is untouched")
    func partialFolders() async throws {
        try await withInstallWorld(script: script(DataFaults(listFails: true)), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            // A folder a dead process left, with a manifest that matches this lend.
            let stale = "\(w.appBackups)/20990101T000000Z-aaaa.partial"
            try makeDirectories(stale + "/data", mode: 0o700)
            let manifest = AppDataBackup.Manifest(
                bundleId: w.bundleId, version: "1", lendSince: testNow, createdAt: testNow, complete: true,
                files: [AppDataBackup.Entry(path: library, size: 1, sha256: "00")], restoredAt: nil)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: URL(fileURLWithPath: stale + "/manifest.json"))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false)
            #expect(w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" }.isEmpty)
        }
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let stale = "\(w.appBackups)/20990101T000000Z-aaaa.partial"
            try makeDirectories(stale + "/data", mode: 0o700)
            #expect(await w.lend().ok)
            #expect(w.backupNames.count == 1 && w.finishedBackups.count == 1, "the stale folder is swept")
        }
    }

    @Test("the two newest backups are kept per device and app")
    func retention() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            for round in 1...4 {
                #expect(await w.lend().ok, "lend \(round)")
                #expect(await w.giveBack().ok, "return \(round)")
                w.clock.advance(3_600)
                #expect(w.finishedBackups.count == min(round, AppDataBackup.keep), "after round \(round)")
            }
            let kept = try w.finishedBackups.map { try w.manifest($0).lendSince }
            #expect(kept.count == 2 && kept.min()! >= testNow.addingTimeInterval(2 * 3_600))
        }
    }

    @Test("data calls are attempted only for the lent app's own ID and a backup never touches another app")
    func onlyTheLentApp() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            #expect(await w.giveBack().ok)
            for spec in w.runner.dataCalls {
                let id = spec.args[spec.args.firstIndex(of: "--domain-identifier")! + 1]
                let type = spec.args[spec.args.firstIndex(of: "--domain-type")! + 1]
                #expect(id == stremioId && type == "appDataContainer")
            }
            #expect(!w.runner.dataCalls.isEmpty)
        }
    }

    // MARK: hostile listings, the time cap, copy order

    @Test("a hostile listing creates and chmods nothing outside backups/, and unsafe paths are never copied")
    func hostileListing() async throws {
        let probe = "sideload-escape-probe-" + UUID().uuidString
        let hostile: [String: Data] = [
            "ok.json": data("ok"), "link -> /etc/passwd": data("name"), "...": data("dots"),
            "../../../../../decoy/escape.json": data("up"), "../../../../../../\(probe)/x": data("out"), "/abs/x": data("abs"),
            "a/../../../../../decoy/b": data("mid"), "x/./y": data("dot"), "a//b": data("empty"), "bad\\name": data("slash"),
            "nul\0name": data("nul"), "decoy/../up": data("trail"),
        ]
        try await withInstallWorld(script: script(files: hostile), lendable: "stremio-ios", ledger: prepare) { w in
            let decoy = w.paths.home + "/decoy"
            try makeDirectories(decoy, mode: 0o755)
            chmod(decoy, 0o755)
            let outside = parentPath(w.paths.home) + "/" + probe
            defer { try? FileManager.default.removeItem(atPath: outside) }
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1, "\(out.errors)")
            #expect(modeOf(decoy) == 0o755 && listing(decoy).isEmpty, "nothing created or chmodded in the decoy")
            #expect(!FileManager.default.fileExists(atPath: outside))
            #expect(modeOf(w.paths.home) == 0o700)
            let sources = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy from" }
                .map { $0.args[$0.args.firstIndex(of: "--source")! + 1] }
            #expect(sources.sorted() == ["...", "link -> /etc/passwd", "ok.json"], "\(sources)")
            #expect(json(out)["dataFiles"] == 3 && json(out)["dataFilesFailed"] == 9)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"], "the dropped paths are counted failed")
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.files.map(\.path).sorted() == ["...", "link -> /etc/passwd", "ok.json"])
        }
    }

    @Test("a tampered manifest naming a path outside the app's data is never pushed or read")
    func hostileManifest() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let name = try #require(w.finishedBackups.first)
            var manifest = try w.manifest(name)
            let decoy = w.paths.home + "/decoy"
            try makeDirectories(decoy, mode: 0o755)
            try Data("x".utf8).write(to: URL(fileURLWithPath: decoy + "/f"))
            manifest.files.append(AppDataBackup.Entry(path: "../../../../decoy/f", size: 1, sha256: "00"))
            manifest.files.append(AppDataBackup.Entry(path: "/etc/hosts", size: 1, sha256: "00"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: URL(fileURLWithPath: "\(w.appBackups)/\(name)/manifest.json"))
            let out = await w.giveBack()
            #expect(out.ok && json(out)["dataRestored"] == false && json(out)["dataFilesFailed"] == 2)
            let pushed = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" }
            #expect(pushed.count == 2, "only the two real files")
            #expect(modeOf(decoy) == 0o755)
        }
    }

    @Test("the whole backup stays within 120 s of wall time even when every copy hangs to the Runner's kill")
    func backupWallTime() async throws {
        var files: [String: Data] = [:]
        for index in 1...8 { files["Documents/f\(index).json"] = data("\(index)") }
        var faults = DataFaults()
        faults.copyHangs = true
        try await withInstallWorld(script: script(faults, files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let started = w.clock.now()
            let out = await w.lend()
            let elapsed = w.clock.now().timeIntervalSince(started)
            #expect(out.ok && json(out)["freed"] == 1)
            #expect(elapsed <= 120, "took \(elapsed) s")
            #expect(json(out)["dataBackedUp"] == false && warningCodes(out) == ["DATA_BACKUP_FAILED"])
            let timeouts = w.runner.dataCalls.map { spec in spec.args[spec.args.firstIndex(of: "--timeout")! + 1] }
            #expect(timeouts == ["60", "30", "30"], "each call is cut to what is left minus the Runner's worst-case overrun (23 s): \(timeouts)")
        }
    }

    @Test("the whole restore stays within 120 s of wall time even when every push hangs to the Runner's kill")
    func restoreWallTime() async throws {
        var files: [String: Data] = [:]
        for index in 1...8 { files["Documents/f\(index).json"] = data("\(index)") }
        var faults = DataFaults()
        faults.copyHangs = true
        try await withInstallWorld(script: script(files: files), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(faults, files: files))
            let started = w.clock.now()
            let out = await w.giveBack()
            let elapsed = w.clock.now().timeIntervalSince(started)
            #expect(out.ok && json(out)["reinstalled"] == true)
            #expect(elapsed <= 120, "took \(elapsed) s")
            #expect(json(out)["dataRestored"] == false && json(out)["dataFilesFailed"] == 8)
            let pushed = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" }
            #expect(pushed.count == 2)
        }
    }

    @Test("Library/Preferences is copied first, so a spent allowance cannot starve the sign-in; directories are never copied")
    func preferencesFirst() async throws {
        let files: [String: Data] = [
            "Documents/a.json": data("a"), "Documents/b.json": data("b"), "Documents/c.json": data("c"), "Zeta.bin": data("z"),
            prefs: data("prefs"),
        ]
        try await withInstallWorld(script: script(DataFaults(callTakes: 50), files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataFiles"] == 1 && json(out)["dataFilesFailed"] == 4)
            let sources = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy from" }
                .map { $0.args[$0.args.firstIndex(of: "--source")! + 1] }
            #expect(sources == [prefs], "\(sources)")
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.files.map(\.path).contains(prefs))
        }
    }

    // MARK: links, case-folding and size

    private func symlinks(under root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        return walker.compactMap { $0 as? String }.filter { name in
            var st = stat()
            return lstat(root + "/" + name, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
        }
    }

    @Test("a symlink devicectl leaves in the tree is removed and counted failed; nothing outside backups/ is written or chmodded")
    func copiedSymlink() async throws {
        var faults = DataFaults()
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let outside = w.paths.home + "/outside"
            try makeDirectories(outside, mode: 0o755)
            chmod(outside, 0o755)
            try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/keep.txt"))
            faults.copyFromSymlinks = ["Documents/link.json": outside]
            var files = container
            files["Documents/link.json"] = data("link")
            w.runner.arm(script(faults, files: files))
            w.runner.setContainer(w.bundleId, files)
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1, "\(out.errors)")
            #expect(json(out)["dataFiles"] == 2 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            #expect(modeOf(outside) == 0o755 && listing(outside) == ["keep.txt"], "nothing written or chmodded outside")
            #expect(symlinks(under: w.paths.backups).isEmpty, "no link survives in the backup tree")
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.files.map(\.path).sorted() == [library, prefs].sorted())
        }
    }

    @Test("folder creation walks every part without following links: a link or a file in the way is refused and nothing outside is touched")
    func secureDirectoryRefusesLinks() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.path + "/backups"
        let outside = base.path + "/outside"
        try makeDirectories(root, mode: 0o700)
        try makeDirectories(outside, mode: 0o755)
        chmod(outside, 0o755)
        #expect(symlink(outside, root + "/A") == 0)
        FileManager.default.createFile(atPath: root + "/file", contents: Data("x".utf8))
        // A link named `A` and a path through `A` (or, on a case-insensitive volume, through `a`).
        for path in [root + "/A/x", root + "/A/x/y", root + "/file/x"] {
            #expect(throws: (any Error).self, "\(path.dropFirst(base.path.count))") {
                try AppDataBackup.secureDirectory(path, root: root)
            }
        }
        // `a` is the link on a case-insensitive volume (refused) and a fresh folder on a case-sensitive one; either way the
        // link's target is left alone.
        try? AppDataBackup.secureDirectory(root + "/a/x", root: root)
        #expect(modeOf(outside) == 0o755 && listing(outside).isEmpty, "the link's target was neither chmodded nor written")
        // Paths outside the root, or with odd parts, are refused before anything is created.
        for path in [base.path, base.path + "/other", root + "/../escape", root + "/a/../../escape"] {
            #expect(throws: (any Error).self) { try AppDataBackup.secureDirectory(path, root: root) }
        }
        #expect(!FileManager.default.fileExists(atPath: base.path + "/escape") && !FileManager.default.fileExists(atPath: base.path + "/other"))
        // The plain check agrees.
        try AppDataBackup.secureDirectory(root + "/ok/deeper", root: root)
        #expect(modeOf(root + "/ok/deeper") == 0o700 && modeOf(root + "/ok") == 0o700)
        #expect(AppDataBackup.isPlain(root + "/ok/deeper", root: root, regularFile: false))
        #expect(!AppDataBackup.isPlain(root + "/A", root: root, regularFile: false))
        #expect(!AppDataBackup.isPlain(root + "/A/anything", root: root, regularFile: true))
        #expect(!AppDataBackup.isPlain(root + "/file", root: root, regularFile: false))
        #expect(AppDataBackup.isPlain(root + "/file", root: root, regularFile: true))
    }

    @Test("paths that collide case-insensitively or Unicode-normalised keep the first and count the rest as failed")
    func collisions() {
        func file(_ path: String) -> AppDataBackup.DeviceFile { AppDataBackup.DeviceFile(path: path, size: 1) }
        let listed = [
            file("Docs/X.json"), file("docs/x.json"), file("A"), file("a/x"), file("Cafe\u{301}.json"), file("Caf\u{e9}.json"), file("ok"),
            file("/abs"), file("a/../b"),
        ]
        let result = AppDataBackup.leaves(listed)
        let kept = result.files.map(\.path)
        #expect(kept.count == 4, "\(kept)")
        #expect(kept.contains("Docs/X.json") && kept.contains("a/x") && kept.contains("ok"))
        #expect(!kept.contains("docs/x.json") && !kept.contains("A"), "`A` is the folder `a`, `docs/x.json` is `Docs/X.json`")
        #expect(kept.filter { $0.hasPrefix("Caf") }.count == 1)
        #expect(result.dropped == 5, "two unsafe, the case clash, the folder clash and one normalisation clash")
        let keys = Set(kept.map { $0.decomposedStringWithCanonicalMapping.lowercased() })
        #expect(keys.count == kept.count)
    }

    @Test("the fold is a full case fold: sigma and final sigma are the same name")
    func sigmaFold() {
        func file(_ path: String) -> AppDataBackup.DeviceFile { AppDataBackup.DeviceFile(path: path, size: 1) }
        let result = AppDataBackup.leaves([file("D/\u{391}\u{3A3}.json"), file("D/\u{3B1}\u{3C2}.json"), file("D/other.json")])
        #expect(result.files.count == 2 && result.dropped == 1, "\(result.files.map(\.path))")
    }

    @Test("one entry that cannot be saved is counted failed and skipped; the good ones, preferences included, are kept")
    func oneBadEntry() async throws {
        let tooLong = "Documents/" + String(repeating: "a", count: 300) + "/x.json"  // a name over the filesystem's 255-byte limit
        var files = container
        files[tooLong] = data("long")
        files["Documents/zzz-after.json"] = data("after")
        try await withInstallWorld(script: script(files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1, "\(out.errors)")
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 3 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let manifest = try w.manifest(try #require(w.finishedBackups.first))
            #expect(manifest.files.map(\.path).sorted() == [library, prefs, "Documents/zzz-after.json"].sorted())
            #expect(!manifest.complete)
            let back = await w.giveBack()
            #expect(json(back)["dataRestored"] == true && json(back)["dataFilesRestored"] == 3)
        }
    }

    @Test("the tvOS app on the Apple TV goes through the same backup and restore path")
    func tvOS() async throws {
        let tvId = carrierPrefix + ".free." + ProvisionApp.stremioTVOS.suffix
        let tvPrefs = "Library/Preferences/\(tvId).plist"
        let files: [String: Data] = [tvPrefs: data("tv prefs"), "Documents/addons.json": data("tv addons"), "Library/Caches/x": data("c")]
        var tvScript = DeviceScript(initial: [tvId: true])
        tvScript.container = files
        try await withInstallWorld(app: .stremioTVOS, script: tvScript, ledger: { $0.installs = [installRecord(.stremioTVOS, alias: "appletv")] }) { w in
            try await w.store.update { $0.devices["appletv"]?.lendableApp = "stremio-tvos" }
            let lend = await w.slot("lend", device: "appletv", to: "lab")
            #expect(lend.ok, "\(lend.errors)")
            #expect(json(lend)["dataBackedUp"] == true && json(lend)["dataFiles"] == 2 && json(lend)["dataFilesFailed"] == 0)
            let folder = w.paths.backups + "/appletv/stremio-tvos"
            #expect(listing(folder).count == 1 && modeOf(folder) == 0o700)
            #expect(w.runner.container(tvId).isEmpty, "the uninstall deleted the app's data")
            let back = await w.slot("return", device: "appletv")
            #expect(back.ok, "\(back.errors)")
            #expect(json(back)["dataRestored"] == true && json(back)["dataFilesRestored"] == 2)
            #expect(w.runner.container(tvId).keys.sorted() == ["Documents/addons.json", tvPrefs].sorted())
            for spec in w.runner.dataCalls {
                #expect(spec.args[spec.args.firstIndex(of: "--domain-identifier")! + 1] == tvId)
            }
        }
    }

    @Test("the per-call allowance is pinned to the Runner's real constants")
    func graceIsPinned() {
        // devicectl's own margin over `--timeout`, then the Runner's SIGTERM-to-SIGKILL grace, drain after the kill and reaping.
        #expect(DeviceCtl.runnerMarginSec == 15)
        #expect(PosixSpawnRunner.defaultGrace == .seconds(2))
        #expect(PosixSpawnRunner.drainAfterKill == .seconds(1))
        #expect(PosixSpawnRunner.defaultReapTimeout == .seconds(5))
        #expect(PosixSpawnRunner.worstCaseOverrunSec == 8)
        #expect(AppDataBackup.runnerGraceSec == 23)
        #expect(AppDataBackup.runnerGraceSec == DeviceCtl.runnerMarginSec + PosixSpawnRunner.worstCaseOverrunSec)
        #expect(AppDataBackup.totalBudgetSec == 120)
    }

    @Test("a listing of nothing but unsafe paths is a failed backup with a warning, not an empty success")
    func onlyUnsafe() async throws {
        let hostile: [String: Data] = ["../x": data("a"), "/abs": data("b"), "a//b": data("c")]
        try await withInstallWorld(script: script(files: hostile), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["freed"] == 1)
            #expect(json(out)["dataBackedUp"] == false && json(out)["dataFiles"] == 0 && json(out)["dataFilesFailed"] == 3)
            #expect(warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(w.backupNames.isEmpty)
            #expect(w.runner.dataCalls.map { DeviceSimRunner.words($0) } == ["device info files"], "nothing was asked for")
        }
    }

    @Test("a file the listing says is too big for the 256 MiB cap is not asked for; the rest is still saved")
    func sizeCapBeforeCopy() async throws {
        var faults = DataFaults()
        faults.claimedSizes = ["Documents/big.bin": 300 * 1024 * 1024]
        var files = container
        files["Documents/big.bin"] = data("small")
        try await withInstallWorld(script: script(faults, files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(out.ok && json(out)["dataBackedUp"] == true)
            #expect(json(out)["dataFiles"] == 2 && json(out)["dataFilesFailed"] == 1)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let sources = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy from" }
                .map { $0.args[$0.args.firstIndex(of: "--source")! + 1] }
            #expect(!sources.contains("Documents/big.bin"))
        }
    }

    @Test("the restore does not follow a link planted inside the backup: the file behind it is never read or pushed")
    func restoreFollowsNoLinks() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let name = try #require(w.finishedBackups.first)
            // Same name, same bytes, but reached through a link to a folder outside the backup.
            let outside = w.paths.home + "/outside-docs"
            try makeDirectories(outside + "/Documents", mode: 0o755)
            try container[library]!.write(to: URL(fileURLWithPath: outside + "/" + library))
            let docs = "\(w.appBackups)/\(name)/data/Documents"
            try FileManager.default.removeItem(atPath: docs)
            #expect(symlink(outside + "/Documents", docs) == 0)
            let out = await w.giveBack()
            #expect(out.ok && json(out)["reinstalled"] == true)
            #expect(json(out)["dataRestored"] == false && json(out)["dataFilesRestored"] == 1 && json(out)["dataFilesFailed"] == 1)
            let pushed = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" }
            #expect(pushed.count == 1 && !pushed.contains { $0.args.contains(library) }, "only the preferences went back")
            #expect(w.runner.container(stremioId).keys.sorted() == [prefs])
        }
    }

    @Test("the listing parser: leaves only, caches and tmp skipped, anything malformed is not a listing")
    func listingParser() throws {
        let files: JSONValue = [
            "info": ["outcome": "success"],
            "result": [
                "files": [
                    ["name": "Documents", "relativePath": "Documents", "metadata": [:], "resources": [:]],
                    ["name": "a.json", "relativePath": "Documents/a.json", "metadata": ["size": 5], "resources": [:]],
                    ["name": "Marked", "relativePath": "Marked", "metadata": ["isDirectory": true], "resources": [:]],
                    ["name": "p.plist", "relativePath": "Library/Preferences/p.plist", "metadata": [:], "resources": [:]],
                    ["relativePath": "Library"], ["relativePath": "Library/Caches"], ["relativePath": "Library/Caches/x"],
                    ["relativePath": "Library/CachesX"], ["relativePath": "tmp"], ["relativePath": "tmpfile"], ["relativePath": "Empty"],
                ]
            ],
        ]
        let parsed = try #require(AppDataBackup.parseListing(files))
        #expect(
            AppDataBackup.leaves(parsed).files.map(\.path)
                == ["Library/Preferences/p.plist", "Documents/a.json", "Empty", "Library/CachesX", "tmpfile"],
            "preferences first, sized files next; a directory marked by its metadata is not a file")
        #expect(AppDataBackup.leaves(parsed).files.dropFirst().first?.size == 5)
        #expect(AppDataBackup.parseListing(nil) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": [["relativePath": ""]]]]) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": [["name": "a"]]]]) == nil)
        #expect(AppDataBackup.parseListing(["info": ["outcome": "failed"], "result": ["files": []]]) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": []]]) == [])
    }
}

// MARK: failure reasons

private func count(_ value: JSONValue?) -> Int? {
    if case .number(let n)? = value { return Int(n) }
    return nil
}

/// `dataFailures` as printed: reason -> count (empty when the key is absent).
private func reasons(_ out: Envelope) -> [String: Int] {
    guard case .object(let fields)? = json(out)["dataFailures"] else { return [:] }
    return fields.compactMapValues { count($0) }
}

/// The invariant: the per-reason counts always sum to `dataFilesFailed`, and the key is present exactly when something failed.
private func expectSums(_ out: Envelope, sourceLocation: SourceLocation = #_sourceLocation) {
    let failed = count(json(out)["dataFilesFailed"]) ?? -1
    #expect(reasons(out).values.reduce(0, +) == failed, "the reasons sum to dataFilesFailed", sourceLocation: sourceLocation)
    #expect((json(out)["dataFailures"] != nil) == (failed > 0), "present only when a file failed", sourceLocation: sourceLocation)
    #expect(reasons(out).values.allSatisfy { $0 > 0 }, "zero counts are omitted", sourceLocation: sourceLocation)
}

private func lendLogged(_ w: InstallWorld) async -> (out: Envelope, lines: [String]) {
    let lines = Mutex<[String]>([])
    var services = w.services
    services.log = { line in lines.withLock { $0.append(line) } }
    let out = await SlotCommand.run(services, SlotOptions(sub: "lend", device: "iphone", to: "lab"))
    return (out, lines.withLock { $0 })
}

@Suite("app data failure reasons")
struct AppDataFailureReasonTests {
    @Test("Failures: counts by reason, omitted when zero, in declared order; the summary and the JSON carry fixed words and counts")
    func failuresType() {
        var failures = AppDataBackup.Failures()
        #expect(failures.total == 0 && failures.json == nil && failures.summary == "")
        failures.add(.copyOther, count: 0)
        #expect(failures.total == 0 && failures.json == nil, "a zero count adds nothing")
        failures.add(.notRegularFile)
        failures.add(.copyTimeout, count: 2)
        failures.add(.copyTimeout)
        #expect(failures.total == 4)
        #expect(failures.summary == " (notRegularFile 1, copyTimeout 3)", "declared order")
        #expect(failures.nonZero.map(\.reason) == [.notRegularFile, .copyTimeout])
        #expect(failures.json == ["notRegularFile": 1, "copyTimeout": 3])
        let order = AppDataBackup.FailReason.allCases.map(\.rawValue)
        #expect(Set(order).count == order.count && order.allSatisfy { $0.allSatisfy { $0.isLetter } }, "keys are plain words")
        #expect(AppDataBackup.Result().failed == 0)
    }

    @Test("a call that fails is counted by class: other, locked, not connected, timeout (both kinds), not run, output overflow, signal")
    func copyCallClasses() async throws {
        let cases: [(String, RunResult, String)] = [
            ("exit 1", RunResult(code: 1), "copyOther"),
            ("locked", RunResult(code: 1, stderr: "ERROR: The device is locked. (com.apple.dt.CoreDeviceError error 1)"), "copyDeviceLocked"),
            (
                "not connected", RunResult(code: 1, stderr: "ERROR: The device is not connected. (com.apple.dt.CoreDeviceError error 2)"),
                "copyDeviceNotConnected"
            ),
            (
                "devicectl's own timeout", RunResult(code: 1, stderr: "ERROR: The operation timed out. (com.apple.dt.CoreDeviceError error 4)"),
                "copyTimeout"
            ),
            ("the Runner's kill", RunResult(code: nil, timedOut: true), "copyTimeout"),
            ("not run", RunResult(code: nil, spawnError: "ENOENT"), "copyNotRun"),
            ("overflow", RunResult(code: nil, overflow: true), "copyOther"),
            ("signal", RunResult(code: nil, signal: 9), "copyOther"),
        ]
        for (name, result, reason) in cases {
            var faults = DataFaults()
            faults.copyFromResult = [library: result]
            try await withInstallWorld(script: script(faults), lendable: "stremio-ios", ledger: prepare) { w in
                let (out, lines) = await lendLogged(w)
                #expect(out.ok && json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 1, "\(name)")
                #expect(json(out)["dataFilesFailed"] == 1 && reasons(out) == [reason: 1], "\(name): \(reasons(out))")
                expectSums(out)
                #expect(lines.contains("app data backup: 1 file(s) saved, 1 failed (\(reason) 1)"), "\(name): \(lines)")
            }
        }
        // A call that exits 0 but reports a failed outcome is a failed call: copyOther, like a plain failure.
        try await withInstallWorld(
            script: script(DataFaults(copyFromReportsFailed: [library])), lendable: "stremio-ios", ledger: prepare
        ) { w in
            let out = await w.lend()
            #expect(json(out)["dataFilesFailed"] == 1 && reasons(out) == ["copyOther": 1])
            expectSums(out)
        }
    }

    @Test("a result that is not a regular file, a size that never matches, and a folder that cannot be made are each counted on their own")
    func localReasons() async throws {
        // A link left at the destination.
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let outside = w.paths.home + "/outside"
            try makeDirectories(outside, mode: 0o755)
            var faults = DataFaults()
            faults.copyFromSymlinks = [library: outside]
            w.runner.arm(script(faults))
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 1 && reasons(out) == ["notRegularFile": 1])
            expectSums(out)
        }
        // Short on both tries (two calls for the file).
        try await withInstallWorld(
            script: script(DataFaults(copyFromShort: [library])), lendable: "stremio-ios", ledger: prepare
        ) { w in
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 1 && reasons(out) == ["sizeMismatch": 1])
            #expect(w.dataWords.filter { $0 == "device copy from" }.count == 3, "one call for the preferences, two for the short file")
            expectSums(out)
        }
        // A name over the filesystem's limit: the folder cannot be made, which is a local error (the path itself is safe).
        let tooLong = "Documents/" + String(repeating: "a", count: 300) + "/x.json"
        var files = container
        files[tooLong] = data("long")
        try await withInstallWorld(script: script(files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 2 && json(out)["dataFilesFailed"] == 1)
            #expect(reasons(out) == ["localError": 1])
            expectSums(out)
        }
    }

    @Test("listing drops and caps are counted by reason: unsafe, collision, file cap, size by the listing")
    func listingReasons() async throws {
        // Unsafe paths only: a failed backup, three unsafe paths.
        let hostile: [String: Data] = ["../x": data("a"), "/abs": data("b"), "a//b": data("c")]
        try await withInstallWorld(script: script(files: hostile), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataBackedUp"] == false && json(out)["dataFilesFailed"] == 3 && reasons(out) == ["unsafePath": 3])
            expectSums(out)
        }
        // Names that collide.
        var clash = container
        clash["Documents/Case.json"] = data("1")
        clash["Documents/case.json"] = data("2")
        try await withInstallWorld(script: script(files: clash), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 3 && reasons(out) == ["nameCollision": 1])
            expectSums(out)
        }
        // More than the file cap.
        var many: [String: Data] = [:]
        for index in 0..<203 { many[String(format: "Documents/f%03d.json", index)] = Data([UInt8(index % 251)]) }
        try await withInstallWorld(script: script(files: many), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 200 && reasons(out) == ["fileCap": 3])
            expectSums(out)
        }
        // Too big by the listing.
        var faults = DataFaults()
        faults.claimedSizes = ["Documents/big.bin": 300 * 1024 * 1024]
        var big = container
        big["Documents/big.bin"] = data("small")
        try await withInstallWorld(script: script(faults, files: big), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 2 && reasons(out) == ["sizeLimit": 1])
            expectSums(out)
        }
    }

    @Test("the byte cap reached by a copy counts that file and every file skipped after it as sizeLimit")
    func sizeLimitAfterCopy() async throws {
        var faults = DataFaults()
        faults.noSizes = true  // the listing does not warn, so the cap is met only after the copy
        var files = container
        files["Documents/a-big.bin"] = Data(count: AppDataBackup.maxBytes + 1)
        try await withInstallWorld(script: script(faults, files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            // Preferences first and saved; the big file is over the cap once copied and removed; the last file is skipped.
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 1)
            #expect(reasons(out) == ["sizeLimit": 2], "\(reasons(out))")
            expectSums(out)
        }
    }

    @Test("a spent allowance counts every file not started as timeLimit; the INCOMPLETE and the nothing-saved paths both sum")
    func timeLimitReasons() async throws {
        var files: [String: Data] = [:]
        for index in 1...4 { files["Documents/f\(index).json"] = data("\(index)") }
        // Partial: one copy, three never started.
        try await withInstallWorld(script: script(DataFaults(callTakes: 50), files: files), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataFiles"] == 1 && reasons(out) == ["timeLimit": 3])
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            expectSums(out)
        }
        // Nothing saved: every copy hangs to the kill, the first two are timeouts, the rest never start.
        var hang = DataFaults()
        hang.copyHangs = true
        var eight: [String: Data] = [:]
        for index in 1...8 { eight["Documents/f\(index).json"] = data("\(index)") }
        try await withInstallWorld(script: script(hang, files: eight), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataBackedUp"] == false && warningCodes(out) == ["DATA_BACKUP_FAILED"])
            #expect(reasons(out) == ["copyTimeout": 2, "timeLimit": 6], "\(reasons(out))")
            expectSums(out)
        }
    }

    @Test("a run with several causes sums them all; a clean run and a failed listing have no dataFailures")
    func mixedAndClean() async throws {
        var many: [String: Data] = [prefs: data("prefs")]
        for index in 0..<203 { many[String(format: "Documents/f%03d.json", index)] = Data([UInt8(index % 251)]) }
        try await withInstallWorld(script: script(files: many), lendable: "stremio-ios", ledger: prepare) { w in
            let outside = w.paths.home + "/outside"
            try makeDirectories(outside, mode: 0o755)
            var faults = DataFaults()
            faults.copyFromResult = ["Documents/f000.json": RunResult(code: 1)]
            faults.copyFromSymlinks = ["Documents/f001.json": outside]
            w.runner.arm(script(faults, files: many))
            let (out, lines) = await lendLogged(w)
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 198 && json(out)["dataFilesFailed"] == 6)
            #expect(reasons(out) == ["fileCap": 4, "copyOther": 1, "notRegularFile": 1], "\(reasons(out))")
            #expect(lines.contains("app data backup: 198 file(s) saved, 6 failed (fileCap 4, notRegularFile 1, copyOther 1)"), "\(lines)")
            expectSums(out)
        }
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let (out, lines) = await lendLogged(w)
            #expect(json(out)["dataFilesFailed"] == 0 && json(out)["dataFailures"] == nil)
            #expect(lines.contains("app data backup: 2 file(s) saved, 0 failed"), "no parenthesis when nothing failed: \(lines)")
            expectSums(out)
        }
        try await withInstallWorld(script: script(DataFaults(listFails: true)), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.lend()
            #expect(json(out)["dataFilesFailed"] == 0 && json(out)["dataFailures"] == nil)
            expectSums(out)
        }
    }

    @Test("failure reasons leak nothing: fixed words and counts in the output, the log and the ledger")
    func reasonsAreCountsOnly() async throws {
        var faults = DataFaults()
        faults.copyFromResult = [library: RunResult(code: 1, stderr: "ERROR: The device is locked: Documents/library-9b2e.json \(sentinel)")]
        try await withInstallWorld(script: script(faults), lendable: "stremio-ios", ledger: prepare) { w in
            let (out, lines) = await lendLogged(w)
            #expect(reasons(out) == ["copyDeviceLocked": 1])
            if case .object(let fields)? = json(out)["dataFailures"] {
                #expect(fields.values.allSatisfy { if case .number = $0 { true } else { false } })
            } else {
                Issue.record("dataFailures is not an object")
            }
            var text = try out.printed().text + lines.joined(separator: "\n")
            text += String(decoding: try Data(contentsOf: URL(fileURLWithPath: w.paths.ledger)), as: UTF8.self)
            for secret in [sentinel, "library-9b2e", "Preferences", "Documents", "Library", "backups", "thumb"] {
                #expect(!text.contains(secret), "\(secret) leaked")
            }
        }
    }
}
