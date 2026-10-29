import Foundation
import Testing

@testable import SideloadCore

// Live presence on the menu's Apps card (design sections 12 and 18): what a row says for each combination of what the
// ledger recorded and what the device showed, the ring and the slot count that follow from it, and the read itself.

private let apollo = menuBundleId("apollo")

private func signed(_ app: String = "apollo", days: Double = 5) -> LedgerFreeSigned {
    LedgerFreeSigned(
        id: "iphone/\(app)", device: "iphone", app: app, bundleId: menuBundleId(app), version: "1.0",
        sha256Prefix: "0a1b2c3d", profileUuid: "UUID-1", profileExpires: daysFromNow(days), certFp8: "12345678",
        signedAt: testNow, path: "builds/signed/\(app)/iphone/X.app", strippedExtensions: [], droppedEntitlements: [])
}

private func op(_ kind: LedgerSlotKind, startedAt: Date, by: LedgerSlotBy = .install) -> LedgerSlotOp {
    LedgerSlotOp(kind: kind, by: by, startedAt: startedAt, window: SlotRule.window(kind))
}

/// The ledger cases of the presence matrix (docs: the plan of the menu presence PR).
private enum LedgerCase: CaseIterable {
    /// `install` recorded it: an `installs[]` record and a present slot.
    case recorded
    /// `app remove` ran: the record is not present, the slot is absent; `freeSigned` still lists the signed build.
    case removed
    /// Only `freeSigned`: signed, never installed by sideload.
    case signedOnly
    /// Lent to the lab and held (the app is off the device).
    case lent
    /// An install or reinstall inside its window.
    case opInWindow
    /// The same, long past its window.
    case opPastWindow

    var ledger: Ledger {
        switch self {
        case .recorded: return menuLedger([("iphone", "apollo", 5)])
        case .removed:
            var ledger = Ledger(freeSigned: [signed()])
            ledger.installs = [menuInstall("iphone", "apollo", days: 5, present: false)]
            ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent)]
            SlotRule.project(&ledger)
            return ledger
        case .signedOnly: return Ledger(freeSigned: [signed()])
        case .lent:
            var ledger = Ledger(installs: [menuInstall("iphone", "apollo", days: 5, present: false)])
            ledger.slots = [
                LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow.addingTimeInterval(-3_600))
            ]
            SlotRule.project(&ledger)
            return ledger
        case .opInWindow: return withOp(startedAt: testNow.addingTimeInterval(-60))
        case .opPastWindow: return withOp(startedAt: testNow.addingTimeInterval(-3_600))
        }
    }

    private func withOp(startedAt: Date) -> Ledger {
        var ledger = Ledger(installs: [menuInstall("iphone", "apollo", days: 5)])
        ledger.slots = [
            LedgerSlot(device: "iphone", app: "apollo", presence: .present, op: op(.reinstall, startedAt: startedAt))
        ]
        SlotRule.project(&ledger)
        return ledger
    }
}

private enum DeviceState: CaseIterable {
    case readHas, readNot, readFailed, readChecking, offline, listFailed, listChecking

    func inputs() -> (probe: DeviceProbe, apps: [String: DeviceAppsProbe]) {
        let visible = DeviceProbe.listed([menuListed()])
        switch self {
        case .readHas: return (visible, ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        case .readNot: return (visible, ["iphone": .read(menuSnapshot([]), takenAt: testNow)])
        case .readFailed: return (visible, ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)])
        case .readChecking: return (visible, ["iphone": .checking])
        // A read that is still in the cache from when the device was visible says nothing once it is not.
        case .offline:
            return (.listed([menuListed(link: "unavailable")]), ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        case .listFailed: return (.failed, ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        case .listChecking: return (.checking, [:])
        }
    }

    /// The row the matrix expects; nil is no row at all.
    func expected(_ ledger: LedgerCase) -> AppPresence? {
        switch (ledger, self) {
        case (.recorded, .readHas): return .installed
        case (.recorded, .readNot): return .notInstalled
        case (.recorded, .readChecking), (.recorded, .listChecking): return .checking
        case (.recorded, _): return .unconfirmed
        // Signed but not recorded present: a usable read confirms it (installed by hand, or "Signed · not installed");
        // with no read there is no row.
        case (.removed, .readHas), (.signedOnly, .readHas): return .installed
        case (.removed, .readNot), (.signedOnly, .readNot): return .notInstalled
        case (.removed, _), (.signedOnly, _): return nil
        case (.lent, .readHas): return .installed
        case (.lent, _): return .lent
        case (.opInWindow, _): return .pending
        case (.opPastWindow, .readHas): return .installed
        case (.opPastWindow, .readNot): return .notInstalled
        case (.opPastWindow, _): return .pending
        }
    }
}

@Suite("menu: presence matrix")
struct MenuPresenceMatrixTests {
    @Test("every ledger case against every device state gives the row the matrix names")
    func matrix() {
        for ledger in LedgerCase.allCases {
            for device in DeviceState.allCases {
                let (probe, apps) = device.inputs()
                let rows = menuBuild(ledger: ledger.ledger, probe: probe, apps: apps).devices[0].apps
                #expect(rows.map(\.presence) == (device.expected(ledger).map { [$0] } ?? []), "\(ledger) / \(device)")
            }
        }
    }

    @Test("only a countdown draws a bar; the other states say what they are, in neutral text")
    func rowShapes() {
        let words: [AppPresence: String] = [
            .notInstalled: "Signed · not installed", .lent: "Lent to lab", .pending: "Change in progress",
            .checking: "checking…",
        ]
        for ledger in LedgerCase.allCases {
            for device in DeviceState.allCases {
                let (probe, apps) = device.inputs()
                for row in menuBuild(ledger: ledger.ledger, probe: probe, apps: apps).devices[0].apps {
                    let label = "\(ledger) / \(device)"
                    if let text = words[row.presence] {
                        #expect(!row.showsBar && row.daysLabel == text, "\(label)")
                        #expect(row.textTone == .neutral && row.barTone == .neutral && row.barFraction == 0, "\(label)")
                    } else {
                        #expect(row.showsBar && row.daysLabel == "5 d", "\(label)")
                    }
                }
            }
        }
    }

    @Test("the ring, the status items and the Renew items count what is or may be on the device, not what is gone or lent")
    func ringMembership() {
        for ledger in LedgerCase.allCases {
            for device in DeviceState.allCases {
                let (probe, apps) = device.inputs()
                let snapshot = menuBuild(ledger: ledger.ledger, probe: probe, apps: apps)
                guard let presence = device.expected(ledger) else { continue }
                let inRing = [.installed, .unconfirmed, .checking, .pending].contains(presence)
                let label = "\(ledger) / \(device)"
                #expect((snapshot.icon.remaining != nil) == inRing, "\(label)")
                #expect(snapshot.devices[0].renew.items.count == (inRing ? 2 : 1), "\(label)")
                // "All apps (N)" counts the apps `refresh` would renew, which is not the same set as the rows.
                let count = snapshot.devices[0].refreshSet.count
                #expect(snapshot.devices[0].renew.items.first?.detail == (count == 0 ? nil : "(\(count))"), "\(label)")
            }
        }
    }

    @Test("a hand-installed app takes its date from freeSigned; a recorded one from installs[], whatever freeSigned says")
    func dates() {
        let read = ["iphone": DeviceAppsProbe.read(menuSnapshot([apollo]), takenAt: testNow)]
        let hand = menuBuild(ledger: Ledger(freeSigned: [signed(days: 4)]), apps: read)
        #expect(hand.devices[0].apps[0].daysLabel == "4 d")
        var recorded = LedgerCase.recorded.ledger
        recorded.freeSigned = [signed(days: 7)]
        let installed = menuBuild(ledger: recorded, apps: read)
        #expect(installed.devices[0].apps[0].daysLabel == "5 d")
        #expect(abs(installed.icon.fraction - 5.0 / 7.0) < 1e-9)
    }

    @Test("a lent app needs no install record; one that is back on the device shows installed with no countdown")
    func lentWithoutInstallRecord() {
        var ledger = Ledger()
        ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&ledger)
        let lent = menuBuild(ledger: ledger).devices[0].apps
        #expect(lent.map(\.presence) == [.lent])
        let back = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)]).devices[0].apps
        #expect(back.map(\.presence) == [.installed])
        #expect(back[0].daysLabel == "Installed" && !back[0].showsBar)
        #expect(menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)]).icon == .unknown)
    }

    @Test("a change in progress with no install record has a row but no date, so it stays out of the ring")
    func pendingWithoutInstallRecord() {
        var ledger = Ledger()
        ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .unknown, op: op(.install, startedAt: testNow))]
        SlotRule.project(&ledger)
        let snapshot = menuBuild(ledger: ledger)
        #expect(snapshot.devices[0].apps.map(\.presence) == [.pending])
        #expect(snapshot.icon == .unknown)
        #expect(snapshot.devices[0].renew.items.map(\.title) == ["All apps"])
    }

    @Test("a read older than what the ledger knows is not used: a cached read from before a lend cannot undo it")
    func staleRead() {
        var ledger = LedgerCase.lent.ledger
        ledger.slots[0].since = testNow
        SlotRule.project(&ledger)
        let before = testNow.addingTimeInterval(-120)
        let stale = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: before)])
        #expect(stale.devices[0].apps.map(\.presence) == [.lent])
        let fresh = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        #expect(fresh.devices[0].apps.map(\.presence) == [.installed])

        var seen = LedgerCase.recorded.ledger
        seen.slots[0].seenAt = testNow
        let older = menuBuild(ledger: seen, apps: ["iphone": .read(menuSnapshot([]), takenAt: before)])
        #expect(older.devices[0].apps.map(\.presence) == [.unconfirmed])
    }

    @Test("app remove then an open inside 5 minutes: a cached read from before it cannot bring a removed app back")
    func staleReadCannotRestoreARemovedApp() {
        var ledger = LedgerCase.removed.ledger
        ledger.slots[0].seenAt = testNow
        let before = DeviceAppsProbe.read(menuSnapshot([apollo]), takenAt: testNow.addingTimeInterval(-120))
        let stale = menuBuild(ledger: ledger, apps: ["iphone": before])
        #expect(stale.devices[0].apps.isEmpty)
        #expect(stale.icon.remaining == nil)
        #expect(stale.devices[0].renew.items.map(\.title) == ["All apps"])
        #expect(stale.devices[0].renew.items.first?.detail == nil)
        // The card says the read was not used (there are no rows to say it on, so only a card with rows shows the note).
        let fresh = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        #expect(fresh.devices[0].apps.map(\.presence) == [.installed])
        #expect(fresh.devices[0].appsNote == nil)
    }

    @Test("a card whose rows show the ledger's record because a read was overtaken, or the device list failed, says so")
    func lastKnownNote() {
        let ledger = menuLedger([("iphone", "apollo", 5)])
        var seen = ledger
        seen.slots[0].seenAt = testNow
        let overtaken = menuBuild(
            ledger: seen, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow.addingTimeInterval(-120))])
        #expect(overtaken.devices[0].apps.map(\.presence) == [.unconfirmed])
        #expect(overtaken.devices[0].appsNote == "Couldn't check apps · showing last known")
        let listFailed = menuBuild(ledger: ledger, probe: .failed)
        #expect(listFailed.devices[0].appsNote == "Couldn't check apps · showing last known")
        // Nothing to show, nothing to say; a good read and an offline device keep their own wording.
        #expect(menuBuild(probe: .failed).devices[0].appsNote == nil)
        #expect(menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)]).devices[0].appsNote == nil)
        #expect(menuBuild(ledger: ledger, probe: .listed([menuListed(link: "unavailable")])).devices[0].appsNote == nil)
    }

    @Test("the overtaken-read note is for the rows that show the record because of it, not for any slot on the device")
    func noteFollowsTheRows() {
        var ledger = LedgerCase.removed.ledger
        ledger.slots[0].seenAt = testNow
        ledger = menuLedger([("iphone", "stremio-ios", 5)], base: ledger)
        let stremio = menuBundleId("stremio-ios")
        // Taken before the remove of apollo: it cannot speak for apollo, but stremio's record is older than the read.
        let read = DeviceAppsProbe.read(menuSnapshot([apollo, stremio]), takenAt: testNow.addingTimeInterval(-120))
        let card = menuBuild(ledger: ledger, apps: ["iphone": read]).devices[0]
        #expect(card.apps.map(\.presence) == [.installed])
        #expect(card.appsNote == nil)
    }

    @Test("a retired device's records make no row and no ring, even when the device list shows it")
    func retiredDevice() {
        var ledger = menuLedger([("gone", "apollo", 0.5)])
        ledger.freeSigned = [
            LedgerFreeSigned(
                id: "gone/stremio-ios", device: "gone", app: "stremio-ios", bundleId: menuBundleId("stremio-ios"), version: "1.0",
                sha256Prefix: "0a1b2c3d", profileUuid: "U", profileExpires: daysFromNow(0.5), certFp8: "12345678", signedAt: testNow,
                path: "x", strippedExtensions: [], droppedEntitlements: [])
        ]
        let snapshot = menuBuild(ledger: ledger, apps: ["gone": .read(menuSnapshot([menuBundleId("stremio-ios")]), takenAt: testNow)])
        #expect(snapshot.devices.map(\.alias) == ["iphone"])
        #expect(snapshot.devices[0].apps.isEmpty)
        #expect(snapshot.icon == .unknown)
    }
}

@Suite("menu: renewal failures")
struct MenuRenewFailedTests {
    private func failed(_ result: String?, code: String? = "DEVICE_LOCKED") -> Ledger {
        var ledger = menuLedger([("iphone", "apollo", 6)])
        ledger.installs[0].refresh = LedgerInstallRefresh(lastResult: result, lastCode: code)
        return ledger
    }

    private let read = ["iphone": DeviceAppsProbe.read(menuSnapshot([apollo]), takenAt: testNow)]

    @Test("a failed last renewal marks the row red and the icon, with the code when it has the plain shape")
    func failedRow() {
        let snapshot = menuBuild(ledger: failed("failed"), apps: read)
        #expect(snapshot.devices[0].apps[0].failure == "Renewal failed · DEVICE_LOCKED")
        #expect(snapshot.icon.state == .renewFailed)
        // The ring keeps its value under the badge.
        #expect(abs(snapshot.icon.fraction - 6.0 / 7.0) < 1e-9)
        #expect(menuBuild(ledger: failed("failed", code: nil), apps: read).devices[0].apps[0].failure == "Renewal failed")
        for odd in ["Apple Development: Jane Doe", "lower_case", "WITH SPACE", ""] {
            #expect(menuBuild(ledger: failed("failed", code: odd), apps: read).devices[0].apps[0].failure == "Renewal failed", "\(odd)")
        }
    }

    @Test("a failure counts for installed, unconfirmed, checking and pending rows")
    func failureStates() {
        let ledger = failed("failed")
        let unconfirmed = menuBuild(ledger: ledger, probe: .listed([menuListed(link: "unavailable")]))
        let checking = menuBuild(ledger: ledger, probe: .checking)
        for snapshot in [unconfirmed, checking, menuBuild(ledger: ledger, apps: read)] {
            #expect(snapshot.devices[0].apps[0].failure != nil)
            #expect(snapshot.icon.state == .renewFailed)
        }
        var pending = failed("failed")
        pending.slots[0].op = op(.reinstall, startedAt: testNow)
        SlotRule.project(&pending)
        let row = menuBuild(ledger: pending, apps: read).devices[0].apps[0]
        #expect(row.presence == .pending && row.failure != nil)
    }

    @Test("skipped and renewed-not-installed are not failures; neither is a failure on an app that is gone or lent")
    func notFailures() {
        for result in ["skipped", "renewed-not-installed", "renewed", nil] {
            let snapshot = menuBuild(ledger: failed(result), apps: read)
            #expect(snapshot.devices[0].apps[0].failure == nil, "\(result ?? "nil")")
            #expect(snapshot.icon.state == .ok, "\(result ?? "nil")")
        }
        let gone = menuBuild(ledger: failed("failed"), apps: ["iphone": .read(menuSnapshot([]), takenAt: testNow)])
        #expect(gone.devices[0].apps[0].presence == .notInstalled)
        #expect(gone.devices[0].apps[0].failure == nil)
        #expect(gone.icon.state != .renewFailed)

        var lent = failed("failed")
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        let held = menuBuild(ledger: lent)
        #expect(held.devices[0].apps[0].presence == .lent && held.devices[0].apps[0].failure == nil)
        #expect(held.icon.state != .renewFailed)
    }

    @Test("an input override still forces the renew failed state")
    func override() {
        #expect(menuBuild(ledger: menuLedger([("iphone", "apollo", 6)]), renewFailed: true).icon.state == .renewFailed)
    }
}

@Suite("menu: the icon and the status follow what is on the device")
struct MenuPresenceRingTests {
    @Test("an app gone from the device and a lent app leave the ring and the worst state to the others")
    func excluded() {
        var ledger = menuLedger([("iphone", "apollo", 0.5), ("iphone", "stremio-ios", 6)])
        // A third record: lent, with a profile that would be expired.
        ledger.installs.append(menuInstall("iphone", "filler", days: -2, present: false))
        ledger.slots.append(LedgerSlot(device: "iphone", app: "filler", presence: .absent, lentTo: "lab", since: testNow))
        SlotRule.project(&ledger)
        let read = ["iphone": DeviceAppsProbe.read(menuSnapshot([menuBundleId("stremio-ios")]), takenAt: testNow)]
        let snapshot = menuBuild(ledger: ledger, canary: "working", apps: read)
        #expect(snapshot.devices[0].apps.map(\.presence) == [.notInstalled, .lent, .installed])
        #expect(snapshot.icon.state == .ok)
        #expect(abs(snapshot.icon.fraction - 6.0 / 7.0) < 1e-9)
        #expect(snapshot.state == .ok)
        #expect(snapshot.devices[0].renew.items.map(\.title) == ["All apps", "Stremio"])
        // A lent app joins the Renew items once it has a signed build: it is re-signed without the device.
        var signedLent = ledger
        signedLent.freeSigned = [menuSigned("iphone", "filler", days: 2)]
        let renewable = menuBuild(ledger: signedLent, canary: "working", apps: read)
        #expect(renewable.devices[0].renew.items.compactMap(\.app) == ["filler", "stremio-ios"])
        #expect(renewable.devices[0].renew.items.first?.detail == "(2)")
        #expect(renewable.icon.state == .ok, "a lent app's signed build never drives the ring")
        // Without the read, the apollo record still counts: it may be on the device.
        let unread = menuBuild(ledger: ledger, canary: "working", probe: .failed)
        #expect(unread.icon.state == .critical)
        #expect(unread.state == .critical)
    }

    @Test("the apps note names why a visible device could not be read, once per card; offline devices keep their own line")
    func appsNote() {
        let ledger = menuLedger([("iphone", "apollo", 6)])
        func note(_ code: String) -> String? {
            menuBuild(ledger: ledger, apps: ["iphone": .failed(code: code, takenAt: testNow)]).devices[0].appsNote
        }
        #expect(note("DEVICE_LOCKED") == "Couldn't check apps (device locked) · showing last known")
        #expect(note("TIMEOUT") == "Couldn't check apps (timed out) · showing last known")
        #expect(note("SNAPSHOT_FAILED") == "Couldn't check apps (couldn't read) · showing last known")
        #expect(note("SOMETHING_ELSE") == "Couldn't check apps (couldn't read) · showing last known")
        let read = menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([apollo]), takenAt: testNow)])
        #expect(read.devices[0].appsNote == nil)
        let offline = menuBuild(
            ledger: ledger, probe: .listed([menuListed(link: "unavailable", lastSeen: testNow.addingTimeInterval(-3_600))]),
            apps: ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)])
        #expect(offline.devices[0].appsNote == nil)
        #expect(offline.devices[0].offlineNote == "Seen 1 h ago")
        // No per-row text about it.
        #expect(menuBuild(ledger: ledger, apps: ["iphone": .failed(code: "TIMEOUT", takenAt: testNow)]).devices[0].apps[0].daysLabel == "6 d")
    }

    @Test("checkingApps is true only while a visible device is being read")
    func checkingApps() {
        let ledger = menuLedger([("iphone", "apollo", 6)])
        #expect(menuBuild(ledger: ledger, apps: ["iphone": .checking]).checkingApps)
        #expect(!menuBuild(ledger: ledger, apps: [:]).checkingApps)
        #expect(!menuBuild(ledger: ledger, apps: ["iphone": .read(menuSnapshot([]), takenAt: testNow)]).checkingApps)
        #expect(!menuBuild(ledger: ledger, probe: .listed([menuListed(link: "unavailable")]), apps: ["iphone": .checking]).checkingApps)
    }

    @Test("a snapshot carries no UDID, CoreDevice ID, device name, identity name or foreign app ID")
    func redaction() {
        let foreign = "com.example.private-thing"
        let read = DeviceAppsProbe.read(menuSnapshot([apollo, foreign]), takenAt: testNow)
        let ledger = menuLedger([("iphone", "apollo", 2)])
        for apps in [["iphone": read], ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)], [:]] as [[String: DeviceAppsProbe]] {
            let snapshot = menuBuild(ledger: ledger, apps: apps)
            let text = String(describing: MenuPanel.loaded(snapshot))
            #expect(!text.contains(savedUdid("1")))
            #expect(!text.contains(String(savedUdid("1").suffix(8))))
            #expect(!text.contains(savedCoreId("1")))
            #expect(!text.contains("Secret Phone"))
            #expect(!text.contains("Robin"))
            #expect(!text.contains(foreign))
        }
    }
}

@Suite("menu: free slots with a live read")
struct MenuPresenceSlotTests {
    private func free(
        _ ledger: Ledger = Ledger(), ids: [String]?, reserved: Int = 0, takenAt: Date = testNow,
        config: Config? = nil
    ) -> Int {
        let apps: [String: DeviceAppsProbe] = ids.map { ["iphone": .read(menuSnapshot($0), takenAt: takenAt)] } ?? [:]
        return menuBuild(config: config ?? menuConfig(reserved: ["iphone": reserved]), ledger: ledger, apps: apps).devices[0].freeSlots
    }

    @Test("the snapshot's managed apps count, hand-installed ones too; other developer apps never do")
    func managed() {
        #expect(free(ids: []) == 3)
        #expect(free(ids: [apollo]) == 2)
        #expect(free(ids: [apollo, menuBundleId("stremio-ios"), menuBundleId("filler")]) == 0)
        #expect(free(ids: ["com.example.other", "com.apple.mobilesafari"]) == 3)
        #expect(free(Ledger(freeSigned: [signed()]), ids: [apollo]) == 2)
        #expect(free(ids: [apollo], reserved: 1) == 1)
        #expect(free(ids: [], reserved: 2) == 1)
    }

    @Test("a record the ledger calls present but the device does not show frees its slot")
    func staleRecordGoneFromDevice() {
        let ledger = menuLedger([("iphone", "apollo", 5)])
        #expect(free(ledger, ids: nil) == 2)
        #expect(free(ledger, ids: []) == 3)
        #expect(free(ledger, ids: [apollo]) == 2)
    }

    @Test("a pending or lent slot the snapshot does not show is used, never free")
    func pendingAndLentAreUsed() {
        #expect(free(LedgerCase.opInWindow.ledger, ids: []) == 2)
        #expect(free(LedgerCase.opInWindow.ledger, ids: [apollo]) == 2)
        #expect(free(LedgerCase.lent.ledger, ids: []) == 2)
        // Back on the device, it is the snapshot's managed app, counted once.
        #expect(free(LedgerCase.lent.ledger, ids: [apollo]) == 2)
        // An operation past its window settles from the snapshot.
        #expect(free(LedgerCase.opPastWindow.ledger, ids: []) == 3)
        #expect(free(LedgerCase.opPastWindow.ledger, ids: [apollo]) == 2)
        // Lent plus a second app that is pending: both held.
        var two = LedgerCase.lent.ledger
        two.installs.append(menuInstall("iphone", "stremio-ios", days: 5))
        two.slots.append(LedgerSlot(device: "iphone", app: "stremio-ios", presence: .present, op: op(.install, startedAt: testNow)))
        SlotRule.project(&two)
        #expect(free(two, ids: []) == 1)
    }

    @Test("an unreadable ledger or an out-of-range reserve leaves the slots unknown, whatever the device shows")
    func unknown() {
        let unreadable = menuBuild(
            ledger: Ledger(), apps: ["iphone": .read(menuSnapshot([]), takenAt: testNow)], ledgerReadable: false)
        #expect(unreadable.devices[0].freeSlots == 0 && unreadable.devices[0].slotsLabel == "slots unknown")
        let badReserve = menuBuild(
            config: menuConfig(reserved: ["iphone": 9]), apps: ["iphone": .read(menuSnapshot([]), takenAt: testNow)]).devices[0]
        #expect(badReserve.freeSlots == 0 && badReserve.slotsLabel == "slots unknown")
    }

    @Test("without a prefix in the config the read cannot say which apps are ours: the ledger alone counts")
    func noPrefix() {
        let ledger = menuLedger([("iphone", "apollo", 5)])
        #expect(free(ledger, ids: [], config: menuConfig(prefix: nil)) == 2)
    }

    @Test("without a read, a signed app counts only while no slot record exists for it")
    func signedWithoutSlot() {
        #expect(free(Ledger(freeSigned: [signed()]), ids: nil) == 2)
        // `app remove` left an absent slot: the slot decides, the old signed build no longer holds a slot.
        #expect(free(LedgerCase.removed.ledger, ids: nil) == 3)
        // Present in both: counted once.
        var both = Ledger(freeSigned: [signed()])
        both.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .present)]
        #expect(free(both, ids: nil) == 2)
        #expect(free(LedgerCase.lent.ledger, ids: nil) == 2)
        #expect(free(LedgerCase.opPastWindow.ledger, ids: nil) == 2)
    }
}

@Suite("menu: reading a device's apps")
struct MenuReadAppsTests {
    private func fixture(_ body: (Paths, Services, FakeRunner) async throws -> Void, apps: @escaping @Sendable (String) -> RunResultWithJSON)
        async throws
    {
        try await withTestHome(config: menuConfig()) { paths, _ in
            let runner = FakeRunner(menuDeviceScript(devices: nil, apps: apps))
            let services = Services(
                runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(), home: paths)
            try await body(paths, services, runner)
        }
    }

    @Test("one devicectl info apps call by alias with a 15 s timeout, read only, taking no lock and writing nothing")
    func readOnly() async throws {
        try await fixture(
            { paths, services, runner in
                try await LedgerStore(paths: paths).update { $0 = menuLedger([("iphone", "apollo", 5)]) }
                try? FileManager.default.removeItem(atPath: paths.opLock)
                let config = try Data(contentsOf: URL(fileURLWithPath: paths.config))
                let ledger = try Data(contentsOf: URL(fileURLWithPath: paths.ledger))

                let probe = await MenuLoader.readApps(services, alias: "iphone", prefix: menuPrefix)

                guard case .read(let snapshot, let takenAt) = probe else {
                    Issue.record("expected a read, got \(probe)")
                    return
                }
                #expect(snapshot.ids == [apollo])
                #expect(takenAt == testNow)
                #expect(runner.calls.count == 1)
                let call = try #require(runner.calls.first)
                #expect(call.executable == "xcrun")
                #expect(Array(call.args.prefix(4)) == ["devicectl", "device", "info", "apps"])
                let words = call.args.filter { !$0.hasPrefix("-") }
                #expect(!words.contains { ["profile", "install", "uninstall", "launch", "copy", "files"].contains($0) })
                #expect(call.args.firstIndex(of: "--timeout").map { call.args[$0 + 1] } == "15")
                #expect(call.timeout == .seconds(15 + DeviceCtl.runnerMarginSec))
                // By saved alias: the call carries the saved CoreDevice ID, which only the config knows.
                #expect(call.args.firstIndex(of: "--device").map { call.args[$0 + 1] } == savedCoreId("1"))
                #expect(!FileManager.default.fileExists(atPath: paths.opLock))
                #expect(try Data(contentsOf: URL(fileURLWithPath: paths.config)) == config)
                #expect(try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) == ledger)
            }, apps: { _ in .apps([apollo]) })
    }

    @Test("a locked, timed-out or unreadable device is a failure with its code, never an empty device")
    func failures() async throws {
        let cases: [(RunResultWithJSON, String)] = [
            (.locked, "DEVICE_LOCKED"), (.timedOut, "TIMEOUT"),
            (RunResultWithJSON(result: RunResult(code: 0), json: ["info": ["outcome": "failure"]]), "SNAPSHOT_FAILED"),
            (RunResultWithJSON(result: RunResult(code: 1), json: nil), "SNAPSHOT_FAILED"),
        ]
        for (reply, code) in cases {
            try await fixture(
                { _, services, runner in
                    let probe = await MenuLoader.readApps(services, alias: "iphone", prefix: menuPrefix)
                    #expect(probe == .failed(code: code, takenAt: testNow), "\(code)")
                    #expect(runner.calls.count == 1)
                }, apps: { _ in reply })
        }
        // A complete empty list is an empty device, which is different.
        try await fixture(
            { _, services, _ in
                guard case .read(let snapshot, _) = await MenuLoader.readApps(services, alias: "iphone", prefix: menuPrefix) else {
                    Issue.record("expected a read")
                    return
                }
                #expect(snapshot.ids.isEmpty)
            }, apps: { _ in .apps([]) })
    }

    @Test("without a usable bundleIdPrefix nothing is run")
    func noPrefix() async throws {
        try await withTestHome(config: menuConfig(prefix: nil)) { paths, _ in
            let runner = FakeRunner(menuDeviceScript(devices: nil, apps: { _ in .apps([]) }))
            let services = Services(
                runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(), home: paths)
            #expect(await MenuLoader.readApps(services, alias: "iphone", prefix: nil) == .failed(code: "CONFIG_MISSING", takenAt: testNow))
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("an alias that is not saved is a failure, not a call")
    func unsavedAlias() async throws {
        try await fixture(
            { _, services, runner in
                guard case .failed = await MenuLoader.readApps(services, alias: "nobody", prefix: menuPrefix) else {
                    Issue.record("expected a failure")
                    return
                }
                #expect(runner.calls.isEmpty)
            }, apps: { _ in .apps([]) })
    }

    @Test("the snapshot read takes the timeout it is given, and 60 s by default")
    func timeouts() async throws {
        try await fixture(
            { _, services, runner in
                let calls = FreeDeviceCalls(services: services, alias: "iphone", bundleId: apollo)
                _ = await calls.trySnapshot()
                _ = await calls.trySnapshot(timeoutSec: 15)
                let timeouts = runner.calls.map { call in call.args.firstIndex(of: "--timeout").map { call.args[$0 + 1] } }
                #expect(timeouts == ["60", "15"])
                #expect(runner.calls.map(\.timeout) == [.seconds(60 + DeviceCtl.runnerMarginSec), .seconds(15 + DeviceCtl.runnerMarginSec)])
            }, apps: { _ in .apps([]) })
    }

    @Test("visible aliases are the saved devices that are paired and reachable, in alias order")
    func visible() {
        let config = menuConfig(devices: ["iphone", "ipad", "appletv"])
        let phone = menuListed("1")
        let pad = menuListed("2")
        let tv = menuListed("3", link: "unavailable")
        #expect(MenuLoader.visibleAliases(config, probe: .listed([phone, pad, tv])) == ["ipad", "iphone"])
        #expect(MenuLoader.visibleAliases(config, probe: .listed([menuListed("2", paired: false)])).isEmpty)
        #expect(MenuLoader.visibleAliases(config, probe: .listed([])).isEmpty)
        #expect(MenuLoader.visibleAliases(config, probe: .failed).isEmpty)
        #expect(MenuLoader.visibleAliases(config, probe: .checking).isEmpty)
    }
}

@Suite("menu: app list cache policy")
struct MenuAppsCacheTests {
    @Test("a device is read when never read, forced, or last attempted 5 minutes ago or more")
    func needsRead() {
        var cache = MenuAppsCache()
        #expect(cache.needsRead("iphone", force: false, now: testNow))
        cache.set("iphone", .read(menuSnapshot([]), takenAt: testNow))
        #expect(!cache.needsRead("iphone", force: false, now: testNow.addingTimeInterval(299)))
        #expect(cache.needsRead("iphone", force: false, now: testNow.addingTimeInterval(300)))
        #expect(cache.needsRead("iphone", force: true, now: testNow))
        #expect(cache.needsRead("ipad", force: false, now: testNow))
        // A clock that moved back is stale, not fresh.
        #expect(cache.needsRead("iphone", force: false, now: testNow.addingTimeInterval(-10)))
    }

    @Test("a failed attempt counts as an attempt; a read in progress is not fresh")
    func failedIsAnAttempt() {
        var cache = MenuAppsCache()
        cache.set("iphone", .failed(code: "DEVICE_LOCKED", takenAt: testNow))
        #expect(!cache.needsRead("iphone", force: false, now: testNow.addingTimeInterval(60)))
        cache.set("iphone", .checking)
        #expect(cache.needsRead("iphone", force: false, now: testNow))
    }

    @Test("devices that are no longer visible are forgotten")
    func retain() {
        var cache = MenuAppsCache()
        cache.set("iphone", .read(menuSnapshot([]), takenAt: testNow))
        cache.set("ipad", .failed(code: "TIMEOUT", takenAt: testNow))
        cache.retain(["iphone"])
        #expect(Set(cache.entries.keys) == ["iphone"])
        #expect(cache.needsRead("ipad", force: false, now: testNow))
    }

    @Test("the first paint of a load reuses the last device list and the cached reads; with nothing known it says checking")
    func firstPaint() {
        let local = MenuLoader.Local.ready(
            MenuInputs(
                now: testNow, canaryStatus: nil, config: menuConfig(), ledger: menuLedger([("iphone", "apollo", 5)]),
                probe: .checking))
        guard case .loaded(let launch) = MenuLoader.firstPaint(local, cache: MenuAppsCache()) else {
            Issue.record("expected a loaded panel")
            return
        }
        #expect(launch.checkingDevices)
        #expect(launch.devices[0].apps.map(\.presence) == [.checking])

        var cache = MenuAppsCache()
        let probe = DeviceProbe.listed([menuListed()])
        cache.remember(probe)
        cache.set("iphone", .read(menuSnapshot([apollo]), takenAt: testNow))
        let settled = MenuLoader.panel(local, probe: probe, apps: cache.entries)
        #expect(MenuLoader.firstPaint(local, cache: cache) == settled)
        guard case .loaded(let again) = settled else { return }
        #expect(again.devices[0].apps.map(\.presence) == [.installed])
        #expect(!again.checkingDevices)
    }
}
