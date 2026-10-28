import Foundation
import Testing

@testable import SideloadCore

// The menu action rules (design section 12): availability and its exact reasons, the confirm text, the row offers.

func menuSigned(_ device: String, _ app: String, days: Double, uuid: String = "UUID-1") -> LedgerFreeSigned {
    LedgerFreeSigned(
        id: "\(device)/\(app)", device: device, app: app, bundleId: menuBundleId(app), version: "1.0",
        sha256Prefix: "0a1b2c3d", profileUuid: uuid, profileExpires: daysFromNow(days), certFp8: "12345678",
        signedAt: testNow, path: "builds/signed/x", strippedExtensions: [], droppedEntitlements: [])
}

private let apolloBid = menuBundleId("apollo")
private let stremioBid = menuBundleId("stremio-ios")

private func read(_ ids: [String]) -> [String: DeviceAppsProbe] {
    ["iphone": .read(menuSnapshot(ids), takenAt: testNow)]
}

private func op() -> LedgerSlotOp {
    LedgerSlotOp(kind: .install, by: .install, startedAt: testNow, window: SlotRule.window(.install))
}


private func availability(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuAvailability {
    MenuActions.availability(action, in: snapshot, now: testNow)
}

private let renewApollo = MenuAction.renew(device: "iphone", app: "apollo")
private let renewAll = MenuAction.renew(device: "iphone", app: nil)

extension MenuSnapshot {
    fileprivate static var empty: MenuSnapshot { menuBuild() }
}

@Suite("menu actions: availability")
struct MenuActionAvailabilityTests {
    @Test("Renew: an installed app at 6 days or fewer, on a visible device with a live read")
    func renewWindow() {
        for (days, ok) in [(5.0, true), (6.0, true), (6.01, false), (7.0, false), (-1.0, true)] {
            let snapshot = menuBuild(ledger: menuLedger([("iphone", "apollo", days)]), apps: read([apolloBid]))
            let result = availability(renewApollo, snapshot)
            #expect(result == (ok ? .enabled : .disabled("renewable at 6 d left")), "\(days)")
        }
    }

    @Test("Renew and Install need a visible device and a successful read; the reasons are exact")
    func deviceRule() {
        let ledger = menuLedger([("iphone", "apollo", 3)])
        let offline = menuBuild(ledger: ledger, probe: .listed([]))
        #expect(availability(renewApollo, offline) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(availability(renewAll, offline) == .disabled("Connect iphone over Wi-Fi or USB"))
        let locked = menuBuild(ledger: ledger, apps: ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)])
        #expect(availability(renewApollo, locked) == .disabled("Couldn't check apps"))
        let unknown = menuBuild(ledger: ledger, probe: .failed)
        #expect(availability(renewApollo, unknown) == .disabled("Couldn't check apps"))
        let checking = menuBuild(ledger: ledger, apps: ["iphone": .checking])
        #expect(availability(renewApollo, checking) == .disabled("Checking apps…"))
        let notAsked = menuBuild(ledger: ledger)
        #expect(availability(renewApollo, notAsked) == .disabled("Checking apps…"))
        // The Install rule is the same.
        var signedLedger = ledger
        signedLedger.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let installOffline = menuBuild(ledger: signedLedger, probe: .listed([]))
        #expect(availability(.install(device: "iphone", app: "apollo"), installOffline) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(availability(.remove(device: "iphone", app: "apollo"), offline) == .disabled("Connect iphone over Wi-Fi or USB"))
    }

    @Test("a lent app's Renew needs no device, only a signed build within 6 days")
    func lentRenew() {
        var ledger = Ledger()
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 4)]
        ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&ledger)
        let offline = menuBuild(ledger: ledger, probe: .listed([]))
        #expect(offline.devices[0].renew.items.compactMap(\.app) == ["apollo"])
        #expect(availability(renewApollo, offline) == .enabled)
        #expect(availability(renewAll, offline) == .enabled)
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 7)]
        let far = menuBuild(ledger: ledger, probe: .listed([]))
        #expect(availability(renewApollo, far) == .disabled("renewable at 6 d left"))
        #expect(availability(renewAll, far) == .disabled("renewable at 6 d left"))
    }

    @Test("All apps is enabled when at least one app in the set is available, and says why when none is")
    func allApps() {
        let near = menuLedger([("iphone", "apollo", 7), ("iphone", "stremio-ios", 2)])
        let snapshot = menuBuild(ledger: near, apps: read([apolloBid, stremioBid]))
        #expect(availability(renewAll, snapshot) == .enabled)
        #expect(availability(renewApollo, snapshot) == .disabled("renewable at 6 d left"))
        let none = menuBuild(ledger: menuLedger([("iphone", "apollo", 7)]), apps: read([apolloBid]))
        #expect(availability(renewAll, none) == .disabled("renewable at 6 d left"))
        #expect(availability(renewAll, menuBuild(apps: read([]))) == .disabled("No apps to renew"))
    }

    @Test("the free certificate changing, an unreadable ledger and a change in progress stop every free action")
    func freeStops() {
        var ledger = menuLedger([("iphone", "apollo", 3)])
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let actions: [MenuAction] = [renewApollo, renewAll, .install(device: "iphone", app: "apollo"), .remove(device: "iphone", app: "apollo")]

        var suspended = ledger
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        let frozen = menuBuild(ledger: suspended, apps: read([apolloBid]))
        for action in actions { #expect(availability(action, frozen) == .disabled("Free certificate changed"), "\(action)") }

        let unreadable = menuBuild(ledger: ledger, apps: read([apolloBid]), ledgerReadable: false)
        for action in actions { #expect(availability(action, unreadable).isEnabled == false, "\(action)") }

        var pending = ledger
        pending.slots.append(LedgerSlot(device: "iphone", app: "stremio-ios", presence: .unknown, op: op()))
        SlotRule.project(&pending)
        let busy = menuBuild(ledger: pending, apps: read([apolloBid]))
        #expect(busy.devices[0].hasPending)
        for action in actions { #expect(availability(action, busy) == .disabled("Change in progress on iphone"), "\(action)") }
    }

    @Test("Install: a free slot is needed for an app that is not on the device; a signed build that has not expired")
    func install() {
        var ledger = menuLedger([("iphone", "apollo", 5)])
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let install = MenuAction.install(device: "iphone", app: "apollo")
        let gone = menuBuild(ledger: ledger, apps: read([]))
        #expect(gone.devices[0].apps.map(\.presence) == [.notInstalled])
        #expect(availability(install, gone) == .enabled)

        let full = menuBuild(config: menuConfig(reserved: ["iphone": 3]), ledger: ledger, apps: read([]))
        #expect(full.devices[0].freeSlots == 0)
        #expect(availability(install, full) == .disabled("No free slot: remove an app first"))

        var expired = ledger
        expired.freeSigned = [menuSigned("iphone", "apollo", days: -1)]
        let stale = availability(install, menuBuild(ledger: expired, apps: read([])))
        #expect(stale.reason?.contains("`sideload provision --app apollo --device iphone --yes`, then `sideload sign --app apollo --device iphone --yes`") == true)

        var unsigned = ledger
        unsigned.freeSigned = []
        let unsignedReason = availability(install, menuBuild(ledger: unsigned, apps: read([]))).reason
        #expect(unsignedReason == "Not signed yet: the owner runs `sideload sign --app apollo --device iphone --yes` first")

        // An installed app only offers the slot-neutral update, and only when a newer build is signed.
        let installed = menuBuild(ledger: ledger, apps: read([apolloBid]))
        #expect(availability(install, installed) == .disabled("Already installed"))
        var newer = ledger
        newer.freeSigned = [menuSigned("iphone", "apollo", days: 7, uuid: "UUID-2")]
        let update = menuBuild(ledger: newer, apps: read([apolloBid]))
        #expect(update.devices[0].apps[0].newerSigned)
        #expect(availability(install, update) == .enabled)
    }

    @Test("after app remove a fresh read confirms the signed app absent: a Signed · not installed row with Install; a stale read or none shows no row")
    func removedThenReinstall() {
        var ledger = Ledger(freeSigned: [menuSigned("iphone", "apollo", days: 5)])
        ledger.installs = [menuInstall("iphone", "apollo", days: 5, present: false)]
        ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, seenAt: testNow)]
        SlotRule.project(&ledger)
        let install = MenuAction.install(device: "iphone", app: "apollo")

        let fresh = menuBuild(ledger: ledger, apps: read([]))
        let card = fresh.devices[0]
        #expect(card.apps.map(\.presence) == [.notInstalled])
        #expect(card.apps[0].daysLabel == "Signed · not installed" && !card.apps[0].showsBar)
        #expect(card.freeSlots == 3 && fresh.icon.remaining == nil, "it holds no slot and is out of the ring")
        #expect(card.renew.items.compactMap(\.app).isEmpty)
        #expect(availability(install, fresh) == .enabled)
        #expect(MenuActions.rowOffers(card.apps[0], card: card, snapshot: fresh, now: testNow).map(\.label) == ["Install"])

        let full = menuBuild(config: menuConfig(reserved: ["iphone": 3]), ledger: ledger, apps: read([]))
        #expect(availability(install, full) == .disabled("No free slot: remove an app first"))

        let stale = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([]), takenAt: testNow.addingTimeInterval(-120))])
        #expect(stale.devices[0].apps.isEmpty)
        #expect(menuBuild(ledger: ledger).devices[0].apps.isEmpty)
    }

    @Test("newerSigned needs a different profile more than a day later that has not expired")
    func newerSigned() {
        func newer(_ days: Double, uuid: String) -> Bool {
            var ledger = menuLedger([("iphone", "apollo", 5)])
            ledger.freeSigned = [menuSigned("iphone", "apollo", days: days, uuid: uuid)]
            return menuBuild(ledger: ledger, apps: read([apolloBid])).devices[0].apps[0].newerSigned
        }
        #expect(newer(7, uuid: "UUID-2"))
        #expect(!newer(7, uuid: "UUID-1"))
        #expect(!newer(5.5, uuid: "UUID-2"))
        #expect(!newer(5, uuid: "UUID-2"))
    }

    @Test("Remove: an installed row on a live read; lent, pending, checking and unconfirmed rows say why not")
    func remove() {
        let remove = MenuAction.remove(device: "iphone", app: "apollo")
        let ledger = menuLedger([("iphone", "apollo", 5)])
        #expect(availability(remove, menuBuild(ledger: ledger, apps: read([apolloBid]))) == .enabled)
        #expect(availability(remove, menuBuild(ledger: ledger, apps: read([]))) == .disabled("Not installed"))
        #expect(availability(remove, menuBuild(ledger: ledger, apps: ["iphone": .checking])) == .disabled("Checking apps…"))
        #expect(availability(remove, menuBuild(ledger: ledger, probe: .failed)) == .disabled("Couldn't check apps"))

        var lent = Ledger()
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        #expect(availability(remove, menuBuild(ledger: lent, apps: read([]))) == .disabled("Lent to lab"))
        #expect(availability(remove, menuBuild(ledger: lent, probe: .listed([]))) == .disabled("Lent to lab"))

        var pending = ledger
        pending.slots[0].op = op()
        SlotRule.project(&pending)
        #expect(availability(remove, menuBuild(ledger: pending, apps: read([apolloBid]))) == .disabled("Change in progress on iphone"))
    }

    @Test("Lendable: needs no device; the choices follow the platform; not while an app is lent or changing")
    func lendable() {
        let config = menuConfig(devices: ["iphone", "appletv"])
        let snapshot = menuBuild(config: config, probe: .listed([]))
        let ios = snapshot.devices.first { $0.alias == "iphone" }!
        let tv = snapshot.devices.first { $0.alias == "appletv" }!
        #expect(MenuActions.lendableChoices(ios) == ["stremio-ios", "apollo", "filler"])
        #expect(MenuActions.lendableChoices(tv) == ["stremio-tvos"])
        #expect(availability(.lendable(device: "iphone", app: "apollo"), snapshot) == .enabled)
        #expect(availability(.lendable(device: "iphone", app: nil), snapshot) == .disabled("Already set"))
        #expect(availability(.lendable(device: "iphone", app: "stremio-tvos"), snapshot).isEnabled == false)

        var lent = Ledger()
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        let during = menuBuild(ledger: lent)
        #expect(availability(.lendable(device: "iphone", app: "filler"), during) == .disabled("An app is lent or changing on iphone"))
        var pending = Ledger()
        pending.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .unknown, op: op())]
        SlotRule.project(&pending)
        #expect(availability(.lendable(device: "iphone", app: "filler"), menuBuild(ledger: pending)).isEnabled == false)
        // Free-certificate stops do not apply to a setting.
        var suspended = Ledger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        #expect(availability(.lendable(device: "iphone", app: "apollo"), menuBuild(ledger: suspended)) == .enabled)
    }

    @Test("row offers: Retry on a failed renewal, Install or Install update, Remove")
    func offers() {
        var ledger = menuLedger([("iphone", "apollo", 5)])
        ledger.installs[0].refresh = LedgerInstallRefresh(lastResult: "failed", lastCode: "DEVICE_LOCKED")
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 7, uuid: "UUID-2")]
        let snapshot = menuBuild(ledger: ledger, apps: read([apolloBid]))
        let card = snapshot.devices[0]
        let labels = MenuActions.rowOffers(card.apps[0], card: card, snapshot: snapshot, now: testNow).map(\.label)
        #expect(labels == ["Retry", "Install update", "Remove"])
        #expect(MenuActions.rowOffers(card.apps[0], card: card, snapshot: snapshot, now: testNow).map(\.kind) == [.retry, .installUpdate, .remove])
        let remove = MenuActions.rowOffers(card.apps[0], card: card, snapshot: snapshot, now: testNow).last
        #expect(remove?.destructive == true && remove?.availability == .enabled)

        let gone = menuBuild(ledger: menuLedger([("iphone", "apollo", 5)]), apps: read([]))
        let goneCard = gone.devices[0]
        #expect(MenuActions.rowOffers(goneCard.apps[0], card: goneCard, snapshot: gone, now: testNow).map(\.label) == ["Install"])
    }
}

@Suite("menu actions: reconfirm")
struct MenuReconfirmTests {
    private func snapshot(appIds: [LedgerFreeAppId] = [], suspended: Bool = false) -> MenuSnapshot {
        var ledger = menuLedger([("iphone", "apollo", 3)])
        ledger.freeAppIds = appIds
        if suspended { ledger.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow) }
        return menuBuild(ledger: ledger, apps: read([apolloBid]))
    }

    @Test("the same confirm runs; a changed line shows the new confirm; an action no longer available is blocked with its reason")
    func outcomes() throws {
        let before = snapshot()
        let shown = try #require(MenuActions.prompt(for: renewApollo, in: before, now: testNow))
        #expect(MenuActions.reconfirm(renewApollo, shown: shown, in: snapshot(), now: testNow) == .run(shown))

        let spent = snapshot(appIds: [LedgerFreeAppId(bundleId: apolloBid, epochStart: daysFromNow(-1))])
        let changed = try #require(MenuActions.prompt(for: renewApollo, in: spent, now: testNow))
        #expect(changed != shown)
        #expect(MenuActions.reconfirm(renewApollo, shown: shown, in: spent, now: testNow) == .show(changed))

        #expect(
            MenuActions.reconfirm(renewApollo, shown: shown, in: snapshot(suspended: true), now: testNow)
                == .blocked("Free certificate changed"))
    }

    @Test("a change in the list of apps alone is a changed confirm")
    func appList() throws {
        var ledger = menuLedger([("iphone", "apollo", 3), ("iphone", "stremio-ios", 2)])
        ledger.freeSigned = []
        let both = menuBuild(ledger: ledger, apps: read([apolloBid, stremioBid]))
        let shown = try #require(MenuActions.prompt(for: renewAll, in: both, now: testNow))
        #expect(shown.apps == ["stremio-ios", "apollo"])
        let one = menuBuild(ledger: ledger, apps: read([apolloBid]))
        guard case .show(let now) = MenuActions.reconfirm(renewAll, shown: shown, in: one, now: testNow) else {
            Issue.record("expected a changed confirm")
            return
        }
        #expect(now.apps == ["apollo"])
    }
}

@Suite("menu actions: the confirm")
struct MenuActionPromptTests {
    private func prompt(_ action: MenuAction, _ snapshot: MenuSnapshot) throws -> MenuPrompt {
        try #require(MenuActions.prompt(for: action, in: snapshot, now: testNow))
    }

    private func world(freeAppIds: [LedgerFreeAppId] = []) -> MenuSnapshot {
        var ledger = menuLedger([("iphone", "apollo", 3), ("iphone", "stremio-ios", 2)])
        ledger.freeAppIds = freeAppIds
        return menuBuild(ledger: ledger, apps: read([apolloBid, stremioBid]))
    }

    @Test("an unavailable action has no confirm")
    func none() {
        let snapshot = menuBuild(ledger: menuLedger([("iphone", "apollo", 7)]), apps: read([apolloBid]))
        #expect(MenuActions.prompt(for: renewApollo, in: snapshot, now: testNow) == nil)
    }

    @Test("Renew names the alias and the app, states the App ID budget and the slots, and ends with the keychain line")
    func renew() throws {
        let ids = [LedgerFreeAppId(bundleId: apolloBid, epochStart: daysFromNow(-1))]
        let snapshot = world(freeAppIds: ids)
        let one = try prompt(renewApollo, snapshot)
        #expect(one.title == "Renew Apollo on iphone" && one.confirmLabel == "Renew" && !one.destructive)
        #expect(one.runningLabel == "Renewing Apollo on iphone…")
        #expect(one.lines.contains("Re-signs and reinstalls Apollo on iphone"))
        #expect(one.lines.contains("Portal: profiles only, normally no new App ID (1 of 10 used in 7 days, 4 reserved)"))
        #expect(one.lines.contains("Slots unchanged"))
        #expect(one.lines.contains("Keep the device unlocked and connected"))
        #expect(one.lines.last == "macOS may ask for keychain access")

        let all = try prompt(renewAll, snapshot)
        #expect(all.title == "Renew all apps on iphone" && all.confirmLabel == "Renew all")
        #expect(all.lines.contains("Apollo") && all.lines.contains("Stremio"))
    }

    @Test("Renew All names a lent app as re-signed only, and a lent-only renew does not ask to keep the device connected")
    func renewLent() throws {
        var ledger = Ledger()
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 4)]
        ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&ledger)
        let snapshot = menuBuild(ledger: ledger, probe: .listed([]))
        let all = try prompt(renewAll, snapshot)
        #expect(all.lines.contains("Apollo: re-signed only, not installed (lent to the lab)"))
        #expect(!all.lines.contains("Keep the device unlocked and connected"))
        #expect(all.lines.last == "macOS may ask for keychain access")
    }

    @Test("Install states the slot arithmetic; an update leaves the slots alone")
    func install() throws {
        var ledger = menuLedger([("iphone", "apollo", 5), ("iphone", "stremio-ios", 4)])
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let snapshot = menuBuild(ledger: ledger, apps: read([stremioBid]))
        #expect(snapshot.devices[0].freeSlots == 2)
        let fresh = try prompt(.install(device: "iphone", app: "apollo"), snapshot)
        #expect(fresh.title == "Install Apollo on iphone")
        #expect(fresh.lines.contains("Slots 1/3 → 2/3"))
        #expect(fresh.lines.contains("Portal: no change"))
        #expect(fresh.lines.last == "macOS may ask for keychain access")

        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 7, uuid: "UUID-2")]
        let update = try prompt(.install(device: "iphone", app: "apollo"), menuBuild(ledger: ledger, apps: read([apolloBid])))
        #expect(update.title == "Install update of Apollo on iphone" && update.confirmLabel == "Install update")
        #expect(update.lines.contains("Slots unchanged"))
    }

    @Test("Remove is destructive, states the slot arithmetic, and warns when it is the last free app")
    func remove() throws {
        let two = try prompt(.remove(device: "iphone", app: "apollo"), world())
        #expect(two.destructive && two.confirmLabel == "Remove")
        #expect(two.lines.first == "Deletes Apollo and its data from iphone, frees a slot (2/3 → 1/3)")
        #expect(!two.lines.contains("Last free app: developer trust is cleared"))

        let alone = menuBuild(ledger: menuLedger([("iphone", "apollo", 3)]), apps: read([apolloBid]))
        let last = try prompt(.remove(device: "iphone", app: "apollo"), alone)
        #expect(last.lines.first == "Deletes Apollo and its data from iphone, frees a slot (1/3 → 0/3)")
        #expect(last.lines.contains("Last free app: developer trust is cleared"))
        #expect(last.lines.last == "macOS may ask for keychain access")
    }

    @Test("Lendable is a setting only and says so; it does not mention the keychain")
    func lendable() throws {
        let snapshot = menuBuild()
        let set = try prompt(.lendable(device: "iphone", app: "apollo"), snapshot)
        #expect(set.lines == ["Setting only: the lab may uninstall Apollo and put it back"])
        let none = try prompt(.lendable(device: "iphone", app: nil), menuBuild(config: menuConfigLendable()))
        #expect(none.title == "Stop lending on iphone")
    }

    @Test("no confirm text carries a device name, an ID or a UDID")
    func noNames() throws {
        var ledger = menuLedger([("iphone", "apollo", 3)])
        ledger.freeSigned = [menuSigned("iphone", "apollo", days: 7, uuid: "UUID-2")]
        let snapshot = menuBuild(ledger: ledger, apps: read([apolloBid]))
        let actions: [MenuAction] = [
            renewApollo, renewAll, .install(device: "iphone", app: "apollo"), .remove(device: "iphone", app: "apollo"),
            .lendable(device: "iphone", app: "apollo"),
        ]
        for action in actions {
            let text = try prompt(action, snapshot)
            let all = ([text.title, text.runningLabel, text.confirmLabel] + text.lines).joined(separator: "\n")
            for secret in ["Robin", savedUdid("1"), savedCoreId("1"), "io.github", "7AGMPUPP64", "6ZU5Z6ZKK7"] {
                #expect(!all.contains(secret), "\(action): \(secret)")
            }
        }
    }

    @Test("the snapshot facts: App ID counts, suspension, trust, and platform")
    func facts() {
        let snapshot = world(freeAppIds: [LedgerFreeAppId(bundleId: apolloBid, epochStart: daysFromNow(-1)), LedgerFreeAppId(bundleId: "x", epochStart: daysFromNow(-9))])
        #expect(snapshot.appIds == MenuAppIds(recent: 1, reserved: 4))
        #expect(!snapshot.suspended && snapshot.ledgerReadable)
        #expect(snapshot.devices[0].platform == "ios" && snapshot.devices[0].slotsKnown && snapshot.devices[0].liveRead == .read)
        #expect(snapshot.devices[0].apps.allSatisfy { !$0.removalClearsTrust })
        let alone = menuBuild(ledger: menuLedger([("iphone", "apollo", 3)]), apps: read([apolloBid]))
        #expect(alone.devices[0].apps[0].removalClearsTrust)
        #expect(alone.devices[0].apps[0].recorded && alone.devices[0].apps[0].app == "apollo")
        #expect(alone.devices[0].apps[0].expires == daysFromNow(3))
        // Without a live read the trust rule is not evaluated.
        #expect(!menuBuild(ledger: menuLedger([("iphone", "apollo", 3)])).devices[0].apps[0].removalClearsTrust)
        #expect(menuBuild(ledgerReadable: false).appIds == nil)
    }
}

private func menuConfigLendable() -> Config {
    var config = menuConfig()
    config.devices["iphone"]?.lendableApp = "apollo"
    return config
}
