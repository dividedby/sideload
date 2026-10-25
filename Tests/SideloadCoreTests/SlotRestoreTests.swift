import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// `sideload slot restore` (docs/design.md section 18, "App data"): the owner's retry of an app-data restore that `slot return`
// could not finish, against the simulated device of `InstallTestSupport`.

private let sentinel = "SENTINEL-SESSION-TOKEN-7c41"
private let prefs = "Library/Preferences/io.github.dividedby.free.stremio.plist"
private let library = "Documents/library-9b2e.json"

private let files: [String: Data] = [prefs: Data((sentinel + "prefs").utf8), library: Data((sentinel + "library").utf8)]

private func script(_ faults: DataFaults = DataFaults(), files: [String: Data] = files) -> DeviceScript {
    var script = DeviceScript(initial: [stremioId: true])
    script.container = files
    script.dataFaults = faults
    return script
}

private func prepare(_ ledger: inout Ledger) { ledger.installs = [installRecord(.stremioIOS)] }

private func faults(_ change: (inout DataFaults) -> Void) -> DataFaults {
    var value = DataFaults()
    change(&value)
    return value
}

private extension InstallWorld {
    var appBackups: String { paths.backups + "/iphone/stremio-ios" }
    var finishedBackups: [String] { listing(appBackups).sorted().filter { !$0.hasSuffix(".partial") } }
    func manifest(_ name: String) throws -> AppDataBackup.Manifest {
        let raw = try Data(contentsOf: URL(fileURLWithPath: "\(appBackups)/\(name)/manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppDataBackup.Manifest.self, from: raw)
    }
    func lend() async -> Envelope { await slot("lend", device: "iphone", to: "lab") }
    func giveBack() async -> Envelope { await slot("return", device: "iphone") }
    func restore(
        _ services: Services? = nil, device: String? = "iphone", app: String? = nil, yes: Bool = true, udid: String? = nil,
        to: String? = nil
    ) async -> Envelope {
        await SlotCommand.run(
            services ?? self.services,
            SlotOptions(sub: "restore", device: device, udid: udid, to: to, app: app, yes: yes))
    }
    var xcrunCalls: Int { runner.calls.filter { $0.executable == "xcrun" }.count }
    var pushes: [CommandSpec] { runner.dataCalls.filter { DeviceSimRunner.words($0) == "device copy to" } }
    /// A lend whose backup holds both files, and a return whose restore then fails on `faults`; the backup stays unrestored.
    func lendAndFailedReturn(_ failing: DataFaults = faults { $0.copyToFails = [prefs] }) async throws {
        #expect(await lend().ok)
        runner.arm(script(failing))
        let back = await giveBack()
        #expect(back.ok && json(back)["dataRestored"] == false, "\(back.errors)")
    }
    func ledgerBytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) }
}

private func warningCodes(_ out: Envelope) -> [String] {
    (json(out)["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
}

@Suite("slot restore")
struct SlotRestoreTests {
    // MARK: dispatch and order

    @Test("usage, then the saved alias, then --yes: nothing runs before the owner confirms")
    func dispatch() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.restore(device: nil).errorCodes == ["USAGE"])
            #expect(await w.restore(device: "").errorCodes == ["USAGE"])
            #expect(await w.restore(udid: "x").errorCodes == ["USAGE"], "the owner uses the alias")
            #expect(await w.restore(to: "lab").errorCodes == ["USAGE"])
            #expect(await w.restore(device: "nope").errorCodes == ["DEVICE_NOT_SAVED"])
            #expect(await w.restore(app: "nonsense").errorCodes == ["USAGE"])
            let lend = await SlotCommand.run(w.services, SlotOptions(sub: "lend", device: "iphone", to: "lab", yes: true))
            #expect(lend.errorCodes == ["USAGE"], "slot lend does not take --yes")
            let lendApp = await SlotCommand.run(w.services, SlotOptions(sub: "lend", device: "iphone", to: "lab", app: "stremio-ios"))
            #expect(lendApp.errorCodes == ["USAGE"])
            let back = await SlotCommand.run(w.services, SlotOptions(sub: "return", device: "iphone", yes: true))
            #expect(back.errorCodes == ["USAGE"], "slot return does not take --yes")
        }
        // No --app and no lendable app on the device.
        try await withInstallWorld(script: script(), ledger: prepare) { w in
            #expect(await w.restore().errorCodes == ["USAGE"])
        }
        // Without --yes: CONFIRM_REQUIRED, no lock, no subprocess, no ledger write.
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let before = try w.ledgerBytes()
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            let out = await w.restore(yes: false)
            #expect(out.errorCodes == ["CONFIRM_REQUIRED"], "the lock is not even tried")
            #expect(json(out)["action"] == "restore" && json(out)["device"] == "iphone" && json(out)["app"] == "stremio-ios")
            #expect(w.runner.calls.isEmpty)
            #expect(try w.ledgerBytes() == before)
        }
    }

    @Test("a busy lock is OPERATION_IN_PROGRESS and nothing else happens")
    func busy() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            let calls = w.runner.calls.count
            let before = try w.ledgerBytes()
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(await w.restore().errorCodes == ["OPERATION_IN_PROGRESS"])
            #expect(w.runner.calls.count == calls)
            #expect(try w.ledgerBytes() == before)
        }
    }

    // MARK: success and retry

    @Test("after a failed return-restore, slot restore pushes the backup, relists, marks it, and writes no ledger or install call")
    func happyPath() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            #expect(w.runner.container(stremioId).keys.sorted() == [library], "the failed return restored one file")
            let ledgerBefore = try w.ledgerBytes()
            let installs = w.runner.installCalls.count
            w.runner.arm(script())
            let out = await w.restore()
            #expect(out.ok, "\(out.errors)")
            let printed = json(out)
            #expect(printed["action"] == "restore" && printed["device"] == "iphone" && printed["app"] == "stremio-ios")
            #expect(printed["dataRestored"] == true && printed["dataFilesRestored"] == 2 && printed["dataFilesFailed"] == 0)
            #expect(warningCodes(out).isEmpty)
            #expect(w.runner.container(stremioId) == [library: files[library]!, prefs: files[prefs]!])
            let manifest = try w.manifest(try #require(w.finishedBackups.last))
            #expect(manifest.restoredAt == testNow && manifest.supersededAt == nil)
            #expect(w.finishedBackups.count == 1, "the backup is kept")
            #expect(try w.ledgerBytes() == ledgerBefore, "not a slot operation")
            #expect(w.runner.installCalls.count == installs)
            let words = w.runner.calls.filter { $0.executable == "xcrun" }.map { DeviceSimRunner.words($0) }
            #expect(!words.suffix(from: words.count - 5).contains { $0.contains("install") || $0.contains("uninstall") })
            #expect(words.lastIndex(of: "device info files")! > words.lastIndex(of: "device copy to")!, "relisted to compare")
            try w.expectClean(out)
            // Once marked, a rerun has nothing to do.
            let again = await w.restore()
            #expect(again.errorCodes == ["NO_PENDING_RESTORE"] && json(again)["restored"] == true)
        }
    }

    @Test("failures keep the backup and are repeatable: INCOMPLETE, then UNVERIFIED, then success")
    func retry() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            let name = try #require(w.finishedBackups.last)
            // 1: a push the device drops.
            w.runner.arm(script(faults { $0.copyToDrops = true }))
            let dropped = await w.restore()
            #expect(dropped.errorCodes == ["RESTORE_FAILED"], "\(dropped.errors)")
            var printed = json(dropped)
            #expect(printed["cause"] == "DATA_RESTORE_INCOMPLETE" && printed["dataRestored"] == false)
            #expect(printed["kept"] == true && printed["dataFilesFailed"] == 1, "only the file the return could not push is missing")
            #expect(warningCodes(dropped) == ["DATA_RESTORE_INCOMPLETE"])
            #expect(try w.manifest(name).restoredAt == nil)
            // 2: the relisting cannot be read (the lend's, the return's and the first run's listings came before).
            let listings = w.runner.dataCalls.filter { DeviceSimRunner.words($0) == "device info files" }.count
            w.runner.arm(script(faults { $0.listFailsOn = [listings + 1] }))
            let unverified = await w.restore()
            #expect(unverified.errorCodes == ["RESTORE_FAILED"])
            printed = json(unverified)
            #expect(printed["cause"] == "DATA_RESTORE_UNVERIFIED" && printed["dataFilesRestored"] == 2 && printed["dataFilesFailed"] == 0)
            #expect(printed["kept"] == true && warningCodes(unverified) == ["DATA_RESTORE_UNVERIFIED"])
            #expect(try w.manifest(name).restoredAt == nil)
            // 3: clean.
            w.runner.arm(script())
            let done = await w.restore()
            #expect(done.ok && json(done)["dataRestored"] == true, "\(done.errors)")
            #expect(try w.manifest(name).restoredAt == testNow)
            #expect(w.runner.container(stremioId) == [library: files[library]!, prefs: files[prefs]!])
        }
    }

    @Test("a partial backup restores what was saved, with the same warning as the return")
    func partialBackup() async throws {
        try await withInstallWorld(script: script(faults { $0.copyFromFails = [prefs] }), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(faults { $0.copyToFails = [library] }))
            #expect(json(await w.giveBack())["dataRestored"] == false)
            w.runner.arm(script(files: [:]))
            let out = await w.restore()
            #expect(out.ok && json(out)["dataRestored"] == true && json(out)["dataFilesRestored"] == 1)
            #expect(warningCodes(out) == ["DATA_RESTORE_PARTIAL_BACKUP"])
        }
    }

    // MARK: nothing pending

    @Test("already restored, no backup, and backups turned off: NO_PENDING_RESTORE with booleans, and no device call")
    func nothingPending() async throws {
        // Already restored by the return.
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            #expect(json(await w.giveBack())["dataRestored"] == true)
            let calls = w.xcrunCalls
            let out = await w.restore()
            #expect(out.errorCodes == ["NO_PENDING_RESTORE"])
            #expect(json(out)["restored"] == true && json(out)["superseded"] == false && json(out)["unreadable"] == false)
            #expect(w.xcrunCalls == calls, "a local read: no device call")
        }
        // No backup ever made.
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            let out = await w.restore()
            #expect(out.errorCodes == ["NO_PENDING_RESTORE"])
            #expect(json(out)["restored"] == false && json(out)["superseded"] == false && json(out)["unreadable"] == false)
            #expect(w.xcrunCalls == 0)
        }
        // backupData false.
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.store.update { $0.apps["stremio-ios"] = ["backupData": false] }
            #expect(await w.lend().ok)
            #expect(await w.giveBack().ok)
            let calls = w.xcrunCalls
            #expect(await w.restore().errorCodes == ["NO_PENDING_RESTORE"])
            #expect(w.xcrunCalls == calls)
        }
    }

    @Test("an unreadable newest manifest is NO_PENDING_RESTORE unreadable, and no older backup is used instead")
    func unreadable() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            let older = try #require(w.finishedBackups.last)
            let baseline = w.pushes.count
            // A newer folder with a manifest that is not JSON.
            let newer = "\(w.appBackups)/29990101T000000Z-aaaa"
            try makeDirectories(newer, mode: 0o700)
            try Data("not json".utf8).write(to: URL(fileURLWithPath: newer + "/manifest.json"))
            chmod(newer + "/manifest.json", 0o600)
            let calls = w.xcrunCalls
            let out = await w.restore()
            #expect(out.errorCodes == ["NO_PENDING_RESTORE"] && json(out)["unreadable"] == true)
            #expect(w.xcrunCalls == calls)
            #expect(try w.manifest(older).restoredAt == nil, "the older one stays as it was")
            // A symlinked manifest is not read either.
            try FileManager.default.removeItem(atPath: newer + "/manifest.json")
            try FileManager.default.createSymbolicLink(
                atPath: newer + "/manifest.json", withDestinationPath: "\(w.appBackups)/\(older)/manifest.json")
            #expect(json(await w.restore())["unreadable"] == true)
            #expect(w.pushes.count == baseline, "no push from restore")
        }
    }

    // MARK: staleness

    @Test("a later lend supersedes an earlier unrestored backup, even when it saved nothing: slot restore never pushes it")
    func superseded() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn(faults { $0.copyToFails = [prefs, library] })
            let name = try #require(w.finishedBackups.last)
            #expect(try w.manifest(name).supersededAt == nil, "pending until a later lend")
            w.clock.advance(86_400)
            w.runner.arm(script(faults { $0.listFails = true }))
            #expect(await w.lend().ok)
            let superseded = try w.manifest(name)
            #expect(superseded.supersededAt == testNow.addingTimeInterval(86_400) && superseded.restoredAt == nil)
            #expect(modeOf("\(w.appBackups)/\(name)/manifest.json") == 0o600 && modeOf("\(w.appBackups)/\(name)") == 0o700)
            #expect(await w.giveBack().ok)
            let pushes = w.pushes.count
            let out = await w.restore()
            #expect(out.errorCodes == ["NO_PENDING_RESTORE"])
            #expect(json(out)["superseded"] == true && json(out)["restored"] == false)
            #expect(w.pushes.count == pushes, "no push")
        }
    }

    @Test("supersedeOlder leaves the lend's own backup, restored ones and other apps alone; old manifests decode")
    func supersedeRules() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let target = try FreeTarget.resolve(app: .stremioIOS, alias: "iphone", config: try w.config())
            let name = try #require(w.finishedBackups.last)
            // The same lend (a resumed one): not older.
            AppDataBackup.supersedeOlder(w.services, target, than: testNow)
            #expect(try w.manifest(name).supersededAt == nil)
            AppDataBackup.supersedeOlder(w.services, target, than: testNow.addingTimeInterval(0.5))
            #expect(try w.manifest(name).supersededAt == nil, "within the same second")
            // A restored one is not marked.
            #expect(await w.giveBack().ok)
            AppDataBackup.supersedeOlder(w.services, target, than: testNow.addingTimeInterval(60))
            #expect(try w.manifest(name).restoredAt != nil && w.manifest(name).supersededAt == nil)
            // Never throws on a missing folder.
            let other = try FreeTarget.resolve(app: .apollo, alias: "iphone", config: try w.config())
            AppDataBackup.supersedeOlder(w.services, other, than: testNow.addingTimeInterval(60))
        }
        // A manifest written before the field existed decodes, and encodes without it.
        let old = """
            {"bundleId":"x","version":"1","lendSince":"2026-10-24T00:00:00Z","createdAt":"2026-10-24T00:00:00Z","complete":true,"files":[]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AppDataBackup.Manifest.self, from: Data(old.utf8))
        #expect(manifest.supersededAt == nil && manifest.restoredAt == nil)
    }

    // MARK: preconditions on the ledger and the device

    @Test("while the app is lent, in any phase: ALREADY_LENT, and no device call")
    func alreadyLent() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            let calls = w.xcrunCalls
            let before = try w.ledgerBytes()
            let out = await w.restore()
            #expect(out.errorCodes == ["ALREADY_LENT"])
            #expect(out.errors.first?.fix?.contains("slot return --device iphone") == true)
            #expect(w.xcrunCalls == calls)
            #expect(try w.ledgerBytes() == before)
        }
    }

    @Test("an op in flight on the device is SLOT_PENDING with no device call")
    func pending() async throws {
        let timedOut = DeviceScript(
            initial: [stremioId: true], uninstallLandsAfter: 100, uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: timedOut, lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().errorCodes == ["TIMEOUT"])
            let calls = w.xcrunCalls
            let out = await w.restore()
            #expect(out.errorCodes == ["SLOT_PENDING"])
            #expect(w.xcrunCalls == calls)
        }
    }

    @Test("the app must be installed: APP_NOT_INSTALLED after app remove, SNAPSHOT_FAILED when the list cannot be read")
    func device() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            let before = try w.ledgerBytes()
            let baseline = w.pushes.count
            var unreadable = script()
            unreadable.snapshotFailures = [1]
            w.runner.arm(unreadable)
            let failed = await w.restore()
            #expect(failed.errorCodes.count == 1 && !failed.ok, "\(failed.errors)")
            #expect(w.pushes.count == baseline, "no push without a snapshot")
            w.runner.arm(script())
            #expect(await w.remove().ok)
            let afterRemove = try w.ledgerBytes()
            let pushes = w.pushes.count
            let out = await w.restore()
            #expect(out.errorCodes == ["APP_NOT_INSTALLED"])
            #expect(w.pushes.count == pushes)
            #expect(try w.ledgerBytes() == afterRemove)
            #expect(before != afterRemove, "app remove is a slot operation; restore is not")
        }
    }

    @Test("a changed free identity set or a locked keychain stops it before anything else")
    func session() async throws {
        let marker = LedgerFreeInFlight(beforeFp8: ["00000000"], startedAt: testNow, app: "stremio-ios", device: "iphone")
        try await withInstallWorld(
            script: script(), lendable: "stremio-ios", ledger: { prepare(&$0); $0.freeProvisionInFlight = marker }
        ) { w in
            #expect(await w.restore().errorCodes == ["FREE_CERT_CHANGED"])
            #expect(w.runner.calls.isEmpty)
        }
        try await withInstallWorld(script: script(), lendable: "stremio-ios", keychain: [nil], ledger: prepare) { w in
            #expect(await w.restore().errorCodes == ["KEYCHAIN_LOCKED"])
            #expect(w.runner.calls.isEmpty)
        }
    }

    // MARK: secrets, scope and time

    @Test("output, progress lines and the ledger carry counts and booleans only; modes hold; every call is scoped to the free ID")
    func secrets() async throws {
        try await withInstallWorld(script: script(), lendable: "stremio-ios", ledger: prepare) { w in
            try await w.lendAndFailedReturn()
            let lines = Mutex<[String]>([])
            var services = w.services
            services.log = { line in lines.withLock { $0.append(line) } }
            w.runner.arm(script(faults { $0.copyToDrops = true }))
            let failed = await w.restore(services)
            w.runner.arm(script())
            let ok = await w.restore(services)
            #expect(failed.errorCodes == ["RESTORE_FAILED"] && ok.ok)
            let name = try #require(w.finishedBackups.last)
            var text = try failed.printed().text + (try ok.printed().text) + lines.withLock { $0 }.joined(separator: "\n")
            text += String(decoding: try w.ledgerBytes(), as: UTF8.self)
            for secret in [sentinel, "library-9b2e", "Preferences", "Documents", "Library", "backups", "thumb", name, savedUdid("1"), savedCoreId("1")] {
                #expect(!text.contains(secret), "\(secret) leaked")
            }
            for key in ["dataRestored", "dataFilesRestored", "dataFilesFailed"] {
                switch json(ok)[key] {
                case .bool?, .number?: break
                default: Issue.record("\(key) is not a bool or a count")
                }
            }
            let root = "\(w.appBackups)/\(name)"
            for dir in [w.paths.backups, w.paths.backups + "/iphone", w.appBackups, root, root + "/data"] {
                #expect(modeOf(dir) == 0o700, "\(dir.dropFirst(w.paths.home.count))")
            }
            #expect(modeOf(root + "/manifest.json") == 0o600)
            for spec in w.runner.dataCalls {
                #expect(spec.args[spec.args.firstIndex(of: "--domain-identifier")! + 1] == stremioId)
                #expect(spec.args[spec.args.firstIndex(of: "--domain-type")! + 1] == "appDataContainer")
            }
            #expect(!w.runner.deviceArgv.contains { $0.contains("io.github.dividedby.free") && $0 != stremioId && !$0.hasPrefix("/") && !$0.hasPrefix("Library") })
        }
    }

    @Test("the restore stays within 120 s even when every push hangs to the Runner's kill; each call is cut to what is left")
    func wallTime() async throws {
        var many: [String: Data] = [:]
        for index in 1...8 { many["Documents/f\(index).json"] = Data((sentinel + "\(index)").utf8) }
        try await withInstallWorld(script: script(files: many), lendable: "stremio-ios", ledger: prepare) { w in
            #expect(await w.lend().ok)
            w.runner.arm(script(faults { $0.copyToFails = Set(many.keys) }, files: many))
            #expect(json(await w.giveBack())["dataRestored"] == false)
            w.runner.arm(script(faults { $0.copyHangs = true }, files: many))
            let pushed = w.pushes.count
            let started = w.clock.now()
            let out = await w.restore()
            let elapsed = w.clock.now().timeIntervalSince(started)
            #expect(out.errorCodes == ["RESTORE_FAILED"] && json(out)["dataFilesFailed"] == 8)
            #expect(elapsed <= 120, "took \(elapsed) s")
            let timeouts = w.pushes.dropFirst(pushed).map { $0.args[$0.args.firstIndex(of: "--timeout")! + 1] }
            #expect(timeouts == ["30", "30"], "30 s each, then under 5 s left once the Runner's 23 s are kept back: \(timeouts)")
            let name = try #require(w.finishedBackups.last)
            #expect(try w.manifest(name).restoredAt == nil)
        }
    }

    // MARK: the lab's debug hook

    #if DEBUG
    @Test("SIDELOAD_TEST_FORCE_SLOT does not apply to restore")
    func debugHook() async throws {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("sideload"))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/sideload"))
        let binary = try #require(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "build the sideload executable first (swift build)")
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: carrierPrefix)) { paths, _ in
            for mode in ["pending", "return-failed", "bogus"] {
                let process = Process()
                process.executableURL = binary
                // No --yes: the command stops at CONFIRM_REQUIRED before any lock, keychain or device.
                process.arguments = ["slot", "restore", "--device", "iphone", "--app", "stremio-ios"]
                var env = ProcessInfo.processInfo.environment
                env["SIDELOAD_HOME"] = paths.home
                env["SIDELOAD_TEST_FORCE_SLOT"] = mode
                process.environment = env
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                try process.run()
                let pid = process.processIdentifier
                let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let printed = try decodeJSON(String(decoding: data, as: UTF8.self))
                #expect(printed["errors"]?.array?.first?["code"] == "CONFIRM_REQUIRED", "\(mode): \(printed)")
                #expect(printed["action"] == "restore")
            }
        }
    }
    #endif
}
