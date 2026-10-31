import Foundation
import Testing

@testable import SideloadCore

// Reinstall previous version in the menu (design section 12): which stored build is "previous", what the row offers, why the
// control is off, the confirm, and the reading of the manifest. No network, no device, no real home.

private func storedProfile(days: Double) -> LedgerFreeProfile {
    LedgerFreeProfile(
        id: "iphone/apollo", device: "iphone", deviceTail: "…0001", app: "apollo", bundleId: menuBundleId("apollo"),
        profileUuid: "UUID-1", created: nil, expires: daysFromNow(days), certFp8: "12345678",
        file: "profiles/free/apollo/iphone/UUID-1.mobileprovision")
}

private func ledger(
    app: String = "apollo", installed: String = "3.9.0", profileDays: Double? = 7, appId: Bool = true
) -> Ledger {
    var ledger = menuLedger([("iphone", app, 5)])
    ledger.installs[0].version = installed
    if let profileDays {
        var profile = storedProfile(days: profileDays)
        profile.id = "iphone/\(app)"
        profile.app = app
        profile.bundleId = menuBundleId(app)
        ledger.freeProfiles = [profile]
    }
    if appId { ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId(app), epochStart: testNow.addingTimeInterval(-3_600))] }
    return ledger
}

private let sha38 = String(repeating: "38", count: 32)
private let sha37 = String(repeating: "37", count: 32)

private func previous(
    _ version: String, sha: String = sha38, build: String? = "141", minOS: String? = "15.0", size: Int64 = 44_000_000
) -> MenuPrevious {
    MenuPrevious(version: version, build: build, sha256: sha, size: size, minOS: minOS)
}

private func build(
    stored: [String: [MenuPrevious]]? = nil, app: String = "apollo", ledger body: Ledger? = nil, config: Config? = nil,
    apps: [String: DeviceAppsProbe]? = nil, probe: DeviceProbe? = nil, os: String? = nil, ledgerReadable: Bool = true
) -> MenuSnapshot {
    var listed = menuListed()
    listed.osVersion = os
    return MenuSnapshotBuilder.build(
        MenuInputs(
            now: testNow, canaryStatus: nil, config: config ?? addConfig(approved: [app]), ledger: body ?? ledger(app: app),
            probe: probe ?? .listed([listed]), ledgerReadable: ledgerReadable,
            deviceApps: apps ?? addRead("iphone", [menuBundleId(app)]), stored: stored ?? [app: [previous("3.8.0")]]))
}

private func availability(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuAvailability {
    MenuActions.availability(action, in: snapshot, now: testNow)
}

private func prompt(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuPrompt? {
    MenuActions.prompt(for: action, in: snapshot, now: testNow)
}

private func reinstall(_ to: MenuPrevious = previous("3.8.0"), from: String = "3.9.0", app: String = "apollo") -> MenuAction {
    .reinstallPrevious(device: "iphone", app: app, from: from, to: to)
}

private func entry(
    _ version: String, approved: Bool = true, pruned: Bool = false, app: String = "apollo", sha: String = sha38
) -> ManifestEntry {
    ManifestEntry(
        app: app, version: version, file: "\(app)/\(version)/App.ipa", urlHost: "github.com", sha256: sha, upstreamDigest: sha,
        size: 44_000_000, fetchedAt: testNow, approved: approved, build: "141", minOS: "15.0", inspectMinOS: "16.0",
        prunedAt: pruned ? testNow : nil)
}

@Suite("menu reinstall: the previous version rule")
struct MenuPreviousRuleTests {
    @Test("the newest older version wins, whatever the order they are listed in")
    func newestOlder() {
        let all = [previous("3.7.0"), previous("3.8.0"), previous("3.2.0"), previous("3.10.0"), previous("3.9.0")]
        #expect(MenuPrevious.pick(all, installed: "3.9.0")?.version == "3.8.0")
        #expect(MenuPrevious.pick(all.reversed(), installed: "3.9.0")?.version == "3.8.0")
        // 3.10.0 is newer than 3.9.0 by number, not by text.
        #expect(MenuPrevious.pick(all, installed: "3.10.0")?.version == "3.9.0")
        #expect(MenuPrevious.pick([previous("1.9.2b45"), previous("1.9.6b142")], installed: "1.9.8b150")?.version == "1.9.6b142")
    }

    @Test("equal, newer and unparseable versions are never previous; none left is nil")
    func skipped() {
        #expect(MenuPrevious.pick([previous("3.9.0")], installed: "3.9.0") == nil)
        #expect(MenuPrevious.pick([previous("3.10.0"), previous("4.0.0")], installed: "3.9.0") == nil)
        #expect(MenuPrevious.pick([previous("3.8.0-beta"), previous("v3.8.0"), previous("latest")], installed: "3.9.0") == nil)
        #expect(MenuPrevious.pick([previous("3.8.0"), previous("3.8.5-rc1")], installed: "3.9.0")?.version == "3.8.0")
        // An unparseable installed version offers nothing, and so does a build on one side only.
        #expect(MenuPrevious.pick([previous("3.8.0")], installed: "3.9.0-beta") == nil)
        #expect(MenuPrevious.pick([previous("1.9.2b45")], installed: "1.9.8") == nil)
        #expect(MenuPrevious.pick([], installed: "3.9.0") == nil)
    }

    @Test("only approved, unpruned entries whose file is on disk are candidates, by app")
    func candidates() {
        var manifest = Manifest()
        manifest.entries = [
            entry("3.8.0"), entry("3.7.0", approved: false), entry("3.6.0", pruned: true), entry("3.5.0"),
            entry("1.9.2b45", app: "stremio-ios"),
        ]
        let found = MenuPrevious.candidates(in: manifest) { $0.version != "3.5.0" }
        #expect(found["apollo"]?.map(\.version) == ["3.8.0"])
        #expect(found["stremio-ios"]?.map(\.version) == ["1.9.2b45"])
        // The facts the confirm shows come from the entry: the stricter minimum OS of the source and the binary.
        #expect(found["apollo"]?.first == MenuPrevious(version: "3.8.0", build: "141", sha256: sha38, size: 44_000_000, minOS: "16.0"))
    }

    @Test("the loader's read of the real manifest: a missing file, a pruned entry and an unreadable manifest are not offered")
    func fromDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        let services = Services(
            runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: paths)
        #expect(MenuPrevious.stored(services).isEmpty)

        var manifest = Manifest()
        manifest.entries = [entry("3.8.0"), entry("3.7.0"), entry("3.6.0", pruned: true)]
        try ManifestStore(paths: paths).save(manifest)
        // Only 3.8.0 and (as a leftover of a crash) 3.6.0 have a file; 3.7.0's is gone.
        for version in ["3.8.0", "3.6.0"] {
            try FileManager.default.createDirectory(atPath: "\(paths.downloads)/apollo/\(version)", withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(paths.downloads)/apollo/\(version)/App.ipa"))
        }
        #expect(MenuPrevious.stored(services)["apollo"]?.map(\.version) == ["3.8.0"])

        try Data("{".utf8).write(to: URL(fileURLWithPath: paths.manifest))
        #expect(MenuPrevious.stored(services).isEmpty)
    }
}

@Suite("menu reinstall: the row and its offer")
struct MenuReinstallRowTests {
    @Test("the row carries the previous version and offers it next to Update, not destructive")
    func offer() throws {
        let stored = ["apollo": [previous("3.8.0"), previous("3.7.0"), previous("3.9.0"), previous("3.10.0")]]
        let snapshot = build(stored: stored)
        let card = snapshot.devices[0]
        let row = try #require(card.apps.first)
        #expect(row.previous?.version == "3.8.0" && row.offersPrevious)
        let offers = MenuActions.rowOffers(row, card: card, snapshot: snapshot, now: testNow)
        let offer = try #require(offers.first { $0.kind == .reinstallPrevious })
        #expect(offer.label == "Reinstall previous version (3.8.0)…" && !offer.destructive)
        #expect(offer.action == reinstall() && offer.availability == .enabled)
        // Remove stays last.
        #expect(offers.last?.kind == .remove)
    }

    @Test("Stremio's version is written 1.9.2 (45)")
    func stremio() throws {
        let snapshot = build(
            stored: ["stremio-ios": [previous("1.9.2b45")]], app: "stremio-ios", ledger: ledger(app: "stremio-ios", installed: "1.9.6b142"))
        let row = try #require(snapshot.devices[0].apps.first)
        let offers = MenuActions.rowOffers(row, card: snapshot.devices[0], snapshot: snapshot, now: testNow)
        #expect(offers.first { $0.kind == .reinstallPrevious }?.label == "Reinstall previous version (1.9.2 (45))…")
    }

    @Test("no stored older build, or a hand-installed app: no offer")
    func none() throws {
        for stored in [[:], ["apollo": [previous("3.9.0"), previous("3.10.0")]], ["apollo": [previous("3.8.0-beta")]]] as [[String: [MenuPrevious]]] {
            let snapshot = build(stored: stored)
            let row = try #require(snapshot.devices[0].apps.first)
            #expect(row.previous == nil && !row.offersPrevious)
            #expect(!MenuActions.rowOffers(row, card: snapshot.devices[0], snapshot: snapshot, now: testNow).contains { $0.kind == .reinstallPrevious })
        }
        var byHand = Ledger()
        byHand.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let hand = try #require(build(ledger: byHand).devices[0].apps.first)
        #expect(!hand.recorded && hand.previous == nil && !hand.offersPrevious)
    }

    @Test("a row that is not on the device, or is lent, does not offer it")
    func presence() throws {
        var row = try #require(build().devices[0].apps.first)
        for presence in [AppPresence.notInstalled, .lent, .pending] {
            row.presence = presence
            #expect(!row.offersPrevious, "\(presence)")
        }
        for presence in [AppPresence.installed, .unconfirmed, .checking] {
            row.presence = presence
            #expect(row.offersPrevious, "\(presence)")
        }
    }

    @Test("a stored build does not change the icon, the countdown or Update's line")
    func untouched() throws {
        #expect(build().icon == build(stored: [:]).icon)
        let with = try #require(build().devices[0].apps.first)
        let without = try #require(build(stored: [:]).devices[0].apps.first)
        #expect(with.daysLabel == without.daysLabel && with.updateLine == without.updateLine)
    }
}

@Suite("menu reinstall: availability, Update's gates")
struct MenuReinstallAvailabilityTests {
    @Test("the rules, in order, with Update's reasons")
    func order() {
        #expect(availability(.reinstallPrevious(device: "nobody", app: "apollo", from: "3.9.0", to: previous("3.8.0")), build()) == .disabled("Device not found"))
        var suspended = ledger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        #expect(availability(reinstall(), build(ledger: suspended)) == .disabled("Free certificate changed"))
        #expect(availability(reinstall(), build(ledgerReadable: false)) == .disabled("Can't read the ledger"))
        #expect(availability(reinstall(), build(ledger: Ledger(), apps: addRead("iphone", []))) == .disabled("Not on iphone"))
        var signedOnly = Ledger()
        signedOnly.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        #expect(availability(reinstall(), build(ledger: signedOnly, apps: addRead())) == .disabled("Signed · not installed: use Install"))
        var lent = signedOnly
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        #expect(availability(reinstall(), build(ledger: lent, apps: addRead())) == .disabled("Lent to lab"))
        var pending = ledger()
        pending.slots[0].op = LedgerSlotOp(kind: .install, by: .install, startedAt: testNow, window: SlotRule.window(.install))
        SlotRule.project(&pending)
        #expect(availability(reinstall(), build(ledger: pending)) == .disabled("Change in progress on iphone"))
        #expect(availability(reinstall(), build(apps: [:], probe: .listed([]))) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(availability(reinstall(), build(apps: ["iphone": .checking])) == .disabled("Checking apps…"))
        #expect(availability(reinstall(), build(ledger: signedOnly, apps: addRead("iphone", [menuBundleId("apollo")]))) == .disabled("Installed by hand: no update check"))
        #expect(availability(reinstall(from: "3.8.5"), build()) == .disabled("Apollo is now 3.9.0, not 3.8.5"))
        #expect(availability(reinstall(), build()) == .enabled)
    }

    @Test("the previous version must still be the row's: gone, another version or another file blocks")
    func stillPrevious() {
        #expect(availability(reinstall(), build(stored: [:])) == .disabled("No previous version of Apollo is stored"))
        #expect(
            availability(reinstall(), build(stored: ["apollo": [previous("3.8.0"), previous("3.8.5")]]))
                == .disabled("The previous version of Apollo is now 3.8.5"))
        #expect(
            availability(reinstall(), build(stored: ["apollo": [previous("3.8.0", sha: sha37)]]))
                == .disabled("The stored file of Apollo 3.8.0 changed since you reviewed it"))
        // Not the installed-or-newer: the installed version moved on to 3.8.0 itself.
        #expect(availability(reinstall(), build(ledger: ledger(installed: "3.8.0"))) == .disabled("Apollo is now 3.8.0, not 3.9.0"))
    }

    @Test("the minimum OS of the stored build, when the device's is known")
    func minimumOS() {
        let needs17 = previous("3.8.0", minOS: "17.0")
        #expect(
            availability(reinstall(needs17), build(stored: ["apollo": [needs17]], os: "16.2"))
                == .disabled("Apollo 3.8.0 needs iOS 17.0 or later; iphone runs 16.2"))
        #expect(availability(reinstall(needs17), build(stored: ["apollo": [needs17]], os: "17.0")) == .enabled)
        #expect(availability(reinstall(needs17), build(stored: ["apollo": [needs17]], os: nil)) == .enabled)
    }

    @Test("the App ID budget gates only a provision that would register a new App ID")
    func budget() {
        var spent = ledger(profileDays: 3, appId: false)
        spent.freeAppIds = (0..<6).map { LedgerFreeAppId(bundleId: "io.example.o\($0)", epochStart: testNow.addingTimeInterval(-3_600)) }
        #expect(availability(reinstall(), build(ledger: spent)) == .disabled("App ID limit: 6 of 10 used in 7 days, 4 reserved"))
        var fresh = spent
        fresh.freeProfiles = [storedProfile(days: 6.5)]
        #expect(availability(reinstall(), build(ledger: fresh)) == .enabled)
        // The source need not be approved any more: the build is already approved and on disk.
        #expect(availability(reinstall(), build(config: addConfig(approved: []))) == .enabled)
    }

    @Test("it is not a fetch stage and stops for the owner's Cancel")
    func stage() {
        #expect(!reinstall().isFetchStage && reinstall().device == "iphone" && reinstall().chain == nil)
        #expect(MenuActions.cancellable(reinstall()))
    }
}

@Suite("menu reinstall: the confirm")
struct MenuReinstallPromptTests {
    @Test("the title, the lines and the labels, exactly, with a fresh profile")
    func fresh() throws {
        let shown = try #require(prompt(reinstall(), build(ledger: ledger(profileDays: 6.5))))
        #expect(shown.title == "Reinstall Apollo 3.8.0 on iphone (now 3.9.0)")
        #expect(shown.confirmLabel == "Reinstall 3.8.0" && !shown.destructive && shown.apps.isEmpty)
        #expect(shown.runningLabel == "Reinstalling Apollo 3.8.0 on iphone…")
        #expect(
            shown.lines == [
                "Apollo 3.8.0 (build 141) · 44.0 MB · iOS 15.0 or later",
                "SHA-256 \(sha38)",
                "Profile reused (7 d left), no portal change",
                "Installs over the existing app: its data is kept, slots unchanged",
                "An older version may not read data the newer one wrote",
                "If iOS refuses the older build, the installed app is left as it is",
                "Renewals keep this version until you update",
                "Keep the device unlocked and connected",
                "macOS may ask for keychain access",
            ])
        #expect(shown.monospacedLines == [1] && shown.lines[1].hasSuffix(sha38))
        let text = shown.lines.joined(separator: "\n") + shown.title
        #expect(!text.contains(savedUdid("1")) && !text.contains("Robin"))
    }

    @Test("the profile line is Update's: renewed under 6 days, with the App ID it uses")
    func profileLine() throws {
        let existing = try #require(prompt(reinstall(), build(ledger: ledger(profileDays: 3))))
        #expect(existing.lines[2] == "Renews the 7-day profile; existing App ID")
        let none = try #require(prompt(reinstall(), build(ledger: ledger(profileDays: nil))))
        #expect(none.lines[2] == "Renews the 7-day profile; existing App ID")
        let newId = try #require(prompt(reinstall(), build(ledger: ledger(profileDays: 3, appId: false))))
        #expect(newId.lines[2] == "Renews the 7-day profile; creates one App ID (0 of 10 used in 7 days, 4 reserved)")
    }

    @Test("Stremio's build is written once and a third-party index adds no claim about the file")
    func stremio() throws {
        let old = previous("1.9.2b45", build: "45", minOS: "14.0", size: 2_000_000_000)
        let snapshot = build(
            stored: ["stremio-ios": [old]], app: "stremio-ios", ledger: ledger(app: "stremio-ios", installed: "1.9.6b142"))
        let shown = try #require(prompt(.reinstallPrevious(device: "iphone", app: "stremio-ios", from: "1.9.6b142", to: old), snapshot))
        #expect(shown.title == "Reinstall Stremio 1.9.2 (45) on iphone (now 1.9.6 (142))")
        #expect(shown.confirmLabel == "Reinstall 1.9.2 (45)")
        #expect(shown.lines[0] == "Stremio 1.9.2 (45) · 2.0 GB · iOS 14.0 or later")
    }

    @Test("a prompt only for an available action")
    func unavailable() {
        #expect(prompt(reinstall(), build(stored: [:])) == nil)
        #expect(prompt(reinstall(), build(apps: [:], probe: .listed([]))) == nil)
    }

    @Test("the confirm button runs what was shown; a changed profile line is shown again; a gone or changed build is blocked")
    func reconfirm() throws {
        let snapshot = build(ledger: ledger(profileDays: 6.5))
        let shown = try #require(prompt(reinstall(), snapshot))
        #expect(MenuActions.reconfirm(reinstall(), shown: shown, in: snapshot, now: testNow) == .run(shown))
        guard case .show(let again) = MenuActions.reconfirm(reinstall(), shown: shown, in: build(ledger: ledger(profileDays: 3)), now: testNow)
        else {
            Issue.record("expected a changed confirm")
            return
        }
        #expect(again.lines[2] == "Renews the 7-day profile; existing App ID")
        // The file was pruned (or never was): the loader no longer lists it.
        #expect(
            MenuActions.reconfirm(reinstall(), shown: shown, in: build(stored: [:], ledger: ledger(profileDays: 6.5)), now: testNow)
                == .blocked("No previous version of Apollo is stored"))
        // A different version became the previous one.
        #expect(
            MenuActions.reconfirm(reinstall(), shown: shown, in: build(stored: ["apollo": [previous("3.8.5")]], ledger: ledger(profileDays: 6.5)), now: testNow)
                == .blocked("The previous version of Apollo is now 3.8.5"))
        // The same version with another file.
        #expect(
            MenuActions.reconfirm(reinstall(), shown: shown, in: build(stored: ["apollo": [previous("3.8.0", sha: sha37)]], ledger: ledger(profileDays: 6.5)), now: testNow)
                == .blocked("The stored file of Apollo 3.8.0 changed since you reviewed it"))
        // The installed version changed under the confirm.
        #expect(
            MenuActions.reconfirm(reinstall(), shown: shown, in: build(ledger: ledger(installed: "3.9.1", profileDays: 6.5)), now: testNow)
                == .blocked("Apollo is now 3.9.1, not 3.9.0"))
    }
}
