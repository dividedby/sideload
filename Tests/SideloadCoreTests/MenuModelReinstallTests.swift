import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

private final class Record: Sendable {
    private let lines = Mutex<[String]>([])
    var calls: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private let oldSha = String(repeating: "38", count: 32)

@MainActor
@Suite("menu: view model, Reinstall previous version")
struct MenuModelReinstallTests {
    private struct World {
        let model: MenuModel
        let record: Record
        let dir: URL
    }

    /// One reachable iPhone with Apollo 3.9.0 installed (profile fresh, App ID live), and a stored, approved 3.8.0 whose file
    /// is on disk. `install` moves the record to the version `sign` was asked for.
    private func world(storeFile: Bool = true) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        var ledger = menuLedger([("iphone", "apollo", 5)])
        ledger.installs[0].version = "3.9.0"
        ledger.freeProfiles = [
            LedgerFreeProfile(
                id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
                profileUuid: "UUID-1", created: nil, expires: daysFromNow(6.5), certFp8: "12345678", file: "x")
        ]
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))]
        try await seed(paths, config: addConfig(), ledger: ledger)
        var manifest = Manifest()
        manifest.entries = [
            ManifestEntry(
                app: "apollo", version: "3.8.0", file: "apollo/3.8.0/Apollo.ipa", urlHost: "github.com", sha256: oldSha,
                upstreamDigest: oldSha, size: 44_000_000, fetchedAt: testNow, approved: true)
        ]
        try ManifestStore(paths: paths).save(manifest)
        if storeFile {
            try FileManager.default.createDirectory(atPath: "\(paths.downloads)/apollo/3.8.0", withIntermediateDirectories: true)
            try Data("ipa".utf8).write(to: URL(fileURLWithPath: "\(paths.downloads)/apollo/3.8.0/Apollo.ipa"))
        }
        let runner = SlowDeviceRunner(
            menuDeviceScript(devices: deviceListJSON(phoneEntryJSON(seed: "1")), apps: { _ in .apps([menuBundleId("apollo")]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow), keychain: FakeKeychain(), home: paths)
        let record = Record()
        var steps = MenuActionSteps()
        steps.fetch = { _, _ in
            record.add("fetch")
            return Envelope(ok: true, command: "fetch")
        }
        steps.provision = { _, _ in
            record.add("provision")
            return Envelope(ok: true, command: "provision")
        }
        steps.sign = { services, options in
            record.add("sign \(options.version ?? "")")
            try? await services.ledgerStore.update {
                var signed = menuSigned("iphone", "apollo", days: 7, uuid: "UUID-1")
                signed.version = "3.8.0"
                signed.sha256Prefix = String(oldSha.prefix(8))
                $0.freeSigned = [signed]
            }
            return Envelope(ok: true, command: "sign")
        }
        steps.install = { services, _ in
            record.add("install")
            try? await services.ledgerStore.update { $0.installs[0].version = "3.8.0" }
            return Envelope(ok: true, command: "install")
        }
        return World(model: MenuModel(services: services, steps: steps), record: record, dir: dir)
    }

    private func loaded(_ w: World) async {
        w.model.reload(force: true)
        await w.model.loadTask?.value
        await w.model.updateTask?.value
    }

    private func row(_ w: World) -> MenuAppRow? {
        guard case .loaded(let snapshot) = w.model.panel else { return nil }
        return snapshot.devices.first?.apps.first
    }

    private func offer(_ w: World) -> MenuOffer? {
        guard case .loaded(let snapshot) = w.model.panel, let card = snapshot.devices.first, let row = row(w) else { return nil }
        return w.model.offers(for: row, on: card, in: snapshot).first { $0.kind == .reinstallPrevious }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    @Test("the panel's load reads the manifest and the file: the row offers the stored older build")
    func loaderReadsManifest() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        #expect(row(w)?.previous?.version == "3.8.0" && row(w)?.previous?.sha256 == oldSha)
        #expect(offer(w)?.label == "Reinstall previous version (3.8.0)…" && offer(w)?.availability == .enabled)

        let gone = try await world(storeFile: false)
        defer { try? FileManager.default.removeItem(at: gone.dir) }
        await loaded(gone)
        #expect(row(gone)?.previous == nil && offer(gone) == nil)
    }

    @Test("the offer is off while another action runs, like Update's")
    func offWhileRunning() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        w.model.request(.remove(device: "iphone", app: "apollo"))
        #expect(offer(w)?.availability == .disabled(MenuActions.controlsBusy))
        w.model.dismiss()
        #expect(offer(w)?.availability == .enabled)
    }

    @Test("one confirm runs provision (skipped here), sign of exactly 3.8.0 and install, then the device is read again")
    func flow() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        let action = try #require(offer(w)?.action)
        w.model.request(action)
        guard case .confirming(let first, let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(first == action && prompt.title == "Reinstall Apollo 3.8.0 on iphone (now 3.9.0)")
        w.model.confirm()
        guard case .running(let label, true, false) = w.model.actionState else {
            Issue.record("expected running, got \(w.model.actionState)")
            return
        }
        #expect(label == "Reinstalling Apollo 3.8.0 on iphone…")
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.headline == "Reinstalled Apollo 3.8.0 on iphone")
        #expect(w.record.calls == ["sign 3.8.0", "install"])
        // Read again as after any change: the row is at 3.8.0 and has nothing older to go back to.
        await w.model.loadTask?.value
        #expect(row(w)?.installedVersion == "3.8.0" && row(w)?.previous == nil && offer(w) == nil)
    }

    @Test("a stored file that went away while the confirm was open is blocked, and nothing runs")
    func goneBeforeConfirm() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        let action = try #require(offer(w)?.action)
        w.model.request(action)
        // The model reconfirms against the panel it holds; a reload after `clean` drops the build from it.
        try FileManager.default.removeItem(atPath: "\(w.model.services.home.downloads)/apollo")
        await loaded(w)
        w.model.confirm()
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the Not run card, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "Not run" && outcome.issues.first?.message == "No previous version of Apollo is stored")
        #expect(w.record.calls.isEmpty)
    }
}
