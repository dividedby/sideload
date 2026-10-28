import Foundation
import Testing

@testable import SideloadCore

// Add app (design section 12): what is offered, why a control is off, the two confirms, and how the fetch and the chain read.

let addSha = String(repeating: "ab", count: 32)

let addFetched = MenuFetched(
    version: "3.9.0", build: "142", sha256: addSha, size: 45_200_000, minOS: "16.0", extensionCount: 2, alreadyApproved: false)

func addConfig(
    devices: [String] = ["iphone"], approved: [String] = ["apollo"], reserved: [String: Int] = [:], tweak: ((inout Config) -> Void)? = nil
) -> Config {
    var config = menuConfig(reserved: reserved, devices: devices)
    config.approvedSources = approved.map { .object(["app": .string($0)]) }
    tweak?(&config)
    return config
}

func addRead(_ alias: String = "iphone", _ ids: [String] = []) -> [String: DeviceAppsProbe] {
    [alias: .read(menuSnapshot(ids), takenAt: testNow)]
}

func addBuild(
    config: Config = addConfig(), ledger: Ledger = Ledger(), probe: DeviceProbe = .listed([menuListed()]),
    apps: [String: DeviceAppsProbe]? = nil, ledgerReadable: Bool = true
) -> MenuSnapshot {
    menuBuild(config: config, ledger: ledger, probe: probe, apps: apps ?? addRead(), ledgerReadable: ledgerReadable)
}

private func availability(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuAvailability {
    MenuActions.availability(action, in: snapshot, now: testNow)
}

private let fetchApollo = MenuAction.addFetch(device: "iphone", app: "apollo")
private let approveApollo = MenuAction.addApprove(device: "iphone", app: "apollo", fetched: addFetched)

@Suite("menu add app: what is offered")
struct MenuAddOfferTests {
    @Test("only approved catalog sources are offered, never the filler or an unknown app, for the card's platform")
    func sources() {
        let config = addConfig(
            devices: ["iphone", "appletv"], approved: ["apollo", "stremio-ios", "stremio-tvos", "filler", "nonsense"])
        let snapshot = addBuild(config: config, probe: .listed([menuListed("1"), menuListed("2")]))
        #expect(snapshot.addSources.map(\.app) == ["apollo", "stremio-ios", "stremio-tvos"])
        let phone = snapshot.devices.first { $0.alias == "iphone" }
        let tv = snapshot.devices.first { $0.alias == "appletv" }
        #expect(phone?.addable.map(\.app) == ["apollo", "stremio-ios"])
        // Apple TV gets Add app like any device.
        #expect(tv?.addable.map(\.app) == ["stremio-tvos"])
        #expect(phone?.addable.map(\.source) == ["github.com", "dl.strem.io (third-party index)"])

        // A source the owner did not approve is hidden, not shown disabled.
        let narrow = addBuild(config: addConfig(approved: ["stremio-ios"]))
        #expect(narrow.devices[0].addable.map(\.app) == ["stremio-ios"])
        #expect(addBuild(config: addConfig(approved: [])).devices[0].addable.isEmpty)
        #expect(addBuild(config: addConfig(approved: ["filler"])).addSources.isEmpty)
    }

    @Test("an app with a row on the device is not offered, and a device without a platform offers nothing")
    func rows() {
        let withRow = addBuild(ledger: menuLedger([("iphone", "apollo", 5)]), apps: addRead("iphone", [menuBundleId("apollo")]))
        #expect(withRow.devices[0].addable.isEmpty)
        var config = addConfig()
        config.devices["iphone"]?.platform = nil
        #expect(addBuild(config: config).devices[0].addable.isEmpty)
    }

    @Test("the App ID is new or reused from the ledger's live epochs, and Stremio's two apps share one")
    func appIds() {
        let fresh = addBuild(config: addConfig(approved: ["apollo", "stremio-ios"]))
        #expect(fresh.devices[0].addable.map(\.newAppId) == [true, true])

        var ledger = Ledger()
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))]
        let reused = addBuild(config: addConfig(approved: ["apollo", "stremio-ios"]), ledger: ledger)
        #expect(reused.devices[0].addable.map(\.newAppId) == [false, true])

        // An epoch older than 7 days no longer counts.
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-8 * 86_400))]
        #expect(addBuild(ledger: ledger).devices[0].addable.map(\.newAppId) == [true])

        // The iOS and tvOS apps of Stremio share a bundle ID: one registered for the phone is reused for the Apple TV.
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("stremio-ios"), epochStart: testNow.addingTimeInterval(-3_600))]
        let tv = addBuild(
            config: addConfig(devices: ["appletv"], approved: ["stremio-tvos"]), ledger: ledger,
            probe: .listed([menuListed("1")]), apps: addRead("appletv"))
        #expect(tv.devices[0].addable.map(\.newAppId) == [false])
    }

    @Test("the device's OS is read from the device list while it is visible")
    func osVersion() {
        var listed = menuListed()
        listed.osVersion = "17.2"
        #expect(addBuild(probe: .listed([listed])).devices[0].osVersion == "17.2")
        #expect(addBuild(probe: .listed([])).devices[0].osVersion == nil)
        #expect(addBuild().devices[0].osVersion == nil)
    }
}

@Suite("menu add app: availability, first match wins")
struct MenuAddAvailabilityTests {
    @Test("the rules, in order, with their exact reasons")
    func order() {
        // 1. the device
        #expect(availability(.addFetch(device: "nobody", app: "apollo"), addBuild()) == .disabled("Device not found"))
        // 2. the free-team stops
        var suspended = Ledger()
        suspended.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["aaaaaaaa"], removedFp8: [])
        #expect(availability(fetchApollo, addBuild(ledger: suspended)) == .disabled("Free certificate changed"))
        #expect(availability(fetchApollo, addBuild(ledgerReadable: false)) == .disabled("Can't read the ledger"))
        // 3. an approved source
        #expect(availability(fetchApollo, addBuild(config: addConfig(approved: []))) == .disabled("Not an approved source"))
        #expect(
            availability(.addFetch(device: "iphone", app: "filler"), addBuild(config: addConfig(approved: ["filler"])))
                == .disabled("Not an approved source"))
        // 4. the platform
        let tvos = MenuAction.addFetch(device: "iphone", app: "stremio-tvos")
        #expect(availability(tvos, addBuild(config: addConfig(approved: ["stremio-tvos"]))) == .disabled("Stremio does not run on iphone"))
        var blank = addConfig()
        blank.devices["iphone"]?.platform = nil
        #expect(availability(fetchApollo, addBuild(config: blank)) == .disabled("iphone has no recorded platform"))
        // 5. a row
        let installed = addBuild(ledger: menuLedger([("iphone", "apollo", 5)]), apps: addRead("iphone", [menuBundleId("apollo")]))
        #expect(availability(fetchApollo, installed) == .disabled("Already installed"))
        var signedOnly = Ledger()
        signedOnly.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        #expect(availability(fetchApollo, addBuild(ledger: signedOnly)) == .disabled("Signed · not installed: use Install"))
        var lent = Ledger()
        lent.freeSigned = [menuSigned("iphone", "apollo", days: 5)]
        lent.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        SlotRule.project(&lent)
        #expect(availability(fetchApollo, addBuild(ledger: lent)) == .disabled("Lent to lab"))
        // 6. the device
        #expect(availability(fetchApollo, addBuild(probe: .listed([]))) == .disabled("Connect iphone over Wi-Fi or USB"))
        #expect(availability(fetchApollo, addBuild(apps: [:])) == .disabled("Checking apps…"))
        #expect(
            availability(fetchApollo, addBuild(apps: ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)]))
                == .disabled("Couldn't check apps"))
        // 7. a slot
        let unknownSlots = addBuild(config: addConfig(reserved: ["iphone": 9]))
        #expect(availability(fetchApollo, unknownSlots) == .disabled("Slots unknown"))
        let full = addBuild(config: addConfig(reserved: ["iphone": 3]))
        #expect(availability(fetchApollo, full) == .disabled("No free slot: remove an app first"))
        // 8. the App ID budget
        let badBudget = addBuild(
            config: addConfig { $0.extra["freeTeam"] = .object(["reservedAppIds": 99]) })
        #expect(availability(fetchApollo, badBudget) == .disabled("App ID budget unknown"))
        #expect(availability(fetchApollo, addBuild()) == .enabled)
    }

    @Test("a new App ID needs room in the budget; a reused one does not")
    func budget() {
        func epochs(_ n: Int, including: String? = nil) -> Ledger {
            var ledger = Ledger()
            ledger.freeAppIds = (0..<n).map { LedgerFreeAppId(bundleId: "io.example.other\($0)", epochStart: testNow.addingTimeInterval(-3_600)) }
            if let including { ledger.freeAppIds[0] = LedgerFreeAppId(bundleId: including, epochStart: testNow.addingTimeInterval(-3_600)) }
            return ledger
        }
        // 5 used + 4 reserved + this one = 10: fits. 6 does not.
        #expect(availability(fetchApollo, addBuild(ledger: epochs(5))) == .enabled)
        #expect(
            availability(fetchApollo, addBuild(ledger: epochs(6))) == .disabled("App ID limit: 6 of 10 used in 7 days, 4 reserved"))
        #expect(availability(fetchApollo, addBuild(ledger: epochs(6, including: menuBundleId("apollo")))) == .enabled)
    }

    @Test("the approval confirm re-applies those rules, and refuses an app the device's OS is too old for")
    func approval() {
        #expect(availability(approveApollo, addBuild()) == .enabled)
        #expect(availability(approveApollo, addBuild(config: addConfig(approved: []))) == .disabled("Not an approved source"))
        #expect(availability(approveApollo, addBuild(probe: .listed([]))) == .disabled("Connect iphone over Wi-Fi or USB"))

        func with(os: String?) -> MenuSnapshot {
            var listed = menuListed()
            listed.osVersion = os
            return addBuild(probe: .listed([listed]))
        }
        #expect(availability(approveApollo, with(os: "15.4")) == .disabled("Apollo 3.9.0 needs iOS 16.0 or later; iphone runs 15.4"))
        #expect(availability(approveApollo, with(os: "16.0")) == .enabled)
        #expect(availability(approveApollo, with(os: "17.1")) == .enabled)
        // Unknown OS: the check is skipped, as the plan says (sign still checks).
        #expect(availability(approveApollo, with(os: nil)) == .enabled)
        var noMinimum = addFetched
        noMinimum.minOS = nil
        #expect(availability(.addApprove(device: "iphone", app: "apollo", fetched: noMinimum), with(os: "10.0")) == .enabled)
    }

    @Test("both stages stop for the owner's Cancel")
    func cancellable() {
        #expect(MenuActions.cancellable(fetchApollo) && MenuActions.cancellable(approveApollo))
    }
}

@Suite("menu add app: the two confirms")
struct MenuAddPromptTests {
    private func prompt(_ action: MenuAction, _ snapshot: MenuSnapshot) -> MenuPrompt? {
        MenuActions.prompt(for: action, in: snapshot, now: testNow)
    }

    @Test("confirm 1: fetch only, nothing signed or installed, no lock line")
    func fetchText() throws {
        let shown = try #require(prompt(fetchApollo, addBuild()))
        #expect(shown.title == "Fetch Apollo for iphone")
        #expect(shown.confirmLabel == "Fetch" && !shown.destructive && shown.runningLabel == "Fetching Apollo…")
        #expect(
            shown.lines == [
                "Downloads the latest Apollo release from github.com and checks it",
                "Nothing is signed or installed; iphone and the portal are unchanged",
            ])
        let stremio = try #require(
            prompt(.addFetch(device: "iphone", app: "stremio-ios"), addBuild(config: addConfig(approved: ["stremio-ios"]))))
        #expect(stremio.lines[0] == "Downloads the latest Stremio release from dl.strem.io (third-party index) and checks it")
        #expect(prompt(fetchApollo, addBuild(config: addConfig(approved: []))) == nil)
    }

    @Test("confirm 2, new App ID: the version, the full SHA-256, the approval, the portal, the slots")
    func approveNew() throws {
        let shown = try #require(prompt(approveApollo, addBuild()))
        #expect(shown.title == "Approve and install Apollo 3.9.0 on iphone")
        #expect(shown.confirmLabel == "Approve and install" && !shown.destructive)
        #expect(shown.runningLabel == "Adding Apollo 3.9.0 to iphone…")
        #expect(
            shown.lines == [
                "Apollo 3.9.0 (build 142) · 45.2 MB · iOS 16.0 or later",
                "SHA-256 \(addSha)",
                "Matches the publisher's",
                "2 extensions will be removed",
                "Approves this exact version for signing",
                "Portal: creates one App ID and a 7-day profile (0 of 10 used in 7 days, 4 reserved)",
                "Slots 0/3 → 1/3",
                "Keep the device unlocked and connected",
                "macOS may ask for keychain access",
            ])
        #expect(shown.monospacedLines == [1] && shown.lines[1].hasSuffix(addSha) && addSha.count == 64)
        // Never a lock line, and no device name, UDID or identity name.
        let text = shown.lines.joined(separator: "\n") + shown.title
        #expect(!text.contains("signing lock") && !text.contains(savedUdid("1")) && !text.contains("Robin"))
    }

    @Test("confirm 2, reused App ID, earlier approval, one extension, no build or minimum OS")
    func approveReused() throws {
        var ledger = Ledger()
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))]
        var fetched = addFetched
        fetched.build = nil
        fetched.minOS = nil
        fetched.extensionCount = 1
        fetched.alreadyApproved = true
        let shown = try #require(prompt(.addApprove(device: "iphone", app: "apollo", fetched: fetched), addBuild(ledger: ledger)))
        #expect(shown.lines[0] == "Apollo 3.9.0 · 45.2 MB")
        #expect(shown.lines[3] == "1 extension will be removed")
        #expect(shown.lines[4] == "Approves this exact version for signing (approved earlier)")
        #expect(shown.lines[5] == "Portal: reuses the existing App ID, profile only")
        var bare = addFetched
        bare.extensionCount = 0
        let none = try #require(prompt(.addApprove(device: "iphone", app: "apollo", fetched: bare), addBuild()))
        #expect(!none.lines.contains { $0.contains("extension") })
    }

    @Test("confirm 2 for a third-party index says what the match guards against; tvOS says tvOS")
    func approveThirdParty() throws {
        let tvos = MenuFetched(
            version: "1.9.6", build: nil, sha256: addSha, size: 1_500_000_000, minOS: "17.0", extensionCount: 0, alreadyApproved: false)
        let snapshot = addBuild(
            config: addConfig(devices: ["appletv"], approved: ["stremio-tvos"]), probe: .listed([menuListed("1")]),
            apps: addRead("appletv"))
        let shown = try #require(prompt(.addApprove(device: "appletv", app: "stremio-tvos", fetched: tvos), snapshot))
        #expect(shown.lines[0] == "Stremio 1.9.6 · 1.5 GB · tvOS 17.0 or later")
        #expect(shown.lines[2] == "Matches the index's; a third party, so this guards against corruption, not a bad index")
    }

    @Test("the confirm button runs what was shown: a changed line is shown again, a vanished source is blocked")
    func reconfirm() throws {
        let snapshot = addBuild()
        let shown = try #require(prompt(approveApollo, snapshot))
        #expect(MenuActions.reconfirm(approveApollo, shown: shown, in: snapshot, now: testNow) == .run(shown))
        var ledger = Ledger()
        ledger.freeAppIds = [LedgerFreeAppId(bundleId: menuBundleId("apollo"), epochStart: testNow.addingTimeInterval(-3_600))]
        let changed = addBuild(ledger: ledger)
        guard case .show(let again) = MenuActions.reconfirm(approveApollo, shown: shown, in: changed, now: testNow) else {
            Issue.record("expected a changed confirm")
            return
        }
        #expect(again.lines.contains("Portal: reuses the existing App ID, profile only"))
        let gone = addBuild(config: addConfig(approved: []))
        #expect(MenuActions.reconfirm(approveApollo, shown: shown, in: gone, now: testNow) == .blocked("Not an approved source"))
    }
}
