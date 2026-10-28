import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

/// Holds a fake command until the test lets it go.
private final class Hold: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var calls: [String] = []
    }

    private let state = Mutex(State())
    var calls: [String] { state.withLock { $0.calls } }
    var waiting: Int { state.withLock { $0.waiters.count } }

    func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { st -> Bool in
                if st.open { return true }
                st.waiters.append(c)
                return false
            }
            if resume { c.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { st -> [CheckedContinuation<Void, Never>] in
            st.open = true
            defer { st.waiters = [] }
            return st.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
@Suite("menu: view model, Add app")
struct MenuModelAddAppTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let hold: Hold
        let dir: URL
    }

    private let fetch = MenuAction.addFetch(device: "iphone", app: "apollo")

    /// One reachable iPhone with no apps and an approved Apollo source. `fetch` waits at the hold when `held`, and fails with
    /// `fetchFails`; the later commands record themselves and succeed.
    private func world(held: Bool = false, fetchFails: Envelope? = nil) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(paths, config: addConfig(), ledger: Ledger())
        var manifest = Manifest()
        manifest.entries = [
            ManifestEntry(
                app: "apollo", version: "3.9.0", file: "apollo/3.9.0/Apollo.ipa", urlHost: "github.com", sha256: addSha,
                upstreamDigest: addSha, size: 45_200_000, fetchedAt: testNow, approved: false)
        ]
        try ManifestStore(paths: paths).save(manifest)
        let list = deviceListJSON(phoneEntryJSON(seed: "1"))
        let runner = SlowDeviceRunner(menuDeviceScript(devices: list, apps: { _ in .apps([]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow), keychain: FakeKeychain(), home: paths)
        let hold = Hold()
        var steps = MenuActionSteps()
        steps.fetch = { _, options in
            hold.record(options.approve ? "approve \(options.version ?? "")" : "fetch")
            if held, !options.approve { await hold.wait() }
            if let fetchFails { return fetchFails }
            return Envelope(
                ok: true, command: "fetch",
                data: [
                    "version": "3.9.0", "build": "142", "sha256": .string(addSha), "size": 45_200_000, "inspectMinOS": "16.0",
                    "alreadyApproved": false, "inspect": ["extensionCount": 2],
                ])
        }
        steps.provision = { services, _ in
            hold.record("provision")
            try? await services.ledgerStore.update {
                $0.freeProfiles = [
                    LedgerFreeProfile(
                        id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
                        profileUuid: "UUID-1", created: nil, expires: daysFromNow(7), certFp8: "12345678", file: "x")
                ]
            }
            return Envelope(ok: true, command: "provision", data: ["appIdNew": true])
        }
        steps.sign = { services, options in
            hold.record("sign \(options.version ?? "")")
            try? await services.ledgerStore.update {
                var signed = menuSigned("iphone", "apollo", days: 7, uuid: "UUID-1")
                signed.version = "3.9.0"
                signed.sha256Prefix = String(addSha.prefix(8))
                $0.freeSigned = [signed]
            }
            return Envelope(ok: true, command: "sign")
        }
        steps.install = { _, _ in
            hold.record("install")
            return Envelope(ok: true, command: "install")
        }
        return World(model: MenuModel(services: services, steps: steps), runner: runner, hold: hold, dir: dir)
    }

    private func loaded(held: Bool = false, fetchFails: Envelope? = nil) async throws -> World {
        let w = try await world(held: held, fetchFails: fetchFails)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        return w
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    @Test("the fetch confirm opens, and a fetched version opens the approval confirm at once: no result card, no re-read of the device")
    func fetchOpensApproval() async throws {
        let w = try await loaded()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(fetch)
        guard case .confirming(let first, let prompt) = w.model.actionState else {
            Issue.record("expected the fetch confirm, got \(w.model.actionState)")
            return
        }
        #expect(first == fetch && prompt.title == "Fetch Apollo for iphone")
        try await Task.sleep(for: .milliseconds(30))
        #expect(w.hold.calls.isEmpty)

        let listsBefore = w.runner.lists
        let readsBefore = w.runner.infoApps.count
        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .confirming(let action, let approval) = w.model.actionState else {
            Issue.record("expected the approval confirm, got \(w.model.actionState)")
            return
        }
        #expect(action == .addApprove(device: "iphone", app: "apollo", fetched: addFetched))
        #expect(approval.title == "Approve and install Apollo 3.9.0 on iphone" && approval.lines.contains("SHA-256 \(addSha)"))
        // Stage 1 changed nothing: the device was not read again, and the card does not say "Checking apps…".
        await w.model.loadTask?.value
        #expect(w.hold.calls == ["fetch"])
        #expect(w.runner.lists == listsBefore && w.runner.infoApps.count == readsBefore && w.model.loadTask == nil)
        if case .loaded(let snapshot) = w.model.panel {
            #expect(snapshot.devices[0].liveRead == .read)
        } else {
            Issue.record("the panel must stay loaded")
        }
    }

    @Test("dismissing the approval leaves the file fetched and nothing approved, signed or installed")
    func dismissApproval() async throws {
        let w = try await loaded()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(fetch)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        w.model.dismiss()
        #expect(w.model.actionState == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.hold.calls == ["fetch"])
    }

    @Test("the approval confirm runs the chain with the version it showed, then the device is read again")
    func approvalRuns() async throws {
        let w = try await loaded()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(fetch)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        let listsBefore = w.runner.lists
        w.model.confirm()
        guard case .running(let label, let cancellable, false) = w.model.actionState else {
            Issue.record("expected running, got \(w.model.actionState)")
            return
        }
        #expect(label == "Adding Apollo 3.9.0 to iphone…" && cancellable)
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.headline == "Added Apollo 3.9.0 to iphone")
        #expect(w.hold.calls == ["fetch", "approve 3.9.0", "provision", "sign 3.9.0", "install"])
        await w.model.loadTask?.value
        #expect(w.runner.lists == listsBefore + 1)
    }

    @Test("a fetch that fails shows a card with Retry and does not re-read the device")
    func fetchFails() async throws {
        let w = try await loaded(fetchFails: .fail("fetch", code: "FETCH_HTTP_ERROR", message: "HTTP 503.", fix: "Retry later."))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let listsBefore = w.runner.lists
        w.model.request(fetch)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .failed && outcome.headline == "Fetch failed" && outcome.lines.first?.retry == fetch)
        await w.model.loadTask?.value
        #expect(w.runner.lists == listsBefore)
        // Retry goes through the confirm again, and the device is still readable, so it opens.
        w.model.request(fetch)
        guard case .confirming = w.model.actionState else {
            Issue.record("the retry must open the confirm, got \(w.model.actionState)")
            return
        }
    }

    @Test("Cancel during the download ends it as Cancelled and opens no approval")
    func cancelFetch() async throws {
        let w = try await loaded(held: true, fetchFails: .fail("fetch", code: "CANCELLED", message: "fetch was interrupted."))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(fetch)
        w.model.confirm()
        try await until { w.hold.waiting == 1 }
        guard case .running(_, true, false) = w.model.actionState else {
            Issue.record("expected a cancellable run, got \(w.model.actionState)")
            return
        }
        w.model.cancelAction()
        w.hold.release()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .cancelled && outcome.proceed == nil)
        #expect(w.hold.calls == ["fetch"])
    }
}
