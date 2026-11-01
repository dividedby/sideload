import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

// Add device (design section 12): which devices the picker lists and how it names them, the alias rules, the save, and the
// view model's flow. Fakes and temp homes only.

private func listed(
    _ seed: String, type: String? = "iPad", platform: String = "ios", physical: Bool = true, paired: Bool = true,
    link: String = "connected", transport: DeviceTransport = .wired, udid: String? = nil
) -> ListedDevice {
    ListedDevice(
        name: "Robin's Secret Tablet", udid: udid ?? savedUdid(seed), coreDeviceId: savedCoreId(seed), platform: platform,
        physical: physical, paired: paired, link: link, transport: transport, deviceType: type)
}

private func candidate(_ seed: String = "2", alias: String = "ipad") -> MenuDeviceCandidate {
    MenuDeviceCandidate(
        id: 0, title: "iPad · USB · …\(savedUdid(seed).suffix(4))", match: savedUdid(seed), platform: "ios", suggestedAlias: alias,
        blocked: nil)
}

private let empty = Config(devices: [:])

@Suite("menu add device: candidates")
struct MenuAddDeviceCandidateTests {
    @Test("a saved device, by either ID, a simulator and an unsupported platform are not listed")
    func filtered() {
        let found = MenuAddDevice.candidates(
            [
                listed("1"),
                listed("2"),
                listed("3", udid: savedUdid("1").lowercased()),
                listed("4", physical: false),
                listed("5", type: "appleWatch", platform: "watchos"),
            ], config: menuConfig())
        #expect(found.map(\.match) == [savedUdid("2")])
    }

    @Test("the title is the type, the connection and the last four UDID characters: never the name or a full ID")
    func titles() {
        let found = MenuAddDevice.candidates(
            [
                listed("2"),
                listed("3", type: "iPhone", link: "disconnected", transport: .network),
                listed("4", type: "appleTV", platform: "tvos", link: "unavailable", transport: .network),
                listed("5", type: nil, transport: .unknown),
                listed("6", type: "something new", platform: "tvos", transport: .unknown),
            ], config: empty)
        let tail = { (seed: String) in "…" + savedUdid(seed).suffix(4) }
        #expect(
            found.map(\.title) == [
                "iPad · USB · \(tail("2"))", "iPhone · Wi-Fi · \(tail("3"))", "Apple TV · offline · \(tail("4"))",
                "iOS device · \(tail("5"))", "Apple TV · \(tail("6"))",
            ])
        #expect(found.map(\.platform) == ["ios", "ios", "tvos", "ios", "tvos"])
        for item in found {
            for text in [item.title, item.description, item.debugDescription, "\(item)", "\(MenuAction.saveDevice(alias: "x", candidate: item))"] {
                #expect(!text.contains("Robin") && !text.contains(item.match))
            }
        }
    }

    @Test("an unpaired device says to pair it in Xcode and comes after the ones that can be saved; so does one with no UDID")
    func blocked() throws {
        let found = MenuAddDevice.candidates(
            [
                listed("2", paired: false),
                listed("3", type: "appleTV", platform: "tvos", paired: false),
                listed("4", udid: ""),
                listed("5"),
            ], config: empty)
        #expect(found.map(\.id) == [0, 1, 2, 3])
        #expect(found[0].match == savedUdid("5") && found[0].blocked == nil)
        #expect(found[1].blocked?.contains("pair it in Xcode") == true && found[1].blocked?.contains("USB") == true)
        #expect(found[2].blocked?.contains("pair it in Xcode") == true && found[2].blocked?.contains("Remotes and Devices") == true)
        #expect(found[3].blocked?.contains("No UDID") == true && found[3].match == savedCoreId("4"))
        #expect(!found[3].title.contains(savedCoreId("4")))
    }

    @Test("an entry with no ID at all is not listed")
    func noIds() {
        var device = listed("2", udid: "")
        device.coreDeviceId = nil
        #expect(MenuAddDevice.candidates([device], config: empty).isEmpty)
    }

    @Test("the suggested alias avoids saved aliases, in any case, and the other suggestions")
    func suggested() {
        var config = menuConfig(devices: ["iPad", "iphone"])
        config.devices["ipad-2"] = SavedDevice(udid: savedUdid("7"), coreDeviceId: savedCoreId("7"), platform: "ios")
        let found = MenuAddDevice.candidates(
            [listed("3"), listed("4"), listed("5", type: "iPhone"), listed("6", type: "appleTV", platform: "tvos"), listed("8", type: nil)],
            config: config)
        #expect(found.map(\.suggestedAlias) == ["ipad-3", "ipad-4", "iphone-2", "appletv", "device"])
        for alias in found.map(\.suggestedAlias) { #expect(DeviceCommand.isValidAlias(alias)) }
    }

    @Test("the only device that can be saved is already chosen; with two, or none, nothing is")
    func preselected() {
        let one = MenuAddDevice.candidates([listed("2"), listed("3", paired: false)], config: empty)
        #expect(MenuAddDevice.preselected(one)?.match == savedUdid("2"))
        #expect(MenuAddDevice.preselected(MenuAddDevice.candidates([listed("2"), listed("3")], config: empty)) == nil)
        #expect(MenuAddDevice.preselected(MenuAddDevice.candidates([listed("3", paired: false)], config: empty)) == nil)
        #expect(MenuAddDevice.preselected([]) == nil)
    }

    @Test("the deviceType comes from devicectl's hardware dictionary, modern or legacy")
    func parse() {
        let modern: JSONValue = ["result": ["devices": [["properties": ["hardware": ["deviceType": "iPad", "platform": "iOS"]]]]]]
        let legacy: JSONValue = ["result": ["devices": [["hardwareProperties": ["deviceType": "appleTV", "platform": "tvOS"]]]]]
        #expect(DeviceList.parse(modern).first?.deviceType == "iPad")
        #expect(DeviceList.parse(legacy).first?.deviceType == "appleTV")
    }

    @Test("find lists through devicectl; a failed listing is an issue, never an empty list")
    func find() async throws {
        try await withTestHome(config: menuConfig()) { paths, _ in
            let entries = deviceListJSON(phoneEntryJSON(seed: "1"), phoneEntryJSON(name: "Robin's Secret Tablet", seed: "2"))
            let (services, _) = fakeServices(paths, route: Route(devices: entries))
            guard case .list(let found) = await MenuAddDevice.find(services) else {
                Issue.record("expected a list")
                return
            }
            #expect(found.map(\.match) == [savedUdid("2")])

            let (failing, _) = fakeServices(paths, route: Route(devices: nil, devicectlCode: 1))
            guard case .failed(let issue) = await MenuAddDevice.find(failing) else {
                Issue.record("expected a failure")
                return
            }
            #expect(issue.code == "DEVICECTL_FAILED")
        }
    }
}

@Suite("menu add device: alias, availability and confirm")
struct MenuAddDeviceConfirmTests {
    @Test("an alias follows device save's rule, is trimmed, and cannot repeat a saved one in any case")
    func alias() {
        #expect(MenuAddDevice.aliasProblem("ipad", taken: ["iphone"]) == nil)
        #expect(MenuAddDevice.aliasProblem("  ipad \n", taken: []) == nil)
        #expect(MenuAddDevice.trimmedAlias("  ipad \n") == "ipad")
        #expect(MenuAddDevice.aliasProblem("", taken: []) == "Type an alias")
        #expect(MenuAddDevice.aliasProblem("   ", taken: []) == "Type an alias")
        for bad in ["-ipad", "my ipad", "ipad!", String(repeating: "a", count: 33), "iPäd"] {
            #expect(MenuAddDevice.aliasProblem(bad, taken: [])?.contains("letters") == true)
        }
        #expect(MenuAddDevice.aliasProblem("IPHONE", taken: ["iphone"]) == "IPHONE is already saved")
    }

    @Test("available unless the device is blocked or the alias is not usable; a confirm exists only then")
    func availability() {
        let snapshot = menuBuild()
        let action = MenuAction.saveDevice(alias: "ipad", candidate: candidate())
        #expect(MenuActions.availability(action, in: snapshot, now: testNow) == .enabled)
        #expect(MenuActions.availability(.saveDevice(alias: "iphone", candidate: candidate()), in: snapshot, now: testNow).reason == "iphone is already saved")
        #expect(MenuActions.prompt(for: .saveDevice(alias: "iphone", candidate: candidate()), in: snapshot, now: testNow) == nil)
        var unpaired = candidate()
        unpaired.blocked = "Not paired: pair it in Xcode first"
        #expect(MenuActions.availability(.saveDevice(alias: "ipad", candidate: unpaired), in: snapshot, now: testNow).reason == unpaired.blocked)
        #expect(!MenuActions.cancellable(action))
    }

    @Test("a suspended free team or an unreadable ledger does not stop a save: it touches neither")
    func notAFreeAction() {
        let snapshot = menuBuild(ledger: Ledger(freeSuspended: LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow)), ledgerReadable: false)
        #expect(MenuActions.availability(.saveDevice(alias: "ipad", candidate: candidate()), in: snapshot, now: testNow) == .enabled)
    }

    @Test("the confirm says nothing changes and that registering is separate, with no name or full ID")
    func prompt() throws {
        let item = candidate()
        let prompt = try #require(MenuActions.prompt(for: .saveDevice(alias: "ipad", candidate: item), in: menuBuild(), now: testNow))
        #expect(prompt.title == "Save this device as ipad" && prompt.confirmLabel == "Save device" && !prompt.destructive)
        #expect(prompt.lines[0] == item.title)
        #expect(prompt.lines.contains("Saves it in config.json; the device and the free team are unchanged"))
        #expect(prompt.lines.contains { $0.contains("separate confirm") && $0.contains("free team") })
        #expect(!(prompt.lines + [prompt.title, prompt.runningLabel]).joined().contains(item.match))
    }

    @Test("first run: only saving can be available, against a panel with no devices")
    func firstRunPanel() throws {
        let panel = MenuPanel.firstRun(MenuIssue(code: "NOT_SET_UP", message: "x"))
        let snapshot = try #require(panel.actionSnapshot(now: testNow))
        #expect(snapshot.devices.isEmpty && !snapshot.showsApps)
        #expect(MenuActions.availability(.saveDevice(alias: "ipad", candidate: candidate()), in: snapshot, now: testNow) == .enabled)
        #expect(MenuActions.availability(.install(device: "ipad", app: "apollo"), in: snapshot, now: testNow).reason == "Device not found")
        #expect(MenuPanel.loading.actionSnapshot(now: testNow) == nil)
        #expect(MenuPanel.failed(MenuIssue(code: "X", message: "x")).actionSnapshot(now: testNow) == nil)
    }
}

@Suite("menu add device: the run")
struct MenuAddDeviceRunTests {
    /// Runs `.saveDevice` against a temp home with the real `device save`.
    private func run(
        _ action: MenuAction, config: Config?, devices: JSONValue? = deviceListJSON(phoneEntryJSON(seed: "2"))
    ) async throws -> (outcome: MenuActionOutcome, saved: [String: SavedDevice], lists: Int) {
        try await withTestHome(config: config) { paths, store in
            let (services, runner) = fakeServices(paths, route: Route(devices: devices))
            let outcome = Mutex<MenuActionOutcome?>(nil)
            await MenuActionRunner.perform(action, services: services) { result in outcome.withLock { $0 = result } }
            let lists = runner.calls.filter { $0.args.contains("list") }.count
            return (try #require(outcome.withLock { $0 }), try store.load().devices, lists)
        }
    }

    @Test("the confirmed save is device save --yes for exactly that device: first run included, no config before it")
    func saves() async throws {
        for config in [nil, menuConfig()] as [Config?] {
            let ran = try await run(.saveDevice(alias: "ipad", candidate: candidate()), config: config)
            #expect(ran.outcome.kind == .done && ran.outcome.headline == "Saved ipad")
            #expect(ran.outcome.notes == [MenuActionOutcome.savedDeviceNote])
            #expect(ran.saved["ipad"]?.udid == savedUdid("2") && ran.saved["ipad"]?.platform == "ios")
            #expect(ran.saved["ipad"]?.autoRefresh == false && ran.saved["ipad"]?.freeSlotsReserved == 0)
        }
    }

    @Test("the options are the owner's --yes with the candidate's ID and platform")
    func options() async throws {
        try await withTestHome(config: empty) { paths, _ in
            let (services, _) = fakeServices(paths)
            let seen = Mutex<DeviceOptions?>(nil)
            var steps = MenuActionSteps()
            steps.saveDevice = { _, options in
                seen.withLock { $0 = options }
                return Envelope(ok: true, command: "device save")
            }
            await MenuActionRunner.perform(.saveDevice(alias: "ipad", candidate: candidate()), services: services, steps: steps) { _ in }
            #expect(seen.withLock { $0 } == DeviceOptions(sub: "save", alias: "ipad", match: savedUdid("2"), platform: "ios", yes: true))
        }
    }

    @Test("an alias taken since the panel was drawn, or this device saved under another, runs nothing")
    func stops() async throws {
        let taken = try await run(.saveDevice(alias: "iphone", candidate: candidate()), config: menuConfig())
        #expect(taken.outcome.headline == "Not run" && taken.outcome.issues[0].message == "iphone is already saved")
        #expect(taken.lists == 0 && taken.saved["iphone"]?.udid == savedUdid("1"))

        let again = try await run(.saveDevice(alias: "other", candidate: candidate("1")), config: menuConfig())
        #expect(again.outcome.issues[0].message == "This device is already saved as iphone")
        #expect(again.lists == 0 && again.saved["other"] == nil)
    }

    @Test("a device gone since the picker fails with device save's own error and offers a retry; the result carries no ID")
    func gone() async throws {
        let action = MenuAction.saveDevice(alias: "ipad", candidate: candidate())
        let ran = try await run(action, config: empty, devices: deviceListJSON())
        #expect(ran.outcome.kind == .failed && ran.outcome.headline == "Device not saved")
        #expect(ran.outcome.issues.first?.code == "DEVICE_NOT_FOUND")
        #expect(ran.outcome.lines.first?.retry == action && ran.outcome.lines.first?.retryLabel == "Retry")
        #expect(ran.saved.isEmpty)
        let text = (ran.outcome.issues.map { $0.message + ($0.fix ?? "") } + ran.outcome.notes + [ran.outcome.headline]).joined()
        #expect(!text.contains(savedUdid("2")))
    }
}

@MainActor
@Suite("menu add device: view model")
struct MenuAddDeviceModelTests {
    private struct World {
        let model: MenuModel
        let runner: SlowDeviceRunner
        let dir: URL
    }

    private func world(config: Config?, devices: JSONValue?) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        if let config { try await seed(paths, config: config, ledger: Ledger()) }
        let runner = SlowDeviceRunner(menuDeviceScript(devices: devices, apps: { _ in .apps([]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow), keychain: FakeKeychain(), home: paths)
        let model = MenuModel(services: services)
        model.reload(force: true)
        await model.loadTask?.value
        return World(model: model, runner: runner, dir: dir)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    private func candidates(_ model: MenuModel) -> [MenuDeviceCandidate]? {
        if case .addingDevice(.list(let found)) = model.actionState { return found }
        return nil
    }

    @Test("open, pick, confirm, save: the panel reads the new device afterwards and its card appears")
    func flow() async throws {
        let list = deviceListJSON(phoneEntryJSON(seed: "1"), phoneEntryJSON(name: "Robin's Secret Tablet", seed: "2"))
        let w = try await world(config: menuConfig(), devices: list)
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(w.model.canAddDevice && w.model.savedAliases == ["iphone"])

        w.model.openAddDevice()
        #expect(w.model.actionState == .addingDevice(.looking) && !w.model.controlsEnabled)
        try await until { candidates(w.model) != nil }
        let found = try #require(candidates(w.model))
        #expect(found.map(\.match) == [savedUdid("2")])
        #expect(!w.model.canAddDevice)

        w.model.chooseDevice(found[0], alias: "  ipad ")
        guard case .confirming(let action, let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(action == .saveDevice(alias: "ipad", candidate: found[0]) && prompt.confirmLabel == "Save device")
        // Nothing is saved before the click.
        #expect(try w.model.services.store.load().devices["ipad"] == nil)

        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected a result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "Saved ipad")
        #expect(try w.model.services.store.load().devices["ipad"]?.udid == savedUdid("2"))
        await w.model.loadTask?.value
        guard case .loaded(let snapshot) = w.model.panel else {
            Issue.record("expected a loaded panel")
            return
        }
        #expect(snapshot.showsApps && snapshot.devices.map(\.alias) == ["ipad", "iphone"])
        #expect(w.runner.infoApps.count >= 2)
    }

    @Test("first run: the panel offers Add device, the save writes the first config, and the panel loads")
    func firstRun() async throws {
        let w = try await world(config: nil, devices: deviceListJSON(phoneEntryJSON(seed: "2")))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        guard case .firstRun(let issue) = w.model.panel else {
            Issue.record("expected first run, got \(w.model.panel)")
            return
        }
        #expect(issue.fix == MenuLoader.firstRunFix && issue.fix?.contains("Add device…") == true)
        #expect(w.model.canAddDevice && w.model.savedAliases.isEmpty)

        w.model.openAddDevice()
        try await until { candidates(w.model) != nil }
        let found = try #require(candidates(w.model))
        w.model.chooseDevice(found[0], alias: found[0].suggestedAlias)
        w.model.confirm()
        try await until { !w.model.actionBusy }
        await w.model.loadTask?.value
        guard case .loaded(let snapshot) = w.model.panel else {
            Issue.record("expected a loaded panel, got \(w.model.panel)")
            return
        }
        #expect(snapshot.devices.map(\.alias) == ["device"])
    }

    @Test("a config that does not parse has no Add device")
    func failedPanel() async throws {
        let w = try await world(config: nil, devices: deviceListJSON())
        defer { try? FileManager.default.removeItem(at: w.dir) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: w.model.services.home.config))
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(!w.model.canAddDevice)
        w.model.openAddDevice()
        #expect(w.model.actionState == .idle)
    }

    @Test("Cancel while looking closes the card, and the late answer does not reopen it")
    func cancelWhileLooking() async throws {
        let w = try await world(config: menuConfig(), devices: deviceListJSON(phoneEntryJSON(seed: "2")))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.runner.holdList(true)
        w.model.openAddDevice()
        w.model.dismiss()
        #expect(w.model.actionState == .idle && w.model.controlsEnabled)
        w.runner.holdList(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.model.actionState == .idle)
    }

    @Test("an alias that cannot be used keeps the picker open, with nothing to confirm; a failed listing can be checked again")
    func staysOpen() async throws {
        let w = try await world(config: menuConfig(), devices: deviceListJSON(phoneEntryJSON(seed: "2")))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddDevice()
        try await until { candidates(w.model) != nil }
        let found = try #require(candidates(w.model))
        w.model.chooseDevice(found[0], alias: "iphone")
        #expect(candidates(w.model) == found)
        w.model.findDevices()
        #expect(w.model.actionState == .addingDevice(.looking))
        try await until { candidates(w.model) != nil }
        w.model.dismiss()
        #expect(w.model.actionState == .idle)
    }
}
