import Foundation
import Testing

@testable import SideloadCore

// Update in the menu (design section 12): the row's facts, what is offered, why a control is off, the two confirms, the
// Install update extension, and the panel's reads of `updates.json`. No network, no device, no real home.

private func listing(_ version: String, minOS: String? = nil, error: String? = nil, ago: TimeInterval = 3 * 3600) -> MenuUpstream {
    MenuUpstream(version: version, minOS: minOS, checkedAt: testNow.addingTimeInterval(-ago), errorCode: error)
}

private func storedProfile(_ app: String, days: Double) -> LedgerFreeProfile {
    LedgerFreeProfile(
        id: "iphone/\(app)", device: "iphone", deviceTail: "…0001", app: app, bundleId: menuBundleId(app), profileUuid: "UUID-1",
        created: nil, expires: daysFromNow(days), certFp8: "12345678", file: "profiles/free/\(app)/iphone/UUID-1.mobileprovision")
}

/// The ledger after `install` put `app` at `installed` on the iPhone, with a stored profile, a live App ID and `extensions` stripped.
private func updLedger(
    app: String = "apollo", installed: String = "3.9.0", profileDays: Double? = 7, appId: Bool = true, extensions: Int = 2,
    signed: LedgerFreeSigned? = nil
) -> Ledger {
    var ledger = menuLedger([("iphone", app, 5)])
    ledger.installs[0].version = installed
    ledger.installs[0].strippedExtensions = (0..<extensions).map { LedgerStrippedExtension(path: "PlugIns/E\($0).appex", bundleId: nil) }
    if let profileDays { ledger.freeProfiles = [storedProfile(app, days: profileDays)] }
    if appId { ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId(app), epochStart: testNow.addingTimeInterval(-3_600))] }
    if let signed { ledger.freeSigned = [signed] }
    return ledger
}

private func updBuild(
    _ upstream: [String: MenuUpstream]? = nil, app: String = "apollo", config: Config? = nil, ledger: Ledger? = nil,
    apps: [String: DeviceAppsProbe]? = nil, probe: DeviceProbe? = nil, os: String? = nil, ledgerReadable: Bool = true
) -> MenuSnapshot {
    var listed = menuListed()
    listed.osVersion = os
    return MenuSnapshotBuilder.build(
        MenuInputs(
            now: testNow, canaryStatus: nil, config: config ?? addConfig(approved: [app]), ledger: ledger ?? updLedger(app: app),
            probe: probe ?? .listed([listed]), ledgerReadable: ledgerReadable,
            deviceApps: apps ?? addRead("iphone", [menuBundleId(app)]), upstream: upstream ?? [app: listing("3.10.0")]))
}

private func availability(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuAvailability {
    MenuActions.availability(action, in: snapshot, now: testNow)
}

private func prompt(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuPrompt? {
    MenuActions.prompt(for: action, in: snapshot, now: testNow)
}

private let updFetch = MenuAction.updateFetch(device: "iphone", app: "apollo", from: "3.9.0")

private func newer(_ version: String = "3.10.0", extensions: Int = 2) -> MenuFetched {
    var fetched = addFetched
    fetched.version = version
    fetched.extensionCount = extensions
    return fetched
}

private func updApprove(_ fetched: MenuFetched = newer(), from: String = "3.9.0", app: String = "apollo") -> MenuAction {
    .updateApprove(device: "iphone", app: app, from: from, fetched: fetched)
}

@Suite("menu update: the row")
struct MenuUpdateRowTests {
    @Test("a newer listed version is a second line and a menu item; 3.10.0 is newer than 3.9.0")
    func newerListed() throws {
        let snapshot = updBuild()
        let card = snapshot.devices[0]
        let row = try #require(card.apps.first)
        #expect(row.installedVersion == "3.9.0" && row.signedVersion == nil && row.recorded)
        #expect(row.update == MenuUpdateInfo(version: "3.10.0", state: .newer, minOS: nil, checkedAt: testNow.addingTimeInterval(-10_800), checkFailed: false))
        #expect(row.updateLine == "Update available · 3.9.0 → 3.10.0" && row.offersUpdate)
        let offers = MenuActions.rowOffers(row, card: card, snapshot: snapshot, now: testNow)
        let update = try #require(offers.first { $0.kind == .update })
        #expect(update.label == "Update to 3.10.0…" && update.action == updFetch && update.availability == .enabled)
        // The daysLabel and the bar are the countdown's, unchanged.
        #expect(row.daysLabel == "5 d" && row.showsBar)
    }

    @Test("Stremio's build is written as 1.9.2 (45)")
    func stremio() throws {
        let snapshot = updBuild(["stremio-ios": listing("1.9.6b142")], app: "stremio-ios", ledger: updLedger(app: "stremio-ios", installed: "1.9.2b45"))
        let row = try #require(snapshot.devices[0].apps.first)
        #expect(row.updateLine == "Update available · 1.9.2 (45) → 1.9.6 (142)")
        let offers = MenuActions.rowOffers(row, card: snapshot.devices[0], snapshot: snapshot, now: testNow)
        #expect(offers.first { $0.kind == .update }?.label == "Update to 1.9.6 (142)…")
    }

    @Test("only a strictly newer, parseable version is offered: equal, older and odd ones are not")
    func states() throws {
        for (listed, state) in [
            ("3.9.0", MenuUpdateState.current), ("3.8.9", .older), ("2.99.0", .older), ("3.10.0-beta", .unknown), ("latest", .unknown),
        ] {
            let row = try #require(updBuild(["apollo": listing(listed)]).devices[0].apps.first)
            #expect(row.update?.state == state, "\(listed)")
            #expect(row.updateLine == nil && !row.offersUpdate, "\(listed)")
        }
        // The installed side may be the odd one.
        let odd = try #require(updBuild(ledger: updLedger(installed: "3.9.0-beta")).devices[0].apps.first)
        #expect(odd.update?.state == .unknown && odd.updateLine == nil)
    }

    @Test("no listing, no approved source, or a hand-installed app: no update")
    func absent() throws {
        #expect(updBuild([:]).devices[0].apps.first?.update == nil)
        // An older updates.json still holds the app, but the owner no longer approves its source.
        let unapproved = updBuild(config: addConfig(approved: []))
        #expect(unapproved.devices[0].apps.first?.update == nil && unapproved.devices[0].apps.first?.updateLine == nil)
        // Signed by sideload, put on the device by hand: no installs[] record.
        var byHand = Ledger()
        byHand.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        let hand = try #require(updBuild(ledger: byHand).devices[0].apps.first)
        #expect(!hand.recorded && hand.presence == .installed)
        #expect(hand.update == nil && hand.installedVersion == nil && hand.profile == nil && hand.updateLine == nil)
    }

    @Test("a row that is not on the device, or is lent, shows no update line")
    func presence() throws {
        var row = try #require(updBuild().devices[0].apps.first)
        for presence in [AppPresence.notInstalled, .lent, .pending] {
            row.presence = presence
            #expect(!row.offersUpdate && row.updateLine == nil, "\(presence)")
        }
        for presence in [AppPresence.installed, .unconfirmed, .checking] {
            row.presence = presence
            #expect(row.offersUpdate, "\(presence)")
        }
        // Not read (device offline): the ledger's record still lists the update, as it lists the countdown.
        let offline = updBuild(apps: [:], probe: .listed([]))
        #expect(offline.devices[0].apps.first?.presence == .unconfirmed && offline.devices[0].apps.first?.updateLine != nil)
    }

    @Test("a failed last check keeps the last good version and says so")
    func checkFailed() throws {
        let row = try #require(updBuild(["apollo": listing("3.10.0", error: "FETCH_NETWORK")]).devices[0].apps.first)
        #expect(row.update?.version == "3.10.0" && row.update?.checkFailed == true && row.updateLine != nil)
    }

    @Test("the row carries what a provision would do: the stored profile, the App ID, the stripped extensions")
    func profileFacts() throws {
        let row = try #require(updBuild().devices[0].apps.first)
        #expect(row.profile == MenuRowProfile(storedExpires: daysFromNow(7), newAppId: false, appIdAllowed: true, installedExtensions: 2))
        let bare = try #require(updBuild(ledger: updLedger(profileDays: nil, appId: false, extensions: 0)).devices[0].apps.first)
        #expect(bare.profile == MenuRowProfile(storedExpires: nil, newAppId: true, appIdAllowed: true, installedExtensions: 0))
        // A new App ID that does not fit: 6 used + 4 reserved + 1 > 10.
        var full = updLedger(appId: false)
        full.freeAppIds = (0..<6).map { LedgerFreeAppId(bundleId: "io.example.o\($0)", epochStart: testNow.addingTimeInterval(-3_600)) }
        #expect(updBuild(ledger: full).devices[0].apps.first?.profile?.appIdAllowed == false)
    }

    @Test("an update does not change the icon")
    func icon() {
        #expect(updBuild().icon == updBuild([:]).icon)
    }
}

@Suite("menu update: availability, first match wins")
struct MenuUpdateAvailabilityTests {
    @Test("the rules, in order, with their exact reasons")
    func order() {
        // 1. the device
        #expect(availability(.updateFetch(device: "nobody", app: "apollo", from: "3.9.0"), updBuild()) == .disabled("Device not found"))
        // 2. the free-team stops
        var suspended = updLedger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        #expect(availability(updFetch, updBuild(ledger: suspended)) == .disabled("Free certificate changed"))
        #expect(availability(updFetch, updBuild(ledgerReadable: false)) == .disabled("Can't read the ledger"))
        // 3. a row, and where it is
        #expect(availability(updFetch, updBuild(ledger: Ledger(), apps: addRead("iphone", []))) == .disabled("Not on iphone"))
        var signedOnly = Ledger()
        signedOnly.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        #expect(availability(updFetch, updBuild(ledger: signedOnly, apps: addRead())) == .disabled("Signed · not installed: use Install"))
        var lent = signedOnly
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        #expect(availability(updFetch, updBuild(ledger: lent, apps: addRead())) == .disabled("Lent to lab"))
        #expect(availability(updFetch, updBuild(apps: [:], probe: .listed([]))) == .disabled("Not confirmed on the device"))
        #expect(availability(updFetch, updBuild(apps: ["iphone": .checking])) == .disabled("Checking apps…"))
        // 4. a recorded install at the version the owner saw
        #expect(availability(updFetch, updBuild(ledger: signedOnly, apps: addRead("iphone", [menuBundleId("apollo")]))) == .disabled("Installed by hand: no update check"))
        #expect(
            availability(.updateFetch(device: "iphone", app: "apollo", from: "3.8.0"), updBuild())
                == .disabled("Apollo is now 3.9.0, not 3.8.0"))
        // 5. an approved source
        #expect(availability(updFetch, updBuild(config: addConfig(approved: []))) == .disabled("Not an approved source"))
        // 6. a newer listed version
        #expect(availability(updFetch, updBuild([:])) == .disabled("No update listed"))
        #expect(availability(updFetch, updBuild(["apollo": listing("3.9.0")])) == .disabled("Up to date"))
        #expect(availability(updFetch, updBuild(["apollo": listing("3.8.0")])) == .disabled("No newer version listed"))
        #expect(availability(updFetch, updBuild(["apollo": listing("3.10.0-rc1")])) == .disabled("Versions can't be compared"))
        // 7. the minimum OS of the listing, when the device's is known
        let needs17 = ["apollo": listing("3.10.0", minOS: "17.0")]
        #expect(availability(updFetch, updBuild(needs17, os: "16.2")) == .disabled("Apollo 3.10.0 needs iOS 17.0 or later; iphone runs 16.2"))
        #expect(availability(updFetch, updBuild(needs17, os: "17.0")) == .enabled)
        #expect(availability(updFetch, updBuild(needs17, os: nil)) == .enabled)
        #expect(availability(updFetch, updBuild()) == .enabled)
    }

    @Test("a profile with under 6 days left is allowed: the update renews it; a fresh one is reused")
    func profileDays() {
        for days in [0.5, 3.0, 5.9, 6.5] {
            #expect(availability(updFetch, updBuild(ledger: updLedger(profileDays: days))) == .enabled, "\(days)")
        }
        #expect(availability(updFetch, updBuild(ledger: updLedger(profileDays: nil))) == .enabled)
    }

    @Test("the App ID budget gates only a provision that would register a new App ID")
    func budget() {
        var spent = updLedger(profileDays: 3, appId: false)
        spent.freeAppIds = (0..<6).map { LedgerFreeAppId(bundleId: "io.example.o\($0)", epochStart: testNow.addingTimeInterval(-3_600)) }
        let limit = MenuAvailability.disabled("App ID limit: 6 of 10 used in 7 days, 4 reserved")
        #expect(availability(updFetch, updBuild(ledger: spent)) == limit)
        #expect(availability(updApprove(), updBuild(ledger: spent)) == limit)
        // A fresh profile skips provision, so nothing is spent.
        var fresh = spent
        fresh.freeProfiles = [storedProfile("apollo", days: 6.5)]
        #expect(availability(updFetch, updBuild(ledger: fresh)) == .enabled)
        // A reused App ID costs none, whatever the budget.
        var reused = spent
        reused.freeAppIds[0] = LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))
        #expect(availability(updFetch, updBuild(ledger: reused)) == .enabled)
        // An unknown budget stops only a new App ID.
        var badBudget = addConfig(approved: ["apollo"])
        badBudget.extra["freeTeam"] = .object(["reservedAppIds": 99])
        #expect(availability(updFetch, updBuild(config: badBudget, ledger: updLedger(profileDays: 3, appId: false))) == .disabled("App ID budget unknown"))
        #expect(availability(updFetch, updBuild(config: badBudget, ledger: updLedger(profileDays: 3))) == .enabled)
    }

    @Test("stage 2 re-applies the rules and refuses a fetched version that is not newer than the installed one")
    func approval() {
        #expect(availability(updApprove(), updBuild()) == .enabled)
        // The listing is not needed: what was fetched decides.
        #expect(availability(updApprove(), updBuild([:])) == .enabled)
        #expect(availability(updApprove(newer("3.9.0")), updBuild()) == .disabled("Apollo 3.9.0 is not newer than 3.9.0"))
        #expect(availability(updApprove(newer("3.8.0")), updBuild()) == .disabled("Apollo 3.8.0 is not newer than 3.9.0"))
        #expect(availability(updApprove(newer("3.10.0-beta")), updBuild()) == .disabled("Apollo 3.10.0-beta is not newer than 3.9.0"))
        #expect(availability(updApprove(newer("3.10.0")), updBuild(config: addConfig(approved: []))) == .disabled("Not an approved source"))
        #expect(availability(updApprove(from: "3.8.0"), updBuild()) == .disabled("Apollo is now 3.9.0, not 3.8.0"))
        // The fetched file's minimum OS, not the listing's.
        var strict = newer()
        strict.minOS = "17.0"
        #expect(availability(updApprove(strict), updBuild(os: "16.2")) == .disabled("Apollo 3.10.0 needs iOS 17.0 or later; iphone runs 16.2"))
        #expect(availability(updApprove(strict), updBuild(os: "17.1")) == .enabled)
        #expect(availability(updApprove(), updBuild(apps: [:], probe: .listed([]))) == .disabled("Not confirmed on the device"))
    }

    @Test("both stages stop for the owner's Cancel, and the fetch stage is a fetch stage")
    func stages() {
        #expect(MenuActions.cancellable(updFetch) && MenuActions.cancellable(updApprove()))
        #expect(updFetch.isFetchStage && !updApprove().isFetchStage && updFetch.device == "iphone" && updApprove().device == "iphone")
    }
}

@Suite("menu update: the two confirms")
struct MenuUpdatePromptTests {
    @Test("confirm 1: installed against listed and how old that is, a download, nothing approved, signed or installed")
    func fetchText() throws {
        let shown = try #require(prompt(updFetch, updBuild()))
        #expect(shown.title == "Fetch Apollo update for iphone")
        #expect(shown.confirmLabel == "Fetch" && !shown.destructive && shown.runningLabel == "Fetching Apollo update…")
        #expect(
            shown.lines == [
                "Installed 3.9.0; listed 3.10.0 (checked 3 h ago)",
                "Downloads the Apollo release from github.com and checks it",
                "Nothing is approved, signed or installed; iphone and the portal are unchanged",
            ])
        let failed = try #require(prompt(updFetch, updBuild(["apollo": listing("3.10.0", error: "FETCH_NETWORK")])))
        #expect(failed.lines[0] == "Installed 3.9.0; listed 3.10.0 (checked 3 h ago); the latest check failed")
        let stremio = try #require(
            prompt(
                .updateFetch(device: "iphone", app: "stremio-ios", from: "1.9.2b45"),
                updBuild(["stremio-ios": listing("1.9.6b142")], app: "stremio-ios", ledger: updLedger(app: "stremio-ios", installed: "1.9.2b45"))))
        #expect(stremio.lines[0] == "Installed 1.9.2 (45); listed 1.9.6 (142) (checked 3 h ago)")
        #expect(stremio.lines[1] == "Downloads the Stremio release from dl.strem.io (third-party index) and checks it")
        #expect(prompt(updFetch, updBuild([:])) == nil)
    }

    @Test("confirm 2 with a fresh profile: the facts, the full SHA-256, the approval, the reuse, the data kept")
    func approveFresh() throws {
        let shown = try #require(prompt(updApprove(), updBuild(ledger: updLedger(profileDays: 6.5))))
        #expect(shown.title == "Approve and update Apollo 3.9.0 → 3.10.0 on iphone")
        #expect(shown.confirmLabel == "Approve and update" && !shown.destructive)
        #expect(shown.runningLabel == "Updating Apollo 3.9.0 → 3.10.0 on iphone…")
        #expect(
            shown.lines == [
                "Apollo 3.10.0 (build 142) · 45.2 MB · iOS 16.0 or later",
                "SHA-256 \(addSha)",
                "Matches the publisher's",
                "2 extensions will be removed",
                "Approves this exact version for signing",
                "Profile reused (7 d left), no portal change",
                "Installs over the existing app: its data is kept, slots unchanged",
                "Keep the device unlocked and connected",
                "macOS may ask for keychain access",
            ])
        #expect(shown.monospacedLines == [1] && shown.lines[1].hasSuffix(addSha))
        let text = shown.lines.joined(separator: "\n") + shown.title
        #expect(!text.contains(savedUdid("1")) && !text.contains("Robin") && !text.contains("signing lock"))
    }

    @Test("confirm 2 says the profile is renewed when it has under 6 days, with the App ID it uses")
    func approveRenews() throws {
        let existing = try #require(prompt(updApprove(), updBuild(ledger: updLedger(profileDays: 3))))
        #expect(existing.lines.contains("Renews the 7-day profile; existing App ID"))
        #expect(!existing.lines.contains { $0.hasPrefix("Profile reused") })
        let none = try #require(prompt(updApprove(), updBuild(ledger: updLedger(profileDays: nil))))
        #expect(none.lines.contains("Renews the 7-day profile; existing App ID"))
        let newId = try #require(prompt(updApprove(), updBuild(ledger: updLedger(profileDays: 3, appId: false))))
        #expect(newId.lines.contains("Renews the 7-day profile; creates one App ID (0 of 10 used in 7 days, 4 reserved)"))
    }

    @Test("confirm 2 names the extension count and how it differs from the installed build")
    func extensions() throws {
        func lines(installed: Int, fetched: Int) throws -> [String] {
            try #require(prompt(updApprove(newer(extensions: fetched)), updBuild(ledger: updLedger(extensions: installed)))).lines
        }
        #expect(try lines(installed: 2, fetched: 2).contains("2 extensions will be removed"))
        #expect(try lines(installed: 1, fetched: 2).contains("2 extensions will be removed (1 more than 3.9.0)"))
        #expect(try lines(installed: 3, fetched: 1).contains("1 extension will be removed (2 fewer than 3.9.0)"))
        #expect(try lines(installed: 3, fetched: 0).contains("No extensions will be removed (3 fewer than 3.9.0)"))
        #expect(try !lines(installed: 0, fetched: 0).contains { $0.contains("xtension") })
    }

    @Test("confirm 2 for a third-party index says so; an earlier approval is said; Stremio's build is not repeated")
    func thirdParty() throws {
        var fetched = MenuFetched(
            version: "1.9.6b142", build: "142", sha256: addSha, size: 2_000_000_000, minOS: "14.0", extensionCount: 2, alreadyApproved: true)
        fetched.extensionCount = 2
        let ledger = updLedger(app: "stremio-ios", installed: "1.9.2b45")
        let shown = try #require(
            prompt(
                .updateApprove(device: "iphone", app: "stremio-ios", from: "1.9.2b45", fetched: fetched),
                updBuild(["stremio-ios": listing("1.9.6b142")], app: "stremio-ios", ledger: ledger)))
        #expect(shown.title == "Approve and update Stremio 1.9.2 (45) → 1.9.6 (142) on iphone")
        #expect(shown.lines[0] == "Stremio 1.9.6 (142) · 2.0 GB · iOS 14.0 or later")
        #expect(shown.lines[2] == "Matches the index's; a third party, so this guards against corruption, not a bad index")
        #expect(shown.lines.contains("Approves this exact version for signing (approved earlier)"))
    }

    @Test("the confirm button runs what was shown: a changed line is shown again, a vanished update is blocked")
    func reconfirm() throws {
        let snapshot = updBuild(ledger: updLedger(profileDays: 6.5))
        let shown = try #require(prompt(updApprove(), snapshot))
        #expect(MenuActions.reconfirm(updApprove(), shown: shown, in: snapshot, now: testNow) == .run(shown))
        // The profile fell under 6 days meanwhile: the confirm now says it renews.
        guard case .show(let again) = MenuActions.reconfirm(updApprove(), shown: shown, in: updBuild(ledger: updLedger(profileDays: 3)), now: testNow) else {
            Issue.record("expected a changed confirm")
            return
        }
        #expect(again.lines.contains("Renews the 7-day profile; existing App ID"))
        #expect(
            MenuActions.reconfirm(updApprove(newer("3.9.0")), shown: shown, in: snapshot, now: testNow)
                == .blocked("Apollo 3.9.0 is not newer than 3.9.0"))
    }
}

@Suite("menu update: Install update for a newer signed version")
struct MenuUpdateInstallTests {
    private func signed(_ version: String, days: Double = 5, uuid: String = "UUID-1") -> LedgerFreeSigned {
        var build = menuSigned("iphone", "apollo", days: days, uuid: uuid)
        build.version = version
        return build
    }

    private func row(_ build: LedgerFreeSigned?) throws -> MenuAppRow {
        try #require(updBuild([:], ledger: updLedger(signed: build)).devices[0].apps.first)
    }

    @Test("a signed build of another, newer version on the same profile is an update to install")
    func sameProfileNewerVersion() throws {
        let row = try row(signed("3.10.0"))
        #expect(row.signedVersion == "3.10.0" && row.newerSigned)
        let snapshot = updBuild([:], ledger: updLedger(signed: signed("3.10.0")))
        let card = snapshot.devices[0]
        let install = try #require(MenuActions.rowOffers(row, card: card, snapshot: snapshot, now: testNow).first { $0.kind == .installUpdate })
        #expect(install.label == "Install update" && install.availability == .enabled)
        let shown = try #require(prompt(install.action, snapshot))
        #expect(shown.lines.first == "Installs the newer signed build of Apollo on iphone")
        #expect(shown.lines.contains("Version 3.9.0 → 3.10.0") && shown.lines.contains("Slots unchanged"))
    }

    @Test("the same version, an older one, an unparseable one and an expired build are not")
    func notAnUpdate() throws {
        for build in [signed("3.9.0"), signed("3.8.0"), signed("3.10.0-beta"), signed("3.10.0", days: -1)] {
            let row = try row(build)
            #expect(!row.newerSigned, "\(build.version) \(build.profileExpires)")
        }
        #expect(try !row(nil).newerSigned)
        // A same-version build on a longer-lived profile is still the existing, profile-only kind.
        var longer = signed("3.9.0", days: 7, uuid: "UUID-2")
        longer.profileExpires = daysFromNow(7)
        #expect(try row(longer).newerSigned)
        let plain = updBuild([:], ledger: updLedger(signed: signed("3.9.0", days: 7, uuid: "UUID-2")))
        let shown = try #require(prompt(.install(device: "iphone", app: "apollo"), plain))
        #expect(!shown.lines.contains { $0.hasPrefix("Version ") })
    }

    @Test("a hand-installed row never offers it")
    func handInstalled() throws {
        var byHand = Ledger()
        byHand.freeSigned = [signed("3.10.0")]
        let row = try #require(updBuild([:], ledger: byHand).devices[0].apps.first)
        #expect(!row.newerSigned && row.installedVersion == nil)
    }
}

@Suite("menu update: what the panel reads of updates.json")
struct MenuUpdatesReadTests {
    private func entry(_ version: String, at date: Date = testNow.addingTimeInterval(-3_600)) -> UpdateCacheEntry {
        UpdateCacheEntry(checkedAt: date, version: version, minOS: "15.0", size: 1000, sha256: addSha)
    }

    private func services(_ paths: Paths, http: any HTTPTransport = DisabledTransport()) -> Services {
        fetchServices(paths, http: http)
    }

    private func ready(_ services: Services) throws -> MenuInputs {
        guard case .ready(let inputs) = MenuLoader.loadLocal(services) else { throw SideloadError("TEST", "expected a ready load") }
        return inputs
    }

    @Test("loadLocal puts the cache in the inputs, from the local file only")
    func loadLocal() async throws {
        try await withTestHome(config: addConfig()) { paths, _ in
            var cache = UpdateCache()
            cache.apps["apollo"] = entry("3.10.0")
            cache.apps["stremio-ios"] = entry("1.9.6b142").failed(code: "FETCH_NETWORK", retryAfter: nil, at: testNow.addingTimeInterval(-60))
            try UpdateCacheStore(paths: paths).save(cache)
            let inputs = try ready(services(paths))
            #expect(inputs.upstream["apollo"] == MenuUpstream(version: "3.10.0", minOS: "15.0", checkedAt: testNow.addingTimeInterval(-3_600)))
            #expect(inputs.upstream["stremio-ios"]?.errorCode == "FETCH_NETWORK" && inputs.upstream["stremio-ios"]?.version == "1.9.6b142")
            // Reading wrote nothing.
            #expect(try UpdateCacheStore(paths: paths).load(now: testNow).cache == cache)
        }
    }

    @Test("a missing, corrupt or error-only file is no listing, and the load still succeeds")
    func unreadable() async throws {
        try await withTestHome(config: addConfig()) { paths, _ in
            #expect(try ready(services(paths)).upstream.isEmpty)
            try Data("not json".utf8).write(to: URL(fileURLWithPath: paths.updates))
            #expect(try ready(services(paths)).upstream.isEmpty)
            var cache = UpdateCache()
            cache.apps["apollo"] = UpdateCacheEntry().failed(code: "FETCH_NETWORK", retryAfter: nil, at: testNow.addingTimeInterval(-60))
            try UpdateCacheStore(paths: paths).save(cache)
            #expect(try ready(services(paths)).upstream.isEmpty)
        }
    }

    @Test("a listing read at the same time or later wins; an older one never hides a newer file")
    func merging() {
        let stored = ["apollo": listing("3.10.0", ago: 3_600)]
        #expect(MenuUpdates.merged(stored, with: ["apollo": listing("3.11.0", ago: 60)])["apollo"]?.version == "3.11.0")
        #expect(MenuUpdates.merged(stored, with: ["apollo": listing("3.9.0", ago: 7_200)])["apollo"]?.version == "3.10.0")
        #expect(MenuUpdates.merged(stored, with: ["apollo": listing("3.10.0", error: "FETCH_NETWORK", ago: 3_600)])["apollo"]?.errorCode == "FETCH_NETWORK")
        #expect(MenuUpdates.merged([:], with: ["apollo": listing("3.10.0")]).keys.sorted() == ["apollo"])
        // The panel lays it over the file.
        let inputs = MenuInputs(
            now: testNow, canaryStatus: nil, config: addConfig(), ledger: updLedger(), probe: .checking, upstream: stored)
        let panel = MenuLoader.panel(
            .ready(inputs), probe: .listed([menuListed()]), apps: addRead("iphone", [menuBundleId("apollo")]),
            checked: ["apollo": listing("3.11.0", ago: 60)])
        guard case .loaded(let snapshot) = panel else {
            Issue.record("expected a loaded panel")
            return
        }
        #expect(snapshot.devices[0].apps.first?.update?.version == "3.11.0")
    }

    private func apolloRelease(_ version: String) -> Data {
        releaseJSON(
            tag: "v1.15.11_\(version)", assets: apolloDecoys(version: version) + [ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa")])
    }

    private func home(_ http: FakeFetchTransport, _ body: (Services, Paths) async throws -> Void) async throws {
        try await withTestHome(config: addConfig()) { paths, _ in
            var record = installRecord(.apollo)
            record.version = "3.9.0"
            try await LedgerStore(paths: paths).update { $0.installs = [record] }
            try await body(services(paths, http: http), paths)
        }
    }

    @Test("check lists the source by its own status: a good read, a failed one with the last good values, then the replay")
    func check() async throws {
        let http = FakeFetchTransport(metadata: [apolloAPI: apolloRelease("3.10.0")])
        try await home(http) { services, paths in
            let first = await MenuUpdates.check(services, force: false)
            #expect(first["apollo"]?.version == "3.10.0" && first["apollo"]?.errorCode == nil && first["apollo"]?.checkedAt == testNow)
            #expect(http.getRequests.count == 1 && http.downloadRequests.isEmpty)
            // Within 6 hours: no request, the same listing, from the file.
            let again = await MenuUpdates.check(services, force: false)
            #expect(again == first && http.getRequests.count == 1)
            #expect(MenuUpdates.cached(services) == first)

            // A source that stops answering: the entry keeps its last good values, and the check reports its own error.
            let down = FakeFetchTransport(metadata: [:])
            var later = services
            later.http = down
            later.clock = FixedClock(testNow.addingTimeInterval(7 * 3600))
            let failed = await MenuUpdates.check(later, force: false)
            #expect(failed["apollo"]?.version == "3.10.0" && failed["apollo"]?.errorCode == "FETCH_HTTP_ERROR")
            // The replay of that error (within the hour) is the same listing, not a reason to hide it.
            let replay = await MenuUpdates.check(later, force: false)
            #expect(replay == failed && down.getRequests.count == 1)
            _ = paths
        }
    }

    @Test("check with nothing installed, nothing approved or nothing listed asks for nothing")
    func nothingToAsk() async throws {
        let http = FakeFetchTransport(metadata: [apolloAPI: apolloRelease("3.10.0")])
        try await withTestHome(config: addConfig(approved: [])) { paths, _ in
            var record = installRecord(.apollo)
            record.version = "3.9.0"
            try await LedgerStore(paths: paths).update { $0.installs = [record] }
            #expect(await MenuUpdates.check(services(paths, http: http), force: true).isEmpty)
        }
        try await withTestHome(config: addConfig()) { paths, _ in
            #expect(await MenuUpdates.check(services(paths, http: http), force: true).isEmpty)
        }
        #expect(http.getRequests.isEmpty)
    }
}
