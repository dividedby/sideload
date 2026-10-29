import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

/// Serves the Apollo release after a pause the test controls, and counts the requests. A cancelled request ends at once.
private final class SlowSource: HTTPTransport {
    private struct State {
        var gets: [String] = []
        var open = true
    }

    private let state = Mutex(State())
    private let body: Data

    init(version: String) {
        body = releaseJSON(
            tag: "v1.15.11_\(version)",
            assets: apolloDecoys(version: version) + [ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa")])
    }

    var gets: [String] { state.withLock { $0.gets } }
    func hold(_ hold: Bool) { state.withLock { $0.open = !hold } }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        state.withLock { $0.gets.append(request.url.absoluteString) }
        while !state.withLock({ $0.open }) { try await Task.sleep(for: .milliseconds(5)) }
        return HTTPResponse(status: 200, body: body)
    }
}

private final class Record: Sendable {
    private let lines = Mutex<[String]>([])
    var calls: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

@MainActor
@Suite("menu: view model, Update and the update check")
struct MenuModelUpdateTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let source: SlowSource
        let record: Record
        let clock: MutableClock
        let paths: Paths
        let dir: URL
    }

    private let fetch = MenuAction.updateFetch(device: "iphone", app: "apollo", from: "3.9.0")

    /// One reachable iPhone with Apollo 3.9.0 installed (profile fresh, App ID live) and an approved Apollo source that lists
    /// `listed`. The fetch returns `fetchedVersion`; the later commands record themselves, and `install` moves the record on.
    private func world(listed: String = "3.10.0", fetchedVersion: String = "3.10.0") async throws -> World {
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
                app: "apollo", version: fetchedVersion, file: "apollo/\(fetchedVersion)/Apollo.ipa", urlHost: "github.com", sha256: addSha,
                upstreamDigest: addSha, size: 45_200_000, fetchedAt: testNow, approved: false)
        ]
        try ManifestStore(paths: paths).save(manifest)
        let runner = SlowDeviceRunner(
            menuDeviceScript(devices: deviceListJSON(phoneEntryJSON(seed: "1")), apps: { _ in .apps([menuBundleId("apollo")]) }))
        let clock = MutableClock(testNow)
        let source = SlowSource(version: listed)
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: clock, keychain: FakeKeychain(), home: paths, http: source)
        let record = Record()
        var steps = MenuActionSteps()
        steps.fetch = { _, options in
            record.add(options.approve ? "approve \(options.version ?? "")" : "fetch")
            return Envelope(
                ok: true, command: "fetch",
                data: [
                    "version": .string(fetchedVersion), "build": "143", "sha256": .string(addSha), "size": 45_200_000,
                    "inspectMinOS": "16.0", "alreadyApproved": false, "inspect": ["extensionCount": 2],
                ])
        }
        steps.provision = { _, _ in
            record.add("provision")
            return Envelope(ok: true, command: "provision", data: ["appIdNew": false])
        }
        steps.sign = { services, options in
            record.add("sign \(options.version ?? "")")
            try? await services.ledgerStore.update {
                var signed = menuSigned("iphone", "apollo", days: 7, uuid: "UUID-1")
                signed.version = fetchedVersion
                signed.sha256Prefix = String(addSha.prefix(8))
                $0.freeSigned = [signed]
            }
            return Envelope(ok: true, command: "sign")
        }
        steps.install = { services, _ in
            record.add("install")
            try? await services.ledgerStore.update { $0.installs[0].version = fetchedVersion }
            return Envelope(ok: true, command: "install")
        }
        return World(
            model: MenuModel(services: services, steps: steps), runner: runner, source: source, record: record, clock: clock,
            paths: paths, dir: dir)
    }

    /// Loads and lets the check that follows finish.
    private func loaded(_ w: World, force: Bool = true) async {
        w.model.reload(force: force)
        await w.model.loadTask?.value
        await w.model.updateTask?.value
    }

    private func row(_ w: World) -> MenuAppRow? {
        guard case .loaded(let snapshot) = w.model.panel else { return nil }
        return snapshot.devices.first?.apps.first
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    @Test("the check runs after the device reads, as a task of its own, and the panel repaints with the update")
    func checkAndRepaint() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        // Nothing listed yet when the load paints.
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(row(w)?.presence == .installed && row(w)?.updateLine == nil)
        #expect(w.runner.infoApps.count == 1, "the devices were read first")
        await w.model.updateTask?.value
        #expect(w.source.gets == [apolloAPI])
        #expect(row(w)?.updateLine == "Update available · 3.9.0 → 3.10.0" && row(w)?.offersUpdate == true)
        #expect(w.model.updateTask == nil)
        // The file now holds it: a fresh model reading only the local file shows the line at once.
        #expect(MenuUpdates.cached(w.model.services)["apollo"]?.version == "3.10.0")
    }

    @Test("a panel open within 6 hours asks nothing; Check status now keeps the 5-minute floor; later it asks again")
    func cadence() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        #expect(w.source.gets.count == 1)

        w.clock.advance(3_600)
        await loaded(w, force: false)
        #expect(w.source.gets.count == 1 && row(w)?.updateLine != nil, "an open within 6 h is answered by the file")

        w.clock.advance(6 * 3_600)
        await loaded(w, force: false)
        #expect(w.source.gets.count == 2, "an open after 6 h asks again")

        await loaded(w)
        #expect(w.source.gets.count == 2, "Check status now right after is inside the 5-minute floor")
        w.clock.advance(301)
        await loaded(w)
        #expect(w.source.gets.count == 3)
    }

    @Test("a source that does not answer leaves the panel loaded and offers no update")
    func sourceDown() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        // 404 for the Apollo URL: the release is not there.
        var down = w.model.services
        down.http = FakeFetchTransport(metadata: [:])
        let model = MenuModel(services: down)
        model.reload(force: true)
        await model.loadTask?.value
        await model.updateTask?.value
        guard case .loaded(let snapshot) = model.panel else {
            Issue.record("the panel must stay loaded")
            return
        }
        #expect(snapshot.devices[0].apps.first?.update == nil && snapshot.devices[0].apps.first?.updateLine == nil)
    }

    @Test("one check at a time: a reload while it runs does not start another; quitting cancels it")
    func oneAtATime() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.source.hold(true)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        try await until { w.source.gets.count == 1 }
        #expect(w.model.updateTask != nil)
        w.clock.advance(400)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(w.source.gets.count == 1, "the running check is the only one")
        #expect(row(w)?.updateLine == nil)

        w.model.cancelForShutdown()
        await w.model.updateTask?.value
        #expect(w.model.updateTask == nil && row(w)?.updateLine == nil)
        // A cancelled check wrote nothing.
        #expect(MenuUpdates.cached(w.model.services).isEmpty)
    }

    @Test("Check status now during a running check is queued and runs once, forced, when it ends")
    func forcedCheckQueued() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.source.hold(true)
        w.model.reload(force: false)
        await w.model.loadTask?.value
        try await until { w.source.gets.count == 1 }
        // Past the 5-minute floor of the check that is running, which started now.
        w.clock.advance(400)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(w.source.gets.count == 1)
        w.source.hold(false)
        try await until { w.source.gets.count == 2 }
        await w.model.updateTask?.value
        #expect(w.source.gets.count == 2 && w.model.updateTask == nil)
        #expect(row(w)?.updateLine != nil)
    }

    @Test("an action that starts cancels the check in flight; its end checks again, and a forced one is still forced")
    func actionCancelsCheck() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        #expect(w.source.gets.count == 1)
        w.clock.advance(400)
        w.source.hold(true)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        try await until { w.source.gets.count == 2 }
        #expect(w.model.updateTask != nil)
        w.model.request(.remove(device: "iphone", app: "apollo"))
        w.model.confirm()
        #expect(w.model.updateTask == nil, "cancelled when the action started")
        w.source.hold(false)
        try await until { !w.model.actionBusy }
        // The cancelled forced check runs again after the action (from the reload its end starts), forced, so it asks even
        // though the cache is fresh. Wait for that request: the reload may not have started when the action stops being busy.
        try await until { w.source.gets.count == 3 }
        await w.model.loadTask?.value
        await w.model.updateTask?.value
        #expect(w.source.gets.count == 3)
    }

    @Test("a fetch stage that ends with no reload runs the check it held off")
    func fetchStageChecks() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        #expect(w.source.gets.count == 1)
        // The 6 h cadence has run out meanwhile; no load follows a fetch stage.
        w.clock.advance(7 * 3_600)
        w.model.request(fetch)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.updateTask?.value
        #expect(w.source.gets.count == 2)
        guard case .confirming = w.model.actionState else {
            Issue.record("expected the approval confirm, got \(w.model.actionState)")
            return
        }
    }

    @Test("an action running holds the check off")
    func notDuringAction() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        w.model.request(.remove(device: "iphone", app: "apollo"))
        w.model.confirm()
        #expect(w.model.actionBusy)
        w.model.reload(force: true)
        #expect(w.model.updateTask == nil)
        try await until { !w.model.actionBusy }
    }

    @Test("Update to X…: the fetch opens confirm 2 at once, which runs the chain; the row then has no update")
    func updateFlow() async throws {
        let w = try await world()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        w.model.request(fetch)
        guard case .confirming(let first, let prompt) = w.model.actionState else {
            Issue.record("expected the fetch confirm, got \(w.model.actionState)")
            return
        }
        #expect(first == fetch && prompt.title == "Fetch Apollo update for iphone")
        let listsBefore = w.runner.lists
        let readsBefore = w.runner.infoApps.count
        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .confirming(let action, let approval) = w.model.actionState else {
            Issue.record("expected the approval confirm, got \(w.model.actionState)")
            return
        }
        #expect(approval.title == "Approve and update Apollo 3.9.0 → 3.10.0 on iphone")
        if case .updateApprove(_, "apollo", "3.9.0", let fetched) = action { #expect(fetched.version == "3.10.0") } else {
            Issue.record("expected the update approval, got \(action)")
        }
        // Stage 1 changed nothing: the device was not read again.
        await w.model.loadTask?.value
        #expect(w.record.calls == ["fetch"] && w.runner.lists == listsBefore && w.runner.infoApps.count == readsBefore)

        w.model.confirm()
        guard case .running(let label, true, false) = w.model.actionState else {
            Issue.record("expected running, got \(w.model.actionState)")
            return
        }
        #expect(label == "Updating Apollo 3.9.0 → 3.10.0 on iphone…")
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.headline == "Updated Apollo 3.9.0 → 3.10.0 on iphone")
        // The profile has 6.5 days left: reused, no provision.
        #expect(w.record.calls == ["fetch", "approve 3.10.0", "sign 3.10.0", "install"])
        // The device is read again, and the listing now equals the installed version.
        await w.model.loadTask?.value
        await w.model.updateTask?.value
        #expect(w.runner.lists == listsBefore + 1)
        #expect(row(w)?.installedVersion == "3.10.0" && row(w)?.updateLine == nil && row(w)?.update?.state == .current)
    }

    @Test("a fetched version that is not newer is not offered for approval: the card says why and nothing else runs")
    func notNewer() async throws {
        let w = try await world(fetchedVersion: "3.9.0")
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        w.model.request(fetch)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the Not run card, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "Not run" && outcome.issues.first?.message == "Apollo 3.9.0 is not newer than 3.9.0")
        #expect(w.record.calls == ["fetch"])
    }

    @Test("no update is offered for a version that is not newer: the fetch confirm does not open")
    func nothingToUpdate() async throws {
        let w = try await world(listed: "3.9.0")
        defer { try? FileManager.default.removeItem(at: w.dir) }
        await loaded(w)
        #expect(row(w)?.update?.state == .current && row(w)?.updateLine == nil)
        w.model.request(fetch)
        #expect(w.model.actionState == .idle)
    }
}
