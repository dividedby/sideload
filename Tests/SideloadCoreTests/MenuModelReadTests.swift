import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

/// Answers like `menuDeviceScript`, but each `device info apps` call takes a moment, so two overlapping calls show up in
/// `maxInFlight`. Records the saved CoreDevice ID each call was addressed to, in order.
private final class SlowDeviceRunner: Runner {
    private struct State {
        var inFlight = 0
        var maxInFlight = 0
        var infoApps: [String] = []
        var lists = 0
        var holdList = false
        var holdApps = false
    }

    private let state = Mutex(State())
    private let script: FakeRunner.Script

    init(_ script: @escaping FakeRunner.Script) { self.script = script }

    var infoApps: [String] { state.withLock { $0.infoApps } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var lists: Int { state.withLock { $0.lists } }

    /// While held, `list devices` does not answer.
    func holdList(_ hold: Bool) { state.withLock { $0.holdList = hold } }

    /// While held, `device info apps` does not answer.
    func holdApps(_ hold: Bool) { state.withLock { $0.holdApps = hold } }

    func run(_ spec: CommandSpec) async -> RunResult {
        let isApps = spec.args.contains("apps")
        state.withLock { st in
            if spec.args.contains("list") { st.lists += 1 }
            guard isApps else { return }
            st.inFlight += 1
            st.maxInFlight = max(st.maxInFlight, st.inFlight)
            st.infoApps.append(spec.args.firstIndex(of: "--device").map { spec.args[$0 + 1] } ?? "")
        }
        if isApps {
            try? await Task.sleep(for: .milliseconds(30))
            while state.withLock({ $0.holdApps }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        if spec.args.contains("list") {
            while state.withLock({ $0.holdList }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let result = script(spec)
        if isApps { state.withLock { $0.inFlight -= 1 } }
        return result
    }
}

private func seed(_ paths: Paths, config: Config, ledger: Ledger) async throws {
    try await ConfigStore(paths: paths).update { $0 = config }
    try await LedgerStore(paths: paths).update { $0 = ledger }
}

@MainActor
@Suite("menu: view model reads the apps of visible devices")
struct MenuModelReadTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let clock: MutableClock
        let dir: URL
    }

    /// Three saved devices: iphone and ipad reachable, appletv offline. `iphone` and `ipad` have one app each recorded.
    private func world(apps: @escaping @Sendable (String) -> RunResultWithJSON) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(
            paths, config: menuConfig(devices: ["iphone", "ipad", "appletv"]),
            ledger: menuLedger([("iphone", "apollo", 5), ("ipad", "apollo", 4)]))
        let list = deviceListJSON(
            phoneEntryJSON(seed: "1"), phoneEntryJSON(seed: "2"), phoneEntryJSON(seed: "3", tunnel: "unavailable"))
        let runner = SlowDeviceRunner(menuDeviceScript(devices: list, apps: apps))
        let clock = MutableClock(testNow)
        let services = Services(runner: runner, fs: FakeFileSystem.free(gb: 50), clock: clock, keychain: FakeKeychain(), home: paths)
        return World(model: MenuModel(services: services), runner: runner, clock: clock, dir: dir)
    }

    private func settle(_ model: MenuModel) async { await model.loadTask?.value }

    private func loaded(_ model: MenuModel) -> MenuSnapshot? {
        if case .loaded(let snapshot) = model.panel { return snapshot }
        return nil
    }

    private func rows(_ model: MenuModel) -> [String: [AppPresence]] {
        guard case .loaded(let snapshot) = model.panel else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.devices.map { ($0.alias, $0.apps.map(\.presence)) })
    }

    @Test("launch reads each visible device once, one after the other; an offline device is not asked")
    func launch() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.reload()
        await settle(w.model)
        // Sorted by alias: ipad (seed 2) before iphone (seed 1); the Apple TV (seed 3) is offline.
        #expect(w.runner.infoApps == [savedCoreId("2"), savedCoreId("1")])
        #expect(w.runner.maxInFlight == 1)
        #expect(w.runner.lists == 1)
        #expect(rows(w.model) == ["iphone": [.installed], "ipad": [.installed], "appletv": []])
        let snapshot = try #require(loaded(w.model))
        #expect(!snapshot.checkingApps && !snapshot.checkingDevices)
    }

    @Test("an open within 5 minutes reads nothing; Check status now reads every visible device; an open after 5 minutes reads again")
    func cadence() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 2)

        // Inside the 2 s debounce nothing runs at all.
        w.clock.advance(1)
        w.model.reload()
        #expect(w.model.loadTask == nil)
        #expect(w.runner.lists == 1)

        w.clock.advance(60)
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.lists == 2)
        #expect(w.runner.infoApps.count == 2)
        #expect(rows(w.model)["iphone"] == [.installed])

        w.model.reload(force: true)
        await settle(w.model)
        #expect(w.runner.infoApps.count == 4)

        w.clock.advance(299)
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 4)

        w.clock.advance(2)
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 6)
        #expect(w.runner.maxInFlight == 1)
    }

    @Test("a failed attempt is not retried on the next open; the rows keep the ledger's record and the card says why")
    func failedAttempt() async throws {
        let w = try await world { _ in .locked }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 2)
        #expect(rows(w.model)["iphone"] == [.unconfirmed])
        let snapshot = try #require(loaded(w.model))
        #expect(snapshot.devices.first { $0.alias == "iphone" }?.appsNote == "Couldn't check apps (device locked) · showing last known")

        w.clock.advance(30)
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 2)

        // The owner's explicit check tries again.
        w.model.reload(force: true)
        await settle(w.model)
        #expect(w.runner.infoApps.count == 4)
    }

    @Test("a device that went offline is forgotten and read afresh when it comes back")
    func forgotten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(paths, config: menuConfig(), ledger: menuLedger([("iphone", "apollo", 5)]))
        let reachable = Mutex(true)
        let script: FakeRunner.Script = { spec in
            let up = reachable.withLock { $0 }
            let list = deviceListJSON(phoneEntryJSON(seed: "1", tunnel: up ? "connected" : "unavailable"))
            return menuDeviceScript(devices: list, apps: { _ in .apps([menuBundleId("apollo")]) })(spec)
        }
        let runner = SlowDeviceRunner(script)
        let clock = MutableClock(testNow)
        let model = MenuModel(
            services: Services(runner: runner, fs: FakeFileSystem.free(gb: 50), clock: clock, keychain: FakeKeychain(), home: paths))
        model.reload()
        await model.loadTask?.value
        #expect(runner.infoApps.count == 1)

        reachable.withLock { $0 = false }
        clock.advance(10)
        model.reload()
        await model.loadTask?.value
        #expect(runner.infoApps.count == 1)
        let offline = try #require(loaded(model))
        #expect(offline.devices[0].apps.map(\.presence) == [.unconfirmed])

        reachable.withLock { $0 = true }
        clock.advance(10)
        model.reload()
        await model.loadTask?.value
        #expect(runner.infoApps.count == 2)
    }

    @Test("the model takes no lock and leaves the ledger and the config as they were")
    func readOnly() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        let paths = Paths(home: w.dir.path)
        let config = try Data(contentsOf: URL(fileURLWithPath: paths.config))
        let ledger = try Data(contentsOf: URL(fileURLWithPath: paths.ledger))
        try? FileManager.default.removeItem(atPath: paths.opLock)
        w.model.reload()
        await settle(w.model)
        #expect(!FileManager.default.fileExists(atPath: paths.opLock))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.config)) == config)
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) == ledger)
    }

    @Test("Check status now during a running load is not dropped: it runs once that load ends and reads every visible device")
    func forceDuringLoad() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 2)

        // An open whose `list devices` is slow; the owner presses Check status now meanwhile. The cached reads are fresh,
        // so the open alone would read nothing.
        w.clock.advance(10)
        w.runner.holdList(true)
        let before = w.runner.lists
        w.model.reload()
        while w.runner.lists == before { try await Task.sleep(for: .milliseconds(5)) }
        w.model.reload(force: true)
        w.runner.holdList(false)
        var waited = 0
        while w.model.loadTask != nil || w.runner.lists < before + 2, waited < 1_000 {
            await w.model.loadTask?.value
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(w.runner.lists == before + 2)
        #expect(w.runner.infoApps.count == 4)
        #expect(w.runner.maxInFlight == 1)

        // Not remembered beyond that one run.
        w.clock.advance(10)
        w.model.reload()
        await settle(w.model)
        #expect(w.runner.infoApps.count == 4)
    }

    @Test("every visible device still to be read says checking from the start, not when its turn comes")
    func allDueDevicesCheckingAtOnce() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.runner.holdApps(true)
        w.model.reload()
        // The first device (ipad) is being read and is held; iphone has not had its turn.
        while w.runner.infoApps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let midway = try #require(loaded(w.model))
        #expect(rows(w.model) == ["iphone": [.checking], "ipad": [.checking], "appletv": []])
        #expect(midway.checkingApps)

        w.runner.holdApps(false)
        await settle(w.model)
        #expect(rows(w.model) == ["iphone": [.installed], "ipad": [.installed], "appletv": []])
    }

    @Test("a reload paints what the last load learned at once: no checking rows, and nothing changes when the answers agree")
    func firstPaintKeepsWhatIsKnown() async throws {
        let w = try await world { _ in .apps([menuBundleId("apollo")]) }
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.reload()
        await settle(w.model)
        let settled = try #require(loaded(w.model))
        #expect(settled.devices.allSatisfy { $0.presence != .checking })

        // The second load's `list devices` is held, so the panel shows only its first paint.
        w.runner.holdList(true)
        let before = w.runner.lists
        w.model.reload(force: true)
        while w.runner.lists == before { try await Task.sleep(for: .milliseconds(5)) }
        let first = try #require(loaded(w.model))
        #expect(first == settled)
        #expect(!first.checkingDevices && !first.checkingApps)
        #expect(rows(w.model) == ["iphone": [.installed], "ipad": [.installed], "appletv": []])

        w.runner.holdList(false)
        await settle(w.model)
        #expect(rows(w.model) == ["iphone": [.installed], "ipad": [.installed], "appletv": []])
    }
}
