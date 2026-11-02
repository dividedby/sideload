import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

// The auto-renew toggle on a device card (owner decision 2026-11-01; design section 12): the offer, its availability and confirm,
// the run (`device auto-refresh --on|--off --yes` only), the result, and the card afterwards. Fakes and temp homes only.

private let turnOn = MenuAction.autoRenew(device: "iphone", on: true)
private let turnOff = MenuAction.autoRenew(device: "iphone", on: false)

private func offSnapshot() -> MenuSnapshot { menuBuild() }
private func onSnapshot() -> MenuSnapshot { menuBuild(config: menuConfig(auto: ["iphone"])) }

private func availability(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuAvailability {
    MenuActions.availability(action, in: snapshot, now: testNow)
}

private final class Log: Sendable {
    private let lines = Mutex<[String]>([])
    var value: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

@Suite("menu auto-renew: offer, availability and confirm")
struct MenuAutoRenewRulesTests {
    @Test("the card knows the setting, and the offer flips it with the title for the current state")
    func offer() {
        let off = offSnapshot()
        #expect(off.devices[0].autoRenew == false)
        let turnOnOffer = MenuActions.autoRenewOffer(off.devices[0], snapshot: off, now: testNow)
        #expect(turnOnOffer.label == "Turn auto-renew on…" && turnOnOffer.action == turnOn)
        #expect(turnOnOffer.kind == .autoRenew && turnOnOffer.availability == .enabled && !turnOnOffer.destructive)

        let on = onSnapshot()
        #expect(on.devices[0].autoRenew)
        let turnOffOffer = MenuActions.autoRenewOffer(on.devices[0], snapshot: on, now: testNow)
        #expect(turnOffOffer.label == "Turn auto-renew off…" && turnOffOffer.action == turnOff)
        #expect(turnOffOffer.availability == .enabled)
    }

    @Test("every saved device gets its own offer, even offline, with an unreadable ledger or a suspended free team")
    func everyDevice() {
        let config = menuConfig(auto: ["appletv"], devices: ["iphone", "appletv"])
        let offline = menuBuild(config: config, probe: .listed([]), ledgerReadable: false)
        let labels = offline.devices.map { MenuActions.autoRenewOffer($0, snapshot: offline, now: testNow) }
        #expect(labels.map(\.label) == ["Turn auto-renew on…", "Turn auto-renew off…"])
        #expect(labels.allSatisfy { $0.availability == .enabled })
        var suspended = Ledger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        #expect(availability(turnOn, menuBuild(ledger: suspended)) == .enabled)
    }

    @Test("a lent or changing app does not stop it: the lab does not read the setting")
    func lentDoesNotStop() {
        var lent = Ledger()
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        #expect(availability(turnOn, menuBuild(ledger: lent)) == .enabled)
    }

    @Test("setting it to what it already is, or on a device that is gone, is not available")
    func noChange() {
        #expect(availability(turnOn, onSnapshot()) == .disabled("Already on"))
        #expect(availability(turnOff, offSnapshot()) == .disabled("Already off"))
        #expect(availability(.autoRenew(device: "nobody", on: true), offSnapshot()) == .disabled("Device not found"))
        #expect(MenuActions.prompt(for: turnOn, in: onSnapshot(), now: testNow) == nil)
    }

    @Test("it is instant, not cancellable, and names its device")
    func shape() {
        #expect(!MenuActions.cancellable(turnOn) && !MenuActions.cancellable(turnOff))
        #expect(turnOn.device == "iphone" && turnOn.leavesDeviceReadAlone && turnOff.leavesDeviceReadAlone)
        // Fetch stages leave the device read alone too; the other settings and the chains do not.
        #expect(MenuAction.addFetch(device: "iphone", app: "apollo").leavesDeviceReadAlone)
        #expect(!MenuAction.lendable(device: "iphone", app: nil).leavesDeviceReadAlone)
        #expect(!MenuAction.renew(device: "iphone", app: nil).leavesDeviceReadAlone)
    }

    @Test("the confirm to turn it on says what it does and does not do")
    func promptOn() throws {
        let prompt = try #require(MenuActions.prompt(for: turnOn, in: offSnapshot(), now: testNow))
        #expect(prompt.title == "Turn auto-renew on for iphone" && prompt.confirmLabel == "Turn on")
        #expect(!prompt.destructive && prompt.runningLabel == "Saving…" && prompt.apps.isEmpty)
        #expect(
            prompt.lines == [
                "Renews the free-team installs on iphone while you are logged in and it is reachable over Wi-Fi or USB",
                "Spends no new App ID",
                "Needs the refresh agent loaded; `sideload refresh --print-agent` shows how",
                "Setting only: nothing is renewed or changed on the device now",
            ])
    }

    @Test("the confirm to turn it off says installs then expire after 7 days unless renewed by hand")
    func promptOff() throws {
        let prompt = try #require(MenuActions.prompt(for: turnOff, in: onSnapshot(), now: testNow))
        #expect(prompt.title == "Turn auto-renew off for iphone" && prompt.confirmLabel == "Turn off")
        #expect(!prompt.destructive && prompt.runningLabel == "Saving…")
        #expect(
            prompt.lines == [
                "Installs on iphone expire after 7 days unless you renew them by hand",
                "Setting only: nothing is changed on the device",
            ])
    }

    @Test("no confirm text carries a device name, an ID or a UDID")
    func noNames() throws {
        for (action, snapshot) in [(turnOn, offSnapshot()), (turnOff, onSnapshot())] {
            let prompt = try #require(MenuActions.prompt(for: action, in: snapshot, now: testNow))
            let all = ([prompt.title, prompt.runningLabel, prompt.confirmLabel] + prompt.lines).joined(separator: "\n")
            for secret in ["Robin", savedUdid("1"), savedCoreId("1"), "io.github", "7AGMPUPP64", "6ZU5Z6ZKK7"] {
                #expect(!all.contains(secret), "\(action): \(secret)")
            }
        }
    }

    @Test("a confirm left open across a change of the setting is blocked, not run; an unchanged panel runs")
    func reconfirm() throws {
        let shown = try #require(MenuActions.prompt(for: turnOn, in: offSnapshot(), now: testNow))
        #expect(MenuActions.reconfirm(turnOn, shown: shown, in: offSnapshot(), now: testNow) == .run(shown))
        #expect(MenuActions.reconfirm(turnOn, shown: shown, in: onSnapshot(), now: testNow) == .blocked("Already on"))
        #expect(MenuActions.blockedReason(turnOn, in: onSnapshot(), now: testNow) == "Already on")
        let gone = menuBuild(config: menuConfig(devices: ["ipad"]))
        #expect(MenuActions.reconfirm(turnOn, shown: shown, in: gone, now: testNow) == .blocked("Device not found"))
    }

    @Test("the \"Auto-renew off\" label under the rows follows the setting: gone when it is on")
    func labelFollows() {
        let ledger = menuLedger([("iphone", "apollo", 3)])
        let apps: [String: DeviceAppsProbe] = ["iphone": .read(menuSnapshot([menuBundleId("apollo")]), takenAt: testNow)]
        let off = menuBuild(ledger: ledger, apps: apps, autoRefreshAvailable: true)
        #expect(off.devices[0].apps[0].exception == "Auto-renew off")
        let on = menuBuild(config: menuConfig(auto: ["iphone"]), ledger: ledger, apps: apps, autoRefreshAvailable: true)
        #expect(on.devices[0].apps[0].exception == nil)
        // The offline line follows too.
        let seen = testNow.addingTimeInterval(-3 * 3600)
        let gone: DeviceProbe = .listed([menuListed(link: "unavailable", lastSeen: seen)])
        #expect(menuBuild(probe: gone, autoRefreshAvailable: true).devices[0].offlineNote == "Seen 3 h ago · auto-renew off")
        let onGone = menuBuild(config: menuConfig(auto: ["iphone"]), probe: gone, autoRefreshAvailable: true)
        #expect(onGone.devices[0].offlineNote == "Seen 3 h ago · renews when back on Wi-Fi or USB")
    }
}

@Suite("menu auto-renew: the run and the result")
struct MenuAutoRenewRunTests {
    private func services(_ paths: Paths = Paths(home: "/nonexistent-sideload-home")) -> Services {
        Services(
            runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
            keychain: FakeKeychain(), home: paths)
    }

    /// Every step logs; nothing else may be called.
    private func steps(_ log: Log) -> MenuActionSteps {
        var steps = MenuActionSteps()
        steps.autoRenew = { _, options in
            log.add("autoRenew \(options)")
            return .result("device auto-refresh")
        }
        steps.refresh = { _, _ in log.add("refresh"); return .result("refresh") }
        steps.install = { _, _ in log.add("install"); return .result("install") }
        steps.remove = { _, _ in log.add("remove"); return .result("app remove") }
        steps.lendable = { _, _ in log.add("lendable"); return .result("device lendable") }
        steps.saveDevice = { _, _ in log.add("saveDevice"); return .result("device save") }
        steps.fetch = { _, _ in log.add("fetch"); return .result("fetch") }
        steps.provision = { _, _ in log.add("provision"); return .result("provision") }
        steps.sign = { _, _ in log.add("sign"); return .result("sign") }
        return steps
    }

    @Test("the run calls only the auto-refresh step, with the right flag and the owner's --yes")
    func onlyAutoRefresh() async {
        for (action, on) in [(turnOn, true), (turnOff, false)] {
            let log = Log()
            await MenuActionRunner.perform(action, services: services(), steps: steps(log), isCancelled: { false }) { _ in }
            let expected = DeviceOptions(sub: "auto-refresh", alias: "iphone", on: on, off: !on, yes: true)
            #expect(log.value == ["autoRenew \(expected)"], "\(action)")
        }
    }

    /// The real command (`DeviceCommand`) over a temp home: it writes `config.json` and nothing else.
    private func real(_ action: MenuAction, config: Config) async throws -> (outcome: MenuActionOutcome, saved: SavedDevice?, files: [String]) {
        try await withTestHome(config: config) { paths, store in
            let outcome = Mutex<MenuActionOutcome?>(nil)
            let runner = FakeRunner { _ in RunResult() }
            let services = Services(
                runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(), home: paths)
            await MenuActionRunner.perform(action, services: services) { result in outcome.withLock { $0 = result } }
            #expect(runner.calls.isEmpty, "no subprocess, no device")
            return (try #require(outcome.withLock { $0 }), try store.load().devices["iphone"], listing(paths.home))
        }
    }

    @Test("the real command writes the setting, takes no operation lock and never reads the ledger")
    func writesConfigOnly() async throws {
        let on = try await real(turnOn, config: menuConfig())
        #expect(on.outcome.kind == .done && on.outcome.headline == "Auto-renew is on for iphone")
        #expect(on.saved?.autoRefresh == true)
        #expect(!on.files.contains(".op.lock") && !on.files.contains("ledger.json"))
        let off = try await real(turnOff, config: menuConfig(auto: ["iphone"]))
        #expect(off.outcome.kind == .done && off.outcome.headline == "Auto-renew is off for iphone")
        #expect(off.saved?.autoRefresh == false)
        #expect(!off.files.contains(".op.lock") && !off.files.contains("ledger.json"))
    }

    @Test("a busy operation lock does not stop it: the setting is not an operation")
    func busyLockIrrelevant() async throws {
        try await withTestHome(config: menuConfig()) { paths, store in
            let held = open(paths.opLock, O_CREAT | O_RDWR, 0o600)
            defer { close(held) }
            #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
            let outcome = Mutex<MenuActionOutcome?>(nil)
            let services = Services(
                runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
                keychain: FakeKeychain(), home: paths)
            await MenuActionRunner.perform(turnOn, services: services) { result in outcome.withLock { $0 = result } }
            #expect(outcome.withLock { $0 }?.kind == .done)
            let saved = try store.load().devices["iphone"]
            #expect(saved?.autoRefresh == true)
        }
    }

    @Test("turning it on for a device with an invalid slot reserve fails with the command's own error; turning it off works")
    func invalidReserve() async throws {
        // Out of range, as a hand-edited file could hold it.
        func broken(auto: Bool) throws -> Config {
            let device = #"{"udid":"\#(savedUdid("1"))","coreDeviceId":"\#(savedCoreId("1"))","platform":"ios","freeSlotsReserved":9"#
            return try Config.parse(Data(#"{"devices":{"iphone":\#(device)\#(auto ? #","autoRefresh":true"# : "")}}}"#.utf8))
        }
        #expect(try broken(auto: false).devices["iphone"]?.freeSlotsReserved == nil)
        let offConfig = try broken(auto: false)
        let on = try await real(turnOn, config: offConfig)
        #expect(on.outcome.kind == .failed && on.outcome.headline == "Setting not saved")
        #expect(on.outcome.issues.first?.code == "CONFIG_INVALID")
        #expect(on.outcome.lines.first?.retry == turnOn)
        #expect(on.saved?.autoRefresh == false)
        let off = try await real(turnOff, config: broken(auto: true))
        #expect(off.outcome.kind == .done && off.saved?.autoRefresh == false)
    }

    @Test("the outcome texts: headline and note for each state, and a failure keeps the command's errors")
    func outcomes() {
        let on = MenuActionOutcome(action: turnOn, envelope: .result("device auto-refresh"), cancelled: false)
        #expect(on.kind == .done && on.headline == "Auto-renew is on for iphone")
        #expect(on.notes == [MenuActionOutcome.autoRenewOnNote] && on.lines.isEmpty && on.proceed == nil)
        let off = MenuActionOutcome(action: turnOff, envelope: .result("device auto-refresh"), cancelled: false)
        #expect(off.kind == .done && off.headline == "Auto-renew is off for iphone")
        #expect(off.notes == [MenuActionOutcome.autoRenewOffNote])
        #expect(off.notes[0].contains("expire after 7 days") && on.notes[0].contains("Nothing was renewed now"))

        let failed = Envelope.fail("device auto-refresh", code: "DEVICE_NOT_SAVED", message: "No saved device.", fix: "Save it.")
        let bad = MenuActionOutcome(action: turnOn, envelope: failed, cancelled: false)
        #expect(bad.kind == .failed && bad.headline == "Setting not saved" && bad.notes.isEmpty)
        #expect(bad.issues.map(\.code) == ["DEVICE_NOT_SAVED"] && bad.lines.first?.retry == turnOn)
        // A cancel that arrives after a failed instant command still reads as cancelled, with no stale notes.
        let cancelled = MenuActionOutcome(action: turnOn, envelope: failed, cancelled: true)
        #expect(cancelled.kind == .cancelled)
    }
}

/// What the CLI's `device auto-refresh` or a hand edit would do while the panel is open.
private func setAutoRenew(_ on: Bool, _ paths: Paths) async throws {
    try await ConfigStore(paths: paths).update { config in
        if var device = config.devices["iphone"] {
            device.autoRefresh = on
            config.devices["iphone"] = device
        }
    }
}

private final class Hold: Sendable {
    private let held = Mutex(true)
    func release() { held.withLock { $0 = false } }
    func wait() async {
        while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
@Suite("menu auto-renew: view model")
struct MenuAutoRenewModelTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let log: Log
        let hold: Hold
        let paths: Paths
        let dir: URL
    }

    /// One reachable device, auto-renew off, Apollo recorded. `refresh` waits for `hold`; the auto-renew step is the real
    /// command over the temp home (it logs through a wrapper).
    private func loadedWorld() async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(paths, config: menuConfig(), ledger: menuLedger([("iphone", "apollo", 5.5)]))
        let list = deviceListJSON(phoneEntryJSON(seed: "1"))
        let runner = SlowDeviceRunner(menuDeviceScript(devices: list, apps: { _ in .apps([menuBundleId("apollo")]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow), keychain: FakeKeychain(), home: paths)
        let log = Log()
        let hold = Hold()
        var steps = MenuActionSteps()
        steps.autoRenew = { services, options in
            log.add("autoRenew on=\(options.on) off=\(options.off) yes=\(options.yes)")
            return await DeviceCommand.run(services, options)
        }
        steps.refresh = { _, _ in
            log.add("refresh")
            await hold.wait()
            return .result("refresh", ["results": []])
        }
        let model = MenuModel(services: services, steps: steps)
        model.reload(force: true)
        await model.loadTask?.value
        return World(model: model, runner: runner, log: log, hold: hold, paths: paths, dir: dir)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    private func card(_ model: MenuModel) -> MenuDeviceCard? {
        if case .loaded(let snapshot) = model.panel { return snapshot.devices.first }
        return nil
    }

    @Test("confirm turns it on: only the config command runs, the card shows the new state and the device is not read again")
    func turnsOn() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(card(w.model)?.autoRenew == false)
        #expect(card(w.model)?.apps.first?.exception == "Auto-renew off")
        let (lists, reads) = (w.runner.lists, w.runner.infoApps.count)

        w.model.request(turnOn)
        guard case .confirming(_, let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(prompt.title == "Turn auto-renew on for iphone")
        #expect(w.log.value.isEmpty)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        try await until { self.card(w.model)?.autoRenew == true }

        #expect(w.log.value == ["autoRenew on=true off=false yes=true"])
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.headline == "Auto-renew is on for iphone")
        #expect(card(w.model)?.apps.first?.exception == nil, "the Auto-renew off label is gone")
        #expect(try ConfigStore(paths: w.paths).load().devices["iphone"]?.autoRefresh == true)
        // Nothing asked the device: no list, no app read, no load.
        try await Task.sleep(for: .milliseconds(100))
        #expect(w.runner.lists == lists && w.runner.infoApps.count == reads && w.model.loadTask == nil)
        // The device's read is still there: the card does not say "Checking apps…".
        #expect(card(w.model)?.liveRead == .read)
    }

    @Test("a load that is running is left alone, and its later repaints already carry the new setting")
    func duringLoad() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let reads = w.runner.infoApps.count
        w.runner.holdList(true)
        w.runner.holdApps(true)
        w.model.reload(force: true)
        try await until { w.model.loadTask != nil }
        w.model.request(turnOn)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        #expect(w.model.loadTask != nil, "the load was not cancelled")
        // Redrawn at once, though the load is still waiting for the device list.
        try await until { self.card(w.model)?.autoRenew == true }
        // The load goes on: the repaint it makes before it reads the device is built from the files as they are now.
        w.runner.holdList(false)
        try await until { w.runner.infoApps.count > reads }
        #expect(w.model.loadTask != nil && card(w.model)?.autoRenew == true)
        #expect(card(w.model)?.apps.first?.exception == nil)
        w.runner.holdApps(false)
        await w.model.loadTask?.value
        #expect(card(w.model)?.autoRenew == true && card(w.model)?.liveRead == .read)
        // Nothing is left over to redraw later: a quiet moment changes nothing and starts no load.
        let lists = w.runner.lists
        try await Task.sleep(for: .milliseconds(100))
        #expect(w.model.loadTask == nil && w.runner.lists == lists && card(w.model)?.autoRenew == true)
    }

    @Test("turning it off from the card, then the offer flips back")
    func turnsOff() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        try await setAutoRenew(true, w.paths)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(card(w.model)?.autoRenew == true)
        w.model.request(turnOff)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        try await until { self.card(w.model)?.autoRenew == false }
        #expect(card(w.model)?.apps.first?.exception == "Auto-renew off")
        let snapshot = try #require(w.model.panelSnapshotForTests)
        let offer = MenuActions.autoRenewOffer(try #require(card(w.model)), snapshot: snapshot, now: testNow)
        #expect(offer.label == "Turn auto-renew on…")
    }

    @Test("a confirm left open while the setting changed elsewhere is blocked and writes nothing")
    func staleConfirm() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.request(turnOn)
        try await setAutoRenew(true, w.paths)
        w.model.reload(force: true)
        await w.model.loadTask?.value
        w.model.confirm()
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected the blocked result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "Not run" && outcome.issues.first?.message == "Already on")
        #expect(w.log.value.isEmpty && !w.model.actionBusy)
    }

    @Test("it is not available while another action is confirmed or runs, and a request then is ignored")
    func gatedByOtherActions() async throws {
        let w = try await loadedWorld()
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let snapshot = try #require(w.model.panelSnapshotForTests)
        #expect(w.model.availability(turnOn, in: snapshot) == .enabled)

        w.model.request(.renew(device: "iphone", app: "apollo"))
        #expect(w.model.availability(turnOn, in: snapshot) == .disabled(MenuActions.controlsBusy))
        w.model.confirm()
        try await until { w.log.value.contains("refresh") }
        #expect(w.model.availability(turnOn, in: snapshot) == .disabled(MenuActions.controlsBusy))
        w.model.request(turnOn)
        w.model.confirm()
        guard case .running = w.model.actionState else {
            Issue.record("the state changed while another action ran: \(w.model.actionState)")
            return
        }
        #expect(w.log.value == ["refresh"])
        w.hold.release()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        #expect(try ConfigStore(paths: w.paths).load().devices["iphone"]?.autoRefresh == false)
    }
}

extension MenuModel {
    fileprivate var panelSnapshotForTests: MenuSnapshot? {
        if case .loaded(let snapshot) = panel { return snapshot }
        return nil
    }
}
