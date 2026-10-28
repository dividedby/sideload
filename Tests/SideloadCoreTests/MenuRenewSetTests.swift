import Foundation
import Testing

@testable import SideloadCore

// "Renew all apps" must list exactly what `refresh` will touch: the menu's set comes from `RefreshPolicy.decide` over the
// same facts, and this suite runs the real `RefreshCommand` selection over scripted steps to prove they agree.

private let renewAll = MenuAction.renew(device: "iphone", app: nil)

private func lentSlot(_ app: String) -> LedgerSlot {
    LedgerSlot(device: "iphone", app: app, presence: .absent, lentTo: "lab", since: testNow.addingTimeInterval(-3_600))
}

private struct Fixture {
    var name: String
    var ledger: Ledger
    /// The bundle IDs the device lists; nil is no usable read (offline, locked).
    var device: [String]?
    /// The apps `refresh` is expected to touch.
    var expected: [String]
    /// What "All apps" must be.
    var all: MenuAvailability
    /// The panel holds a read taken before the ledger last learned about the app (a lab `slot return` inside the cache
    /// window): it shows the app absent, while `refresh`'s own fresh snapshot (`device`) shows it.
    var staleRead = false
}

private func fixtures() -> [Fixture] {
    let apollo = menuBundleId("apollo")
    let stremio = menuBundleId("stremio-ios")
    let filler = menuBundleId("filler")
    var list: [Fixture] = []

    list.append(
        Fixture(
            name: "one due, one not, both on the device",
            ledger: menuLedger([("iphone", "stremio-ios", 3), ("iphone", "apollo", 7)]), device: [stremio, apollo],
            expected: ["stremio-ios"], all: .enabled))

    // The reviewer's scenario: offline, a lent app with a signed copy at 4 d, an installed app at 3 d.
    var offline = menuLedger([("iphone", "stremio-ios", 3)])
    offline.freeSigned = [menuSigned("iphone", "apollo", days: 4)]
    offline.slots.append(lentSlot("apollo"))
    SlotRule.project(&offline)
    list.append(
        Fixture(
            name: "offline, lent due and installed due", ledger: offline, device: nil, expected: ["stremio-ios", "apollo"],
            all: .disabled("Connect iphone over Wi-Fi or USB")))

    // Hand-installed (no install record) with a signed copy that is not due: refresh reinstalls it to record it.
    list.append(
        Fixture(
            name: "hand-installed, signed copy fresh", ledger: Ledger(freeSigned: [menuSigned("iphone", "apollo", days: 7)]),
            device: [apollo], expected: ["apollo"], all: .enabled))

    list.append(
        Fixture(
            name: "hand-installed but not on the device", ledger: Ledger(freeSigned: [menuSigned("iphone", "apollo", days: 7)]),
            device: [], expected: [], all: .disabled("No apps to renew")))

    var mixed = menuLedger([("iphone", "apollo", 5)])
    mixed.freeSigned = [menuSigned("iphone", "filler", days: 2)]
    list.append(
        Fixture(
            name: "a recorded and a hand-installed app", ledger: mixed, device: [apollo, filler], expected: ["filler", "apollo"],
            all: .enabled))

    list.append(
        Fixture(
            name: "recorded app the device no longer shows", ledger: menuLedger([("iphone", "apollo", 5)]), device: [],
            expected: [], all: .disabled("No apps to renew")))

    var lent = Ledger(freeSigned: [menuSigned("iphone", "apollo", days: 4), menuSigned("iphone", "filler", days: 8)])
    lent.slots = [lentSlot("apollo"), lentSlot("filler")]
    SlotRule.project(&lent)
    list.append(
        Fixture(
            name: "lent apps: only the one within 6 days, no device needed", ledger: lent, device: nil, expected: ["apollo"],
            all: .enabled))

    list.append(
        Fixture(
            name: "unreadable device, installed due", ledger: menuLedger([("iphone", "apollo", 1)]), device: nil,
            expected: ["apollo"], all: .disabled("Connect iphone over Wi-Fi or USB")))

    // The reviewer's fixture: the cached read predates the slot's seenAt, so the row is unconfirmed and says nothing about
    // the app; refresh reads the device afresh and finds it.
    var returned = menuLedger([("iphone", "apollo", 3)])
    returned.slots[0].seenAt = testNow
    SlotRule.project(&returned)
    list.append(
        Fixture(
            name: "cached read older than the slot record, refresh's own snapshot shows the app", ledger: returned,
            device: [apollo], expected: ["apollo"], all: .disabled("Not confirmed on the device"), staleRead: true))
    return list
}

@Suite("menu actions: Renew all apps lists what refresh touches")
struct MenuRenewSetTests {
    private func snapshot(_ fixture: Fixture) -> MenuSnapshot {
        guard let ids = fixture.device else { return menuBuild(ledger: fixture.ledger, probe: .listed([])) }
        if fixture.staleRead {
            let old = testNow.addingTimeInterval(-120)
            return menuBuild(ledger: fixture.ledger, apps: ["iphone": .read(menuSnapshot([]), takenAt: old)])
        }
        return menuBuild(ledger: fixture.ledger, apps: ["iphone": .read(menuSnapshot(ids), takenAt: testNow)])
    }

    /// The apps a real `refresh --force` run does anything to, on the same ledger and device answer.
    private func touched(_ fixture: Fixture) async throws -> [String] {
        try await withTestHome(config: menuConfig()) { paths, _ in
            try await LedgerStore(paths: paths).update { $0 = fixture.ledger }
            let services = Services(
                runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
                keychain: FakeKeychain(), home: paths)
            var steps = RefreshSteps()
            steps.provision = { _, o in .result("provision", ["app": .string(o.app ?? ""), "appIdNew": false]) }
            steps.sign = { _, o in .result("sign", ["app": .string(o.app ?? "")]) }
            steps.install = { _, o in .result("install", ["app": .string(o.app ?? "")]) }
            let ids = fixture.device
            steps.snapshot = { _, _, _ in
                if let ids { return FreeDeviceCalls.SnapshotRead(snapshot: menuSnapshot(ids), error: nil, takenAt: testNow) }
                return FreeDeviceCalls.SnapshotRead(
                    snapshot: nil, error: SideloadError("DEVICE_NOT_CONNECTED", "The device is not connected."), takenAt: testNow)
            }
            let out = await RefreshCommand.run(
                services, RefreshOptions(device: "iphone", force: true, yes: true), steps: steps,
                timeZone: TimeZone(identifier: "UTC")!)
            guard case .array(let results)? = out.data["results"] else { return [] }
            return results.compactMap { item -> String? in
                guard case .string(let app)? = item["app"], case .string(let status)? = item["status"], status != "skipped" else {
                    return nil
                }
                return app
            }
        }
    }

    @Test("the menu's set is the set the real refresh selection touches, in its order, for every fixture")
    func crossCheck() async throws {
        for fixture in fixtures() {
            let card = snapshot(fixture).devices[0]
            let real = try await touched(fixture)
            #expect(card.refreshSet.map(\.app) == real, "\(fixture.name): menu \(card.refreshSet.map(\.app)) vs refresh \(real)")
            #expect(real == fixture.expected, "\(fixture.name): refresh touched \(real)")
        }
    }

    @Test("All apps is enabled only when every app in the set is, with the first blocked app's reason")
    func availability() {
        for fixture in fixtures() {
            let result = MenuActions.availability(renewAll, in: snapshot(fixture), now: testNow)
            #expect(result == fixture.all, "\(fixture.name)")
        }
    }

    @Test("the confirm lists every app the run touches and asks to keep the device connected when any is installed")
    func confirmLists() throws {
        for fixture in fixtures() where fixture.all == .enabled {
            let prompt = try #require(MenuActions.prompt(for: renewAll, in: snapshot(fixture), now: testNow), "\(fixture.name)")
            let listed = prompt.lines.dropFirst().prefix { !$0.hasPrefix("Portal:") }
            let names = listed.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
            #expect(names == fixture.expected.map(MenuActions.displayName), "\(fixture.name): \(prompt.lines)")
            let installs = fixture.expected.contains { !($0 == "apollo" && fixture.name.hasPrefix("lent")) }
            #expect(prompt.lines.contains("Keep the device unlocked and connected") == installs, "\(fixture.name)")
        }
    }

    @Test("the reviewer's scenario: offline, a lent app due and an installed app due: All is off and names the connection")
    func offlineMix() throws {
        let fixture = fixtures()[1]
        let snapshot = snapshot(fixture)
        #expect(MenuActions.availability(.renew(device: "iphone", app: "stremio-ios"), in: snapshot, now: testNow) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(MenuActions.availability(.renew(device: "iphone", app: "apollo"), in: snapshot, now: testNow) == .enabled)
        #expect(MenuActions.availability(renewAll, in: snapshot, now: testNow) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(MenuActions.prompt(for: renewAll, in: snapshot, now: testNow) == nil)
    }

    @Test("a hand-installed app with a fresh signed copy is renewable on its own too, and is listed by All")
    func handInstalled() throws {
        let fixture = fixtures()[2]
        let snapshot = snapshot(fixture)
        #expect(MenuActions.availability(.renew(device: "iphone", app: "apollo"), in: snapshot, now: testNow) == .enabled)
        let prompt = try #require(MenuActions.prompt(for: renewAll, in: snapshot, now: testNow))
        #expect(prompt.lines.contains("Apollo"))
    }
}
