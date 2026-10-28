import Foundation
import Testing

@testable import SideloadCore

// The menu bar app's snapshot logic (design sections 12 and 18): thresholds, bars, offline collapse, slots, the icon
// state and redaction. The SwiftUI views only draw these values.

private func signed(
    _ device: String, _ app: String, days: Double, uuid: String = "UUID-1"
) -> LedgerFreeSigned {
    LedgerFreeSigned(
        id: "\(device)/\(app)", device: device, app: app, bundleId: "io.github.dividedby.free.\(app)", version: "1.0",
        sha256Prefix: "0a1b2c3d", profileUuid: uuid, profileExpires: daysFromNow(days), certFp8: "12345678",
        signedAt: testNow, path: "builds/signed/\(app)/\(device)/X.app", strippedExtensions: [], droppedEntitlements: [])
}

private func config(
    reserved: [String: Int] = [:], auto: Set<String> = [], devices: [String] = ["iphone"]
) -> Config {
    menuConfig(reserved: reserved, auto: auto, devices: devices)
}

private func listed(
    _ seed: String = "1", link: String = "disconnected", transport: DeviceTransport = .network, paired: Bool = true,
    lastSeen: Date? = nil
) -> ListedDevice {
    menuListed(seed, link: link, transport: transport, paired: paired, lastSeen: lastSeen)
}

private func build(
    config: Config = config(), ledger: Ledger = Ledger(), canary: String? = nil, probe: DeviceProbe = .listed([listed()]),
    autoRefreshAvailable: Bool = false, ledgerReadable: Bool = true
) -> MenuSnapshot {
    menuBuild(
        config: config, ledger: ledger, canary: canary, probe: probe, autoRefreshAvailable: autoRefreshAvailable,
        ledgerReadable: ledgerReadable)
}

/// The ledger after `install` put these apps on devices (an `installs[]` record and a present slot each).
private func installed(_ apps: (device: String, app: String, days: Double)...) -> Ledger { menuLedger(apps) }

@Suite("menu: free install expiry")
struct FreeInstallExpiryTests {
    @Test("ok above 3 days, warn at 3 days or less, critical at 1 day or less, expired once past")
    func thresholds() {
        func level(_ days: Double) -> ExpiryItem.Level {
            FreeInstallExpiry.assess(expires: daysFromNow(days), now: testNow).level
        }
        #expect(level(6.5) == .ok)
        #expect(level(4.0) == .ok)
        // The level comes from the exact remaining time, not the floored day count.
        #expect(level(3.9) == .ok)
        #expect(level(3.01) == .ok)
        #expect(level(3.0) == .warn)
        #expect(level(2.0) == .warn)
        #expect(level(1.9) == .warn)
        #expect(level(1.01) == .warn)
        #expect(level(1.0) == .critical)
        #expect(level(0.5) == .critical)
        #expect(level(0) == .expired)
        #expect(level(-2) == .expired)
    }

    @Test("bar fraction is time left over 7 days, clamped; green when good, orange when due, red when expired")
    func barAndColour() {
        let f = { (days: Double) in FreeInstallExpiry.barFraction(expires: daysFromNow(days), now: testNow) }
        #expect(abs(f(6) - 6.0 / 7.0) < 1e-9)
        #expect(f(7) == 1)
        #expect(f(30) == 1)
        #expect(f(0) == 0)
        #expect(f(-3) == 0)
        #expect(FreeInstallExpiry.barTone(.ok) == .good)
        #expect(FreeInstallExpiry.barTone(.warn) == .due)
        #expect(FreeInstallExpiry.barTone(.critical) == .due)
        #expect(FreeInstallExpiry.barTone(.expired) == .failed)
        #expect(FreeInstallExpiry.textTone(.ok) == .plain)
        #expect(FreeInstallExpiry.textTone(.warn) == .due)
    }

    @Test("labels: plain days when fine, due marker at 3 d or fewer, hours under a day, expired")
    func labels() {
        let label = { (days: Double) in FreeInstallExpiry.label(expires: daysFromNow(days), now: testNow) }
        #expect(label(6.2) == "6 d")
        #expect(label(3.9) == "3 d")  // floored for display, still ok
        #expect(label(3.0) == "3 d · due")
        #expect(label(2.5) == "2 d · due")
        #expect(label(0.25) == "6 h · due")
        #expect(label(0.001) == "<1 h · due")
        #expect(label(-1) == "expired")
    }
}

@Suite("menu: snapshot")
struct MenuSnapshotTests {
    @Test("an app is on the card when installs[] has it; rows carry days, bar and tone")
    func installShows() {
        let snapshot = build(ledger: installed(("iphone", "apollo", 6.5), ("iphone", "stremio-ios", 2.2)))
        let card = snapshot.devices[0]
        #expect(snapshot.showsApps)
        #expect(card.apps.map(\.name) == ["Apollo", "Stremio"])
        #expect(card.apps[0].daysLabel == "6 d")
        #expect(card.apps[0].barTone == .good)
        #expect(card.apps[1].daysLabel == "2 d · due")
        #expect(card.apps[1].barTone == .due)
        #expect(card.apps[1].textTone == .due)
        #expect(card.apps.allSatisfy { $0.presence == .unconfirmed && $0.showsBar && $0.failure == nil })
    }

    @Test("a signed app alone is not an install: without a live read it has no row")
    func freeSignedAloneHasNoRow() {
        let snapshot = build(ledger: Ledger(freeSigned: [signed("iphone", "apollo", days: 6.5)]))
        #expect(snapshot.devices[0].apps.isEmpty)
        #expect(!snapshot.showsApps)
        #expect(snapshot.icon == .unknown)
        #expect(snapshot.strip.freeInUse)
    }

    @Test("the Apps section is hidden until something is installed")
    func hiddenWhenEmpty() {
        let snapshot = build()
        #expect(!snapshot.showsApps)
        #expect(!snapshot.strip.freeInUse)
    }

    @Test("a hand-installed app: a stored profile with the same UUID is used; a newer one that is not installed does not move the date")
    func profileRecordMatching() {
        let entry = signed("iphone", "apollo", days: 2, uuid: "A")
        func profile(_ uuid: String, days: Double) -> LedgerFreeProfile {
            LedgerFreeProfile(
                id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: entry.bundleId,
                profileUuid: uuid, created: nil, expires: daysFromNow(days), certFp8: "12345678", file: "x")
        }
        let apps = ["iphone": DeviceAppsProbe.read(menuSnapshot([entry.bundleId]), takenAt: testNow)]
        let newer = menuBuild(ledger: Ledger(freeProfiles: [profile("B", days: 7)], freeSigned: [entry]), apps: apps)
        #expect(newer.devices[0].apps[0].daysLeft == 2)
        let same = menuBuild(ledger: Ledger(freeProfiles: [profile("A", days: 3)], freeSigned: [entry]), apps: apps)
        #expect(same.devices[0].apps[0].daysLeft == 3)
    }

    @Test("an installs[] record's date is not moved by a newer freeSigned build that is not installed")
    func installsDateWins() {
        var ledger = installed(("iphone", "apollo", 2))
        ledger.freeSigned = [signed("iphone", "apollo", days: 7)]
        let snapshot = build(ledger: ledger)
        #expect(snapshot.devices[0].apps[0].daysLeft == 2)
        #expect(abs(snapshot.icon.fraction - 2.0 / 7.0) < 1e-9)
    }

    @Test("slot counting: 3 minus installed apps minus reserved, never below zero; labels read N free slot(s)")
    func slots() {
        let two = Ledger(freeSigned: [signed("iphone", "apollo", days: 5), signed("iphone", "stremio-ios", days: 5)])
        #expect(build(ledger: two).devices[0].freeSlots == 1)
        #expect(build(ledger: two).devices[0].slotsLabel == "1 free slot")
        let reserved = build(config: config(reserved: ["iphone": 1]), ledger: two).devices[0]
        #expect(reserved.freeSlots == 0)
        #expect(reserved.slotsLabel == "no free slots")
        #expect(build(config: config(reserved: ["iphone": 1])).devices[0].slotsLabel == "2 free slots")
        #expect(build().devices[0].freeSlots == 3)
        // An unreadable ledger shows no slot free.
        let unread = build(ledgerReadable: false).devices[0]
        #expect(unread.freeSlots == 0 && unread.slotsLabel == "slots unknown")
        // An out-of-range stored reserve leaves the slots unknown: none free, never a count from a guessed reserve.
        for raw in [4, 9, 99, -1] {
            let card = build(config: config(reserved: ["iphone": raw])).devices[0]
            #expect(card.freeSlots == 0 && card.slotsLabel == "slots unknown", "reserve \(raw)")
            #expect(card.reservedSlots.isEmpty, "reserve \(raw)")
        }
    }

    @Test("a pending or lent slot is used, never free, whatever freeSigned says (the menu reads the slot records)")
    func pendingAndLentSlotsAreUsed() {
        func op(_ kind: LedgerSlotKind, by: LedgerSlotBy) -> LedgerSlotOp {
            LedgerSlotOp(kind: kind, by: by, startedAt: testNow, window: SlotRule.window(kind))
        }
        func ledger(_ slots: [LedgerSlot]) -> Ledger {
            var ledger = Ledger(freeSigned: [signed("iphone", "apollo", days: 5)], slots: slots)
            SlotRule.project(&ledger)
            return ledger
        }
        // apollo is signed and not yet recorded as a slot: 2 free. The lent app was uninstalled, so freeSigned still lists
        // nothing for it; the record alone makes it used.
        let lent = LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent, lentTo: "lab", since: testNow)
        #expect(build(ledger: ledger([lent])).devices[0].freeSlots == 1, "lent counts as used")
        let returning = LedgerSlot(
            device: "iphone", app: "stremio-ios", presence: .absent, lentTo: "lab", since: testNow, op: op(.install, by: .giveBack))
        #expect(build(ledger: ledger([returning])).devices[0].freeSlots == 1, "pending counts as used")
        let installing = LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent, op: op(.install, by: .install))
        #expect(build(ledger: ledger([installing])).devices[0].freeSlots == 1, "a pending plain install counts as used")
        // The same app in freeSigned and in a slot is counted by the stricter of the two, not twice.
        let both = Ledger(freeSigned: [signed("iphone", "apollo", days: 5)], slots: [
            LedgerSlot(device: "iphone", app: "apollo", presence: .present)
        ])
        #expect(build(ledger: both).devices[0].freeSlots == 2)
        // An unused record is not a slot.
        #expect(build(ledger: ledger([LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent)])).devices[0].freeSlots == 2)
        // The legacy shape (no slots key yet) is migrated in memory, so an older ledger reads the same.
        let legacy = Ledger(
            freeSigned: [signed("iphone", "apollo", days: 5)],
            lent: [LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: testNow, state: "lending", opAt: testNow)])
        #expect(build(ledger: legacy).devices[0].freeSlots == 1)
    }

    @Test("reserved slots are grey rows, never in the Renew menu")
    func reservedRows() {
        let one = build(config: config(reserved: ["iphone": 1]), ledger: installed(("iphone", "apollo", 5)))
        #expect(one.devices[0].reservedSlots == ["Reserved slot"])
        #expect(one.devices[0].renew.items.map(\.title) == ["All apps", "Apollo"])
        let two = build(config: config(reserved: ["iphone": 2]))
        #expect(two.devices[0].reservedSlots == ["Reserved slot (1)", "Reserved slot (2)"])
    }

    @Test("Renew… is visible but disabled, with the tooltip; All apps shows the count")
    func renewDisabled() {
        let card = build(ledger: installed(("iphone", "apollo", 5), ("iphone", "stremio-ios", 1))).devices[0]
        #expect(!card.renew.enabled)
        #expect(card.renew.tooltip == MenuSnapshotBuilder.renewDisabledTooltip)
        #expect(card.renew.tooltip?.contains("sideload refresh") == true)
        #expect(card.renew.items.first == MenuRenewMenu.Item(title: "All apps", detail: "2", due: false))
        #expect(card.renew.items.last?.due == true)
    }

    @Test("a visible device shows its transport and a filled dot; v1 shows no auto-renew text at all")
    func visibleDevice() {
        let ledger = installed(("iphone", "apollo", 5))
        let wifi = build(ledger: ledger, probe: .listed([listed(transport: .network)])).devices[0]
        #expect(wifi.connectionLabel == "Wi-Fi")
        #expect(wifi.dotFilled)
        #expect(wifi.offlineNote == nil)
        #expect(wifi.apps[0].exception == nil)
        let usb = build(ledger: ledger, probe: .listed([listed(transport: .wired)])).devices[0]
        #expect(usb.connectionLabel == "USB")
    }

    @Test("with refresh available, Auto-renew off is the only per-row exception, for a device not opted in")
    func autoRenewException() {
        let ledger = installed(("iphone", "apollo", 5))
        let off = build(ledger: ledger, autoRefreshAvailable: true).devices[0]
        #expect(off.apps[0].exception == "Auto-renew off")
        let on = build(config: config(auto: ["iphone"]), ledger: ledger, autoRefreshAvailable: true).devices[0]
        #expect(on.apps[0].exception == nil)
        // The flag off hides it whatever the device setting.
        #expect(build(config: config(auto: []), ledger: ledger, autoRefreshAvailable: false).devices[0].apps[0].exception == nil)
    }

    @Test("an offline device shows one line and no per-row text; the dot is hollow")
    func offlineCollapse() {
        let ledger = installed(("iphone", "apollo", 4), ("iphone", "stremio-ios", 4))
        let seen = testNow.addingTimeInterval(-3 * 3_600)
        let probe = DeviceProbe.listed([listed(link: "unavailable", lastSeen: seen)])
        let off = build(config: config(auto: ["iphone"]), ledger: ledger, probe: probe).devices[0]
        #expect(!off.dotFilled)
        #expect(off.connectionLabel == "offline")
        #expect(off.offlineNote == "Seen 3 h ago")
        #expect(off.apps.allSatisfy { $0.exception == nil })
        // Never seen: the header already says offline, so there is no line at all.
        let gone = build(ledger: ledger, probe: .listed([])).devices[0]
        #expect(gone.connectionLabel == "offline")
        #expect(gone.offlineNote == nil)
        #expect(gone.apps.allSatisfy { $0.exception == nil })
        let unpaired = build(ledger: ledger, probe: .listed([listed(paired: false)])).devices[0]
        #expect(unpaired.connectionLabel == "offline")
    }

    @Test("with refresh available, the offline line says whether it renews when back")
    func offlineLineWithRefresh() {
        let ledger = installed(("iphone", "apollo", 4))
        let probe = DeviceProbe.listed([listed(link: "unavailable", lastSeen: testNow.addingTimeInterval(-3 * 3_600))])
        let opted = build(config: config(auto: ["iphone"]), ledger: ledger, probe: probe, autoRefreshAvailable: true).devices[0]
        #expect(opted.offlineNote == "Seen 3 h ago · renews when back on Wi-Fi or USB")
        let notOpted = build(ledger: ledger, probe: probe, autoRefreshAvailable: true).devices[0]
        #expect(notOpted.offlineNote == "Seen 3 h ago · auto-renew off")
        #expect(notOpted.apps[0].exception == nil)
    }

    @Test("checking and failed probes are never shown as offline")
    func probeStates() {
        let ledger = installed(("iphone", "apollo", 4))
        let checking = build(ledger: ledger, probe: .checking)
        #expect(checking.checkingDevices)
        #expect(checking.devices[0].connectionLabel == "checking…")
        #expect(checking.devices[0].offlineNote == nil)
        let failed = build(ledger: ledger, probe: .failed)
        #expect(!failed.checkingDevices)
        #expect(failed.devices[0].connectionLabel == "status unknown")
        #expect(failed.devices[0].offlineNote == nil)
    }

    @Test("ago formatting")
    func ago() {
        #expect(MenuFormat.ago(from: testNow.addingTimeInterval(-20), now: testNow) == "just now")
        #expect(MenuFormat.ago(from: testNow.addingTimeInterval(-720), now: testNow) == "12 min ago")
        #expect(MenuFormat.ago(from: testNow.addingTimeInterval(-3 * 86_400), now: testNow) == "3 d ago")
        #expect(MenuFormat.ago(from: testNow.addingTimeInterval(500), now: testNow) == "just now")
    }

    @Test("cards are ordered phones and tablets first, the Apple TV last")
    func ordering() {
        let snapshot = build(config: config(devices: ["appletv", "iphone"]), probe: .checking)
        #expect(snapshot.devices.map(\.alias) == ["iphone", "appletv"])
    }

    @Test("the strip reads from the canary and the cert kit Export is hidden only while blocked")
    func stripAndExport() {
        let blocked = build(ledger: installed(("iphone", "apollo", 5)), canary: "blocked")
        #expect(blocked.strip.line == "Free account in use · Paid account blocked")
        #expect(!blocked.showsCertKitExport)
        let working = build(canary: "working")
        #expect(working.strip.paidText == "Paid account working")
        #expect(working.showsCertKitExport)
        #expect(build(canary: "error").strip.paid == .unknown)
    }
}

@Suite("menu: paid-side state")
struct MenuStateTests {
    private let fresh = installed(("iphone", "apollo", 6))

    @Test("blocked canary with healthy apps is blocked; working is ok; no data is unknown")
    func baseStates() {
        #expect(build(ledger: fresh, canary: "blocked").state == .blocked)
        #expect(build(ledger: fresh, canary: "working").state == .ok)
        #expect(build(ledger: fresh, canary: nil).state == .ok)
        #expect(build(canary: nil).state == .unknown)
        #expect(build(ledger: fresh, canary: "error").state == .unknown)
    }

    @Test("expiry outranks blocked; the worst app wins; expired is critical")
    func worstWins() {
        let due = installed(("iphone", "apollo", 6), ("iphone", "stremio-ios", 3))
        #expect(build(ledger: due, canary: "blocked").state == .warn)
        let critical = installed(("iphone", "apollo", 3), ("iphone", "stremio-ios", 0.5))
        #expect(build(ledger: critical, canary: "blocked").state == .critical)
        let expired = installed(("iphone", "apollo", -1))
        #expect(build(ledger: expired, canary: "working").state == .critical)
    }

    @Test("an app on an offline device still counts toward the icon")
    func offlineStillCounts() {
        let due = installed(("iphone", "apollo", 2))
        #expect(build(ledger: due, probe: .listed([])).state == .warn)
    }

    @Test("only a loaded panel has an icon; the rest are unknown")
    func panelIcon() {
        #expect(MenuPanel.loading.icon == .unknown)
        #expect(MenuPanel.failed(MenuIssue(code: "X", message: "m")).icon == .unknown)
        #expect(MenuPanel.firstRun(MenuIssue(code: "X", message: "m")).icon == .unknown)
        #expect(MenuPanel.loaded(build(ledger: fresh, canary: "working")).icon.state == .ok)
    }
}

@Suite("menu: countdown ring icon")
struct MenuIconTests {
    private func icon(
        _ days: Double?, canary: String? = nil, ledger extra: Ledger? = nil, renewing: Bool = false,
        renewFailed: Bool = false
    ) -> MenuIcon {
        var ledger = extra ?? Ledger()
        if let days { ledger = menuLedger([("iphone", "apollo", days)], base: ledger) }
        return MenuSnapshotBuilder.build(
            MenuInputs(
                now: testNow, canaryStatus: canary, config: config(), ledger: ledger, probe: .listed([listed()]),
                renewing: renewing, renewFailed: renewFailed)
        ).icon
    }

    @Test("state and fraction for each band, with the boundaries from the exact remaining time")
    func bands() {
        let cases: [(Double, MenuIcon.State)] = [
            (7, .ok), (6.5, .ok), (3.9, .ok), (3.01, .ok), (3.0, .due), (2.0, .due), (1.01, .due), (1.0, .critical),
            (0.5, .critical), (0.001, .critical), (0, .expired), (-2, .expired),
        ]
        for (days, state) in cases {
            let made = icon(days)
            #expect(made.state == state, "\(days) days")
            #expect(abs(made.fraction - min(max(days / 7, 0), 1)) < 1e-9, "\(days) days")
        }
        #expect(icon(30).fraction == 1)
        #expect(icon(30).state == .ok)
    }

    @Test("the ring is the soonest app across every device")
    func soonestAcrossDevices() {
        let ledger = installed(("iphone", "apollo", 6), ("appletv", "stremio-tvos", 2), ("iphone", "stremio-ios", 4))
        let made = MenuSnapshotBuilder.build(
            MenuInputs(
                now: testNow, canaryStatus: "blocked", config: config(devices: ["iphone", "appletv"]), ledger: ledger,
                probe: .listed([]))
        ).icon
        #expect(made.state == .due)
        #expect(abs(made.fraction - 2.0 / 7.0) < 1e-9)
    }

    @Test("an app whose device is no longer saved does not count")
    func unsavedDevice() {
        let ledger = installed(("gone", "apollo", 0.5))
        #expect(icon(6, ledger: ledger).state == .ok)
    }

    @Test("the paid canary does not drive the icon while free installs exist")
    func canaryIgnored() {
        #expect(icon(6, canary: "blocked").state == .ok)
        #expect(icon(6, canary: "error").state == .ok)
        #expect(icon(6, canary: nil).state == .ok)
        #expect(icon(2, canary: "working").state == .due)
    }

    @Test("with no free installs: the paid state falls back to ok or unknown; no data at all is unknown")
    func fallbackWithoutInstalls() {
        let working = icon(nil, canary: "working")
        #expect(working.state == .ok)
        #expect(working.fraction == 1)
        #expect(icon(nil, canary: "blocked").state == .unknown)
        #expect(icon(nil, canary: "error").state == .unknown)
        let none = icon(nil, canary: nil)
        #expect(none.state == .unknown)
        #expect(none.fraction == 0)
        #expect(none == .unknown)
    }

    @Test("the ring colour under renew failed comes from the assessed level, never from the remaining time alone")
    func ringColourFromLevel() {
        // The boundary is the assessed level: 3 days is due, 3.01 is ok.
        #expect(icon(3.0, renewFailed: true).ringIsDue)
        #expect(icon(2.0, renewFailed: true).ringIsDue)
        #expect(!icon(3.01, renewFailed: true).ringIsDue)
        #expect(!icon(6, renewFailed: true).ringIsDue)
        #expect(!icon(nil, canary: "working", renewFailed: true).ringIsDue)
        #expect(icon(2.0, renewing: true).ringIsDue)
        // The initialiser does not infer it from `remaining`.
        #expect(!MenuIcon(state: .renewFailed, fraction: 0.3, remaining: 86_400).ringIsDue)
        #expect(MenuIcon(state: .renewFailed, fraction: 0.3, ringIsDue: true).ringIsDue)
    }

    @Test("with no free installs the paid state maps to a full ring: warn is due, critical is critical")
    func paidFallbackLevels() {
        func make(_ paid: StatusState, renewFailed: Bool = false) -> MenuIcon {
            MenuIcon.make(soonest: nil, now: testNow, paid: paid, certChanged: false, renewFailed: renewFailed)
        }
        #expect(make(.ok) == MenuIcon(state: .ok, fraction: 1))
        #expect(make(.warn) == MenuIcon(state: .due, fraction: 1, ringIsDue: true))
        #expect(make(.critical) == MenuIcon(state: .critical, fraction: 1))
        #expect(make(.blocked) == .unknown)
        #expect(make(.unknown) == .unknown)
        // Free installs still win over any paid state.
        let free = MenuIcon.make(soonest: daysFromNow(6), now: testNow, paid: .critical, certChanged: false)
        #expect(free.state == .ok)
        // The due colour survives a failed renewal; critical outranks it.
        #expect(make(.warn, renewFailed: true).state == .renewFailed)
        #expect(make(.warn, renewFailed: true).ringIsDue)
        #expect(make(.critical, renewFailed: true).state == .critical)
        #expect(make(.warn).accessibilityLabel == "sideload: a paid item is due")
        #expect(make(.critical).accessibilityLabel == "sideload: a paid item is expiring or expired")
    }

    @Test("a suspended free identity (FREE_CERT_CHANGED) is the worst state, with or without installs")
    func certChanged() {
        let suspended = Ledger(
            freeSuspended: LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"]))
        #expect(icon(6, ledger: suspended).state == .certChanged)
        #expect(icon(-1, ledger: suspended).state == .certChanged)
        #expect(icon(0.5, ledger: suspended, renewFailed: true).state == .certChanged)
        let bare = icon(nil, ledger: suspended)
        #expect(bare.state == .certChanged)
        #expect(bare.fraction == 1)
        #expect(icon(6).state == .ok)
    }

    @Test("precedence: cert changed > expired > critical > renew failed > due > renewing > ok > unknown")
    func precedence() {
        #expect(MenuIcon.State.allCases == [.certChanged, .expired, .critical, .renewFailed, .due, .renewing, .ok, .unknown])
        // Flags never outrank expired or critical.
        #expect(icon(-1, renewing: true, renewFailed: true).state == .expired)
        #expect(icon(0.5, renewing: true, renewFailed: true).state == .critical)
        // Renew failed outranks due, renewing and ok.
        #expect(icon(2, renewing: true, renewFailed: true).state == .renewFailed)
        #expect(icon(6, renewFailed: true).state == .renewFailed)
        #expect(icon(nil, renewFailed: true).state == .renewFailed)
        // Due outranks renewing; renewing outranks ok and unknown.
        #expect(icon(2, renewing: true).state == .due)
        #expect(icon(6, renewing: true).state == .renewing)
        #expect(icon(nil, renewing: true).state == .renewing)
        // The ring keeps its value under the flags.
        #expect(abs(icon(6, renewFailed: true).fraction - 6.0 / 7.0) < 1e-9)
        #expect(icon(2, renewFailed: true).ringIsDue)
        #expect(!icon(6, renewFailed: true).ringIsDue)
    }

    @Test("renewing and renew failed are never set by the snapshot inputs by default")
    func flagsDefaultOff() {
        let inputs = MenuInputs(now: testNow, canaryStatus: nil, config: config(), ledger: Ledger(), probe: .checking)
        #expect(!inputs.renewing)
        #expect(!inputs.renewFailed)
    }

    @Test("accessibility text names the time left and the state")
    func accessibility() {
        #expect(icon(2.5).accessibilityLabel == "sideload: 2 days left, due")
        #expect(icon(6.5).accessibilityLabel == "sideload: 6 days left, all good")
        #expect(icon(1.5).accessibilityLabel == "sideload: 1 day left, due")
        #expect(icon(0.5).accessibilityLabel == "sideload: 12 hours left, critical")
        #expect(icon(0.01).accessibilityLabel == "sideload: under 1 hour left, critical")
        #expect(icon(-1).accessibilityLabel == "sideload: expired")
        #expect(icon(nil).accessibilityLabel == "sideload: status unknown")
        #expect(icon(nil, canary: "working").accessibilityLabel == "sideload: all good")
        #expect(icon(2.5, renewFailed: true).accessibilityLabel == "sideload: renewal failed, 2 days left")
        #expect(icon(6.5, renewing: true).accessibilityLabel == "sideload: renewing, 6 days left")
        let suspended = Ledger(freeSuspended: LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow))
        #expect(icon(6, ledger: suspended).accessibilityLabel == "sideload: certificate changed, renewal suspended")
    }
}

@Suite("menu: redaction")
struct MenuRedactionTests {
    @Test("a snapshot carries no UDID, CoreDevice ID, device name or identity name")
    func nothingIdentifying() {
        let ledger = installed(("iphone", "apollo", 2))
        let off = build(config: config(), ledger: ledger, probe: .listed([listed(link: "unavailable", lastSeen: testNow)]))
        let on = build(config: config(), ledger: ledger, probe: .listed([listed()]))
        for snapshot in [off, on] {
            let text = String(describing: snapshot)
            #expect(!text.contains(savedUdid("1")))
            #expect(!text.contains(String(savedUdid("1").suffix(8))))
            #expect(!text.contains(savedCoreId("1")))
            #expect(!text.contains("Secret Phone"))
            #expect(!text.contains("Robin"))
        }
    }

    @Test("issues are redacted: IDs reduce to four characters, identity names and user paths go")
    func issuesRedacted() {
        let issue = MenuIssue(
            code: "X", message: "device \(savedUdid("1")) at /Users/someone/x",
            fix: "Apple Development: Jane Doe (ABCDE12345)")
        #expect(!issue.message.contains(savedUdid("1")))
        #expect(issue.message.contains("…"))
        #expect(!issue.message.contains("someone"))
        #expect(issue.fix?.contains("Jane") == false)
    }
}

@Suite("menu: loader and doctor")
struct MenuLoaderTests {
    @Test("no config.json is a first run that carries the doctor's fix text")
    func firstRun() async throws {
        try await withTestHome { paths, _ in
            let (services, runner) = fakeServices(paths)
            guard case .firstRun(let issue) = MenuLoader.loadLocal(services) else {
                Issue.record("expected firstRun")
                return
            }
            #expect(issue.fix == DeviceCheck.fixSave)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("an unreadable config is a failed panel with code, message and fix")
    func failed() async throws {
        try await withTestHome { paths, _ in
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: paths.config))
            let (services, _) = fakeServices(paths)
            guard case .failed(let issue) = MenuLoader.loadLocal(services) else {
                Issue.record("expected failed")
                return
            }
            #expect(issue.code == "CONFIG_INVALID")
            #expect(issue.fix != nil)
        }
    }

    @Test("local load reads the config, the ledger and the last canary status; an unreadable ledger is a notice")
    func localLoad() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            try Data(#"{"ts":"2026-10-19T10:00:00Z","status":"blocked"}"#.utf8 + [10]).write(to: URL(fileURLWithPath: paths.canaryLog))
            try await LedgerStore(paths: paths).update { $0.freeSigned = [signed("iphone", "apollo", days: 5)] }
            let (services, runner) = fakeServices(paths)
            guard case .ready(let inputs) = MenuLoader.loadLocal(services) else {
                Issue.record("expected ready")
                return
            }
            #expect(inputs.canaryStatus == "blocked")
            #expect(inputs.ledger.freeSigned.count == 1)
            #expect(inputs.notices.isEmpty)
            #expect(runner.calls.isEmpty)  // local files only

            try Data("garbage".utf8).write(to: URL(fileURLWithPath: paths.ledger))
            guard case .ready(let degraded) = MenuLoader.loadLocal(services) else {
                Issue.record("expected ready")
                return
            }
            #expect(degraded.notices.first?.code == "LEDGER_INVALID")
            #expect(degraded.ledger.freeSigned.isEmpty)
        }
    }

    @Test("probing lists devices through devicectl once; no saved device means no call; a failure is .failed")
    func probe() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            var route = Route()
            route.devices = deviceListJSON(phoneEntryJSON())
            let (services, runner) = fakeServices(paths, route: route)
            let probe = await MenuLoader.probeDevices(services, saved: iphoneConfig())
            guard case .listed(let devices) = probe else {
                Issue.record("expected listed")
                return
            }
            #expect(devices.count == 1)
            #expect(runner.calls.count == 1)
            #expect(runner.calls[0].args.prefix(3).elementsEqual(["devicectl", "list", "devices"]))

            let (idle, idleRunner) = fakeServices(paths)
            #expect(await MenuLoader.probeDevices(idle, saved: Config()) == .listed([]))
            #expect(idleRunner.calls.isEmpty)

            var broken = Route()
            broken.devicectlCode = 1
            let (failing, _) = fakeServices(paths, route: broken)
            #expect(await MenuLoader.probeDevices(failing, saved: iphoneConfig()) == .failed)
        }
    }

    @Test("lastConnectionDate is parsed from devicectl output, with or without fractional seconds")
    func lastConnection() {
        #expect(DeviceList.parseDate("2026-10-19T09:00:00.000Z") == Date(timeIntervalSince1970: 1_792_400_400))
        #expect(DeviceList.parseDate("2026-10-19T09:00:00Z") == Date(timeIntervalSince1970: 1_792_400_400))
        #expect(DeviceList.parseDate("yesterday") == nil)
    }

    @Test("doctor runs in process through the runner and reduces to redacted rows")
    func doctor() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            var route = Route()
            route.devices = deviceListJSON(phoneEntryJSON())
            let (services, runner) = fakeServices(paths, route: route)
            let summary = await DoctorSummary.run(services)
            #expect(!summary.rows.isEmpty)
            #expect(summary.rows.contains { $0.severity == .ok })
            #expect(!runner.calls.isEmpty)
            #expect(summary.rows.allSatisfy { !$0.message.contains(savedUdid("1")) })
        }
        let row: [String: JSONValue] = [
            "id": .string("device"), "severity": .string("fail"), "message": .string("\(savedUdid("1")) gone"),
            "fix": .string("Plug it in"),
        ]
        let envelope = Envelope(
            ok: false, command: "doctor",
            data: ["checks": .array([.object(row)])], errors: [])
        let summary = DoctorSummary(envelope)
        #expect(!summary.ok)
        #expect(summary.rows.count == 1)
        #expect(summary.rows[0].severity == CheckResult.Severity.fail)
        #expect(!summary.rows[0].message.contains(savedUdid("1")))
        #expect(summary.rows[0].fix == "Plug it in")
    }
}
