import Foundation
import Testing

@testable import SideloadCore

// The lab's WebDriverAgent left installed (#64): a visible device's card says so when no slot is lent to the lab, and its
// free count includes the app, which the app list alone identifies (the card reads no profiles).

private let apollo = menuBundleId("apollo")
private let wda = "com.facebook.WebDriverAgentRunner.xctrunner"
private let note = "Lab app still installed · uses a free slot"

@Suite("menu: the lab's app left installed")
struct MenuLabAppNoteTests {
    private func card(
        _ ids: [String], ledger: Ledger = menuLedger([("iphone", "apollo", 5)]),
        reserved: Int = 0, probe: DeviceProbe = .listed([menuListed(link: "connected")]),
        read: Bool = true
    ) -> MenuDeviceCard {
        menuBuild(
            config: menuConfig(reserved: ["iphone": reserved]), ledger: ledger, probe: probe,
            apps: read ? ["iphone": .read(menuSnapshot(ids), takenAt: testNow)] : [:]
        ).devices[0]
    }

    private var lentLedger: Ledger {
        var ledger = Ledger(
            installs: [menuInstall("iphone", "stremio-ios", days: 5, present: false)])
        ledger.slots = [
            LedgerSlot(
                device: "iphone", app: "stremio-ios", presence: .absent, lentTo: "lab",
                since: testNow.addingTimeInterval(-3_600))
        ]
        SlotRule.project(&ledger)
        return ledger
    }

    @Test("a WebDriverAgent with no lend active gets the note and uses a free slot")
    func shownWithoutLend() {
        let left = card([apollo, wda])
        #expect(left.labAppNote == note)
        #expect(left.freeSlots == 1, "apollo + the lab's app leave one of three")
        #expect(left.appsNote == nil)
        #expect(card([apollo]).labAppNote == nil)
        #expect(card([apollo]).freeSlots == 2)
    }

    @Test("the reserve is a floor, not added on top of the lab's app")
    func reserveFloor() {
        #expect(card([apollo, wda], reserved: 1).freeSlots == 1)
        #expect(card([apollo, wda], reserved: 2).freeSlots == 0)
    }

    @Test(
        "with a lend active the app is expected: no note, and the lent slot and the app count once")
    func lentHidesNote() {
        let ledger = lentLedger
        let during = card([apollo, wda], ledger: ledger)
        #expect(during.labAppNote == nil)
        #expect(during.freeSlots == 1, "apollo + the lent slot holding the lab's app")
        #expect(card([apollo], ledger: ledger).labAppNote == nil)
    }

    @Test(
        "only a developer-built app with a WebDriverAgent label counts: look-alikes and TestFlight betas do not"
    )
    func labelAndFlag() {
        func card(_ apps: [String: Bool]) -> MenuDeviceCard {
            menuBuild(
                config: menuConfig(reserved: ["iphone": 0]),
                ledger: menuLedger([("iphone", "apollo", 5)]),
                apps: ["iphone": .read(AppSnapshot(apps: apps), takenAt: testNow)]
            ).devices[0]
        }
        let notDeveloper = card([apollo: true, wda: false])
        #expect(notDeveloper.labAppNote == nil && notDeveloper.freeSlots == 2)
        let beta = card([apollo: true, "com.example.testflight.beta1": true])
        #expect(beta.labAppNote == nil && beta.freeSlots == 2)
    }

    @Test("no live read, an unreadable ledger, or an unreachable device shows no note")
    func notWithoutRead() {
        #expect(card([apollo, wda], read: false).labAppNote == nil)
        let unreadable = menuBuild(
            ledger: Ledger(), apps: ["iphone": .read(menuSnapshot([wda]), takenAt: testNow)],
            ledgerReadable: false
        ).devices[0]
        #expect(unreadable.labAppNote == nil)
        let offline = card(
            [apollo, wda],
            probe: .listed([
                menuListed(link: "unavailable", lastSeen: testNow.addingTimeInterval(-3_600))
            ]))
        #expect(offline.labAppNote == nil, "the reach line stays alone")
        #expect(offline.reach?.line == "Can't reach it right now · Seen 1 h ago")
        let failed = menuBuild(
            ledger: menuLedger([("iphone", "apollo", 5)]),
            apps: ["iphone": .failed(code: "DEVICE_LOCKED", takenAt: testNow)]
        ).devices[0]
        #expect(failed.labAppNote == nil)
        #expect(failed.appsNote == "Couldn't check apps (device locked) · showing last known")
    }

    @Test("the note carries no bundle ID")
    func noIds() {
        let text = String(describing: card([apollo, wda]).labAppNote ?? "")
        #expect(!text.contains("facebook") && !text.contains("WebDriverAgent"))
    }
}
