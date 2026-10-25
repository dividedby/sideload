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
            // list 50 s (70 left), copy 1 with 30 s (50 s taken, 20 left), copy 2 with 20 s (-30 left), then no more calls.
            #expect(json(out)["dataBackedUp"] == true && json(out)["dataFiles"] == 2 && json(out)["dataFilesFailed"] == 2)
            #expect(warningCodes(out) == ["DATA_BACKUP_INCOMPLETE"])
            let timeouts = w.runner.dataCalls.map { spec in spec.args[spec.args.firstIndex(of: "--timeout")! + 1] }
            #expect(timeouts == ["60", "30", "20"])
            #expect(w.dataWords.count == 3)
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

    @Test("the listing parser: leaves only, caches and tmp skipped, anything malformed is not a listing")
    func listingParser() throws {
        let files: JSONValue = [
            "info": ["outcome": "success"],
            "result": [
                "files": [
                    ["name": "Documents", "relativePath": "Documents", "metadata": [:], "resources": [:]],
                    ["name": "a.json", "relativePath": "Documents/a.json", "metadata": ["size": 5], "resources": [:]],
                    ["relativePath": "Library"], ["relativePath": "Library/Caches"], ["relativePath": "Library/Caches/x"],
                    ["relativePath": "Library/CachesX"], ["relativePath": "tmp"], ["relativePath": "tmpfile"], ["relativePath": "Empty"],
                ]
            ],
        ]
        let parsed = try #require(AppDataBackup.parseListing(files))
        #expect(AppDataBackup.leaves(parsed).map(\.path) == ["Documents/a.json", "Empty", "Library/CachesX", "tmpfile"])
        #expect(AppDataBackup.leaves(parsed).first?.size == 5)
        #expect(AppDataBackup.parseListing(nil) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": [["relativePath": ""]]]]) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": [["name": "a"]]]]) == nil)
        #expect(AppDataBackup.parseListing(["info": ["outcome": "failed"], "result": ["files": []]]) == nil)
        #expect(AppDataBackup.parseListing(["result": ["files": []]]) == [])
    }
}
