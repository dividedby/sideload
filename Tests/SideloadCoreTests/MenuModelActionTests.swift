import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

/// Holds a fake command until the test lets it go.
private final class ActionGate: Sendable {
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
@Suite("menu: view model actions")
struct MenuModelActionTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let gate: ActionGate
        let dir: URL
    }

    private let renew = MenuAction.renew(device: "iphone", app: "apollo")

    /// One reachable device with Apollo recorded (5.5 days left: renewable, and `ok` for the ring). `refresh` waits at the
    /// gate when `held`, and leaves post-result work behind when `postEmit`.
    private func world(held: Bool, postEmit: Bool = false, postEmitWaitsForCancel: Bool = false) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(paths, config: menuConfig(), ledger: menuLedger([("iphone", "apollo", 5.5)]))
        let list = deviceListJSON(phoneEntryJSON(seed: "1"))
        let runner = SlowDeviceRunner(menuDeviceScript(devices: list, apps: { _ in .apps([menuBundleId("apollo")]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow), keychain: FakeKeychain(), home: paths)
        let gate = ActionGate()
        var steps = MenuActionSteps()
        steps.refresh = { services, options in
            gate.record("refresh \(options.device ?? "") \(options.app ?? "all") force=\(options.force) yes=\(options.yes)")
            if postEmit {
                services.postEmit.add { gate.record("postEmit lists=\(runner.lists)") }
            }
            if postEmitWaitsForCancel {
                services.postEmit.add {
                    gate.record("postEmit waiting")
                    for _ in 0..<300 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    gate.record("postEmit cancelled=\(Task.isCancelled)")
                }
            }
            if held { await gate.wait() }
            return Envelope(
                ok: true, command: "refresh",
                data: ["results": [["app": "apollo", "status": "renewed", "daysLeftBefore": 5, "daysLeftAfter": 7]]])
        }
        return World(model: MenuModel(services: services, steps: steps), runner: runner, gate: gate, dir: dir)
    }

    private func loadedWorld(held: Bool = true, postEmit: Bool = false, postEmitWaitsForCancel: Bool = false) async throws -> World {
        let w = try await world(held: held, postEmit: postEmit, postEmitWaitsForCancel: postEmitWaitsForCancel)
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

    @Test("a request only opens the confirm: nothing runs until confirm()")
    func requestRunsNothing() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(renew)
        guard case .confirming(let action, let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(action == renew && prompt.title == "Renew Apollo on iphone")
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.gate.calls.isEmpty)
        w.model.dismiss()
        #expect(w.model.actionState == .idle)
        // An action that is not available opens nothing.
        w.model.request(.remove(device: "nobody", app: "apollo"))
        #expect(w.model.actionState == .idle)
        w.model.confirm()
        #expect(w.model.actionState == .idle && !w.model.actionBusy)
    }

    @Test("running: the options are exact, the icon says renewing only meanwhile, one action at a time, reloads are skipped")
    func running() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(w.model.panel.icon.state == .ok)
        let listsBefore = w.runner.lists

        w.model.request(renew)
        w.model.confirm()
        guard case .running(let label, let cancellable, false) = w.model.actionState else {
            Issue.record("expected running, got \(w.model.actionState)")
            return
        }
        #expect(label == "Renewing Apollo on iphone…" && cancellable)
        #expect(w.model.panel.icon.state == .renewing)
        try await until { w.gate.waiting == 1 }
        #expect(w.gate.calls == ["refresh iphone apollo force=true yes=true"])

        // One at a time: a second request, a second confirm and any reload do nothing while it runs.
        w.model.request(.lendable(device: "iphone", app: "filler"))
        w.model.confirm()
        w.model.reload(force: true)
        w.model.reload()
        #expect(w.model.loadTask == nil && w.runner.lists == listsBefore)
        guard case .running = w.model.actionState else {
            Issue.record("the state changed while running: \(w.model.actionState)")
            return
        }
        #expect(!w.model.controlsEnabled)
        #expect(w.gate.calls.count == 1)

        w.gate.release()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.lines.map(\.text) == ["Renewed · 5 d → 7 d"])
        await w.model.loadTask?.value
        #expect(w.model.panel.icon.state != .renewing)
    }

    @Test("after the command: the device's read is forgotten and the device is read again at once, past the debounce")
    func rereadsAfterwards() async throws {
        let w = try await loadedWorld(held: false)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let readsBefore = w.runner.infoApps.count
        let listsBefore = w.runner.lists
        w.model.request(renew)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        #expect(w.runner.infoApps.count == readsBefore + 1)
        #expect(w.runner.lists == listsBefore + 1)
        guard case .finished = w.model.actionState else {
            Issue.record("the result must stay until dismissed: \(w.model.actionState)")
            return
        }
        w.model.dismiss()
        #expect(w.model.actionState == .idle)
    }

    @Test("the command's post-result work runs after the result and before the re-read")
    func postEmitOrder() async throws {
        let w = try await loadedWorld(held: false, postEmit: true)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let listsBefore = w.runner.lists
        w.model.request(renew)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        #expect(w.gate.calls.last == "postEmit lists=\(listsBefore)")
        #expect(w.runner.lists == listsBefore + 1)
    }

    @Test("Cancel marks the run as cancelling; reopening the panel during the run shows the running state and reloads nothing")
    func cancel() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(renew)
        w.model.confirm()
        try await until { w.gate.waiting == 1 }
        w.model.reload()
        guard case .running(_, _, false) = w.model.actionState else {
            Issue.record("expected running: \(w.model.actionState)")
            return
        }
        w.model.cancelAction()
        guard case .running(_, _, true) = w.model.actionState else {
            Issue.record("expected cancelling: \(w.model.actionState)")
            return
        }
        w.gate.release()
        try await until { !w.model.actionBusy }
        // The fake command returned ok, so a clean run despite the click lost nothing.
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done)
        await w.model.loadTask?.value
    }

    @Test("quit during the post-result work cancels the task; the on-card Cancel does not reach it")
    func shutdownReachesPostEmit() async throws {
        let w = try await loadedWorld(held: false, postEmitWaitsForCancel: true)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(renew)
        w.model.confirm()
        try await until { w.gate.calls.contains("postEmit waiting") }
        guard case .finished = w.model.actionState else {
            Issue.record("expected the result while the post-result work runs: \(w.model.actionState)")
            return
        }
        #expect(w.model.actionBusy)
        w.model.cancelAction()
        try await Task.sleep(for: .milliseconds(100))
        #expect(w.model.actionBusy)
        w.model.cancelForShutdown()
        try await until { !w.model.actionBusy }
        #expect(w.gate.calls.last == "postEmit cancelled=true")
        await w.model.loadTask?.value
    }

    @Test("All apps runs one refresh per app the confirm lists, never an open-ended one")
    func allPerListedApp() async throws {
        let w = try await loadedWorld(held: false)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let all = MenuAction.renew(device: "iphone", app: nil)
        w.model.request(all)
        guard case .confirming(_, let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(prompt.apps == ["apollo"])
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        #expect(w.gate.calls == ["refresh iphone apollo force=true yes=true"])
    }

    @Test("confirm() runs only what the owner saw: a changed confirm is shown again instead of run, an identical one runs")
    func confirmRechecks() async throws {
        let w = try await loadedWorld(held: false)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(renew)
        guard case .confirming(_, let shown) = w.model.actionState else {
            Issue.record("expected the confirm")
            return
        }
        // The App ID count in the confirm changes while it is open.
        let paths = Paths(home: w.dir.path)
        var ledger = menuLedger([("iphone", "apollo", 5.5)])
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))]
        try await seed(paths, config: menuConfig(), ledger: ledger)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        w.model.confirm()
        guard case .confirming(_, let again) = w.model.actionState else {
            Issue.record("expected the confirm again, got \(w.model.actionState)")
            return
        }
        #expect(again != shown && again.lines.contains { $0.contains("1 of 10 used") })
        #expect(w.gate.calls.isEmpty && !w.model.actionBusy)

        // Confirmed as shown now, it runs.
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        #expect(w.gate.calls == ["refresh iphone apollo force=true yes=true"])
    }

    @Test("an action that became unavailable is not run: the reason is shown")
    func confirmUnavailable() async throws {
        let w = try await loadedWorld(held: false)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(renew)
        let paths = Paths(home: w.dir.path)
        var ledger = menuLedger([("iphone", "apollo", 5.5)])
        ledger.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        try await seed(paths, config: menuConfig(), ledger: ledger)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        w.model.confirm()
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the reason, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "Not run" && outcome.issues.first?.message == "Free certificate changed")
        #expect(w.gate.calls.isEmpty && !w.model.actionBusy)
    }

    @Test("a setting is not cancellable, and Cancel with nothing running does nothing")
    func lendableNotCancellable() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(MenuActions.cancellable(renew) && !MenuActions.cancellable(.lendable(device: "iphone", app: nil)))
        w.model.cancelAction()
        #expect(w.model.actionState == .idle)
    }
}
