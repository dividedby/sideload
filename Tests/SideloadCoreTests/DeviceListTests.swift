import Foundation
import Testing

@testable import SideloadCore

// Fake IDs come from `savedUdid` / `savedCoreId` (ConfigTestSupport), assembled at runtime.

private func entry(
    name: String, udid: String, coreId: String, platform: String = "iOS", reality: String = "physical",
    pairing: String = "paired", tunnel: String = "connected", hostnames: [String] = []
) -> JSONValue {
    [
        "identifier": .string(coreId),
        "visibilityClass": reality == "simulated" ? "simulators" : "default",
        "properties": [
            "connection": [
                "pairingState": .string(pairing), "tunnelState": .string(tunnel), "transportType": "wired",
                "potentialHostnames": .array(hostnames.map { .string($0) }),
            ],
            "hardware": ["platform": .string(platform), "reality": .string(reality), "udid": .string(udid)],
            "state": ["name": .string(name)],
        ],
    ]
}

private func list(_ entries: JSONValue...) -> JSONValue {
    ["info": ["outcome": "success"], "result": ["devices": .array(entries)]]
}

private func phone(
    name: String = "Test iPhone", reality: String = "physical", pairing: String = "paired",
    tunnel: String = "connected"
) -> JSONValue {
    entry(
        name: name, udid: savedUdid("1"), coreId: savedCoreId("1"), reality: reality, pairing: pairing,
        tunnel: tunnel)
}

@Suite("device list")
struct DeviceListTests {
    @Test("parses modern devicectl device entries and ignores simulators")
    func modern() {
        let devices = DeviceList.parse(
            list(phone(), entry(name: "Sim", udid: savedUdid("3"), coreId: savedCoreId("3"), reality: "simulated")))
        #expect(devices.count == 2)
        #expect(devices.map(\.physical) == [true, false])
        #expect(devices[0].platform == "ios")
        #expect(devices[0].paired)
        #expect(devices[0].name == "Test iPhone")
        #expect(devices[0].udid == savedUdid("1"))
        #expect(devices[0].coreDeviceId == savedCoreId("1"))
        #expect(devices[0].link == "connected")
    }

    @Test("reads hostnames and drops non-string entries")
    func hostnames() {
        let json: JSONValue = list([
            "identifier": .string(savedCoreId("1")),
            "properties": [
                "connection": ["potentialHostnames": ["a.example.invalid", 7, "b.example.invalid", nil]],
                "hardware": ["platform": "iOS", "reality": "physical"],
            ],
        ])
        #expect(DeviceList.parse(json)[0].hostnames == ["a.example.invalid", "b.example.invalid"])
        #expect(DeviceList.parse(list(phone()))[0].hostnames.isEmpty)
        let kept = DeviceList.parse(list(entry(name: "N", udid: savedUdid("1"), coreId: savedCoreId("1"), hostnames: ["h.example.invalid"])))
        #expect(kept[0].hostnames == ["h.example.invalid"])
    }

    @Test("missing or malformed documents parse to an empty list")
    func malformed() {
        #expect(DeviceList.parse(nil).isEmpty)
        #expect(DeviceList.parse(.null).isEmpty)
        #expect(DeviceList.parse([]).isEmpty)
        #expect(DeviceList.parse(["result": [:]]).isEmpty)
        #expect(DeviceList.parse(["result": ["devices": "nope"]]).isEmpty)
        #expect(DeviceList.parse(["result": ["devices": [1, "x", nil]]]).isEmpty)
        #expect(DeviceList.parse(list()).isEmpty)
    }

    @Test("falls back to the deprecated hardware, device and connection property keys")
    func legacyKeys() {
        let json: JSONValue = list([
            "identifier": .string(savedCoreId("1")),
            "hardwareProperties": ["platform": "iOS", "reality": "physical", "udid": .string(savedUdid("1"))],
            "deviceProperties": ["name": "Legacy Phone"],
            "connectionProperties": [
                "pairingState": "paired", "tunnelState": "unavailable", "potentialHostnames": ["h.example.invalid"],
            ],
        ])
        let d = DeviceList.parse(json)[0]
        #expect(d.name == "Legacy Phone")
        #expect(d.udid == savedUdid("1"))
        #expect(d.coreDeviceId == savedCoreId("1"))
        #expect(d.platform == "ios")
        #expect(d.physical)
        #expect(d.paired)
        #expect(d.link == "unavailable")
        #expect(d.hostnames == ["h.example.invalid"])
    }

    @Test("modern keys win over deprecated ones, and null counts as absent")
    func modernWins() {
        let json: JSONValue = list([
            "properties": [
                "hardware": ["platform": "tvOS", "udid": .string(savedUdid("2"))],
                "connection": ["pairingState": "paired", "state": "connected"],
                "state": ["name": "Modern"],
            ],
            "hardwareProperties": ["platform": "iOS", "udid": .string(savedUdid("1"))],
            "deviceProperties": ["name": "Old"],
            "connectionProperties": ["pairingState": "unpaired", "tunnelState": "unavailable"],
        ], [
            "properties": ["hardware": nil, "connection": nil, "state": nil],
            "hardwareProperties": ["platform": "iOS"],
            "deviceProperties": ["name": "FromLegacy"],
            "connectionProperties": ["pairingState": "paired"],
        ])
        let devices = DeviceList.parse(json)
        #expect(devices[0].name == "Modern")
        #expect(devices[0].platform == "tvos")
        #expect(devices[0].udid == savedUdid("2"))
        #expect(devices[0].link == "connected")
        #expect(devices[1].name == "FromLegacy")
        #expect(devices[1].platform == "ios")
        #expect(devices[1].paired)
    }

    @Test("name falls back to deviceProperties.name when state has none")
    func nameFallback() {
        let json: JSONValue = list([
            "properties": ["hardware": ["platform": "iOS"], "state": [:]],
            "deviceProperties": ["name": "Fallback"],
        ])
        #expect(DeviceList.parse(json)[0].name == "Fallback")
        #expect(DeviceList.parse(list(["properties": [:]]))[0].name == "")
    }

    @Test("link reads the modern `state` key, then defaults to unknown")
    func linkKeys() {
        func link(_ conn: JSONValue) -> String {
            DeviceList.parse(list(["properties": ["connection": conn]]))[0].link
        }
        #expect(link(["tunnelState": "connected", "state": "unavailable"]) == "connected")
        #expect(link(["state": "unavailable"]) == "unavailable")
        #expect(link([:]) == "unknown")
    }

    @Test("platform is lowercased with whitespace removed")
    func platformNormalisation() {
        func platform(_ p: JSONValue) -> String {
            DeviceList.parse(list(["properties": ["hardware": ["platform": p]]]))[0].platform
        }
        #expect(platform("iOS") == "ios")
        #expect(platform("tv OS") == "tvos")
        #expect(platform(" Watch OS ") == "watchos")
        #expect(DeviceList.parse(list(["properties": [:]]))[0].platform == "")
    }

    @Test("physical: `reality` decides, else visibilityClass, else true")
    func physicalFlag() {
        func physical(_ entry: JSONValue) -> Bool { DeviceList.parse(list(entry))[0].physical }
        #expect(physical(["properties": ["hardware": ["reality": "physical"]]]))
        #expect(!physical(["properties": ["hardware": ["reality": "simulated"]]]))
        #expect(!physical(["visibilityClass": "simulators", "properties": ["hardware": ["reality": "simulated"]]]))
        // `reality` wins over a contradicting visibilityClass.
        #expect(physical(["visibilityClass": "simulators", "properties": ["hardware": ["reality": "physical"]]]))
        #expect(!physical(["visibilityClass": "simulators", "properties": [:]]))
        #expect(!physical(["properties": ["state": ["visibilityClass": "simulators"]]]))
        #expect(physical(["visibilityClass": "default", "properties": [:]]))
        #expect(physical(["properties": [:]]))
        // An empty `reality` is treated as absent.
        #expect(!physical(["visibilityClass": "simulators", "properties": ["hardware": ["reality": ""]]]))
    }

    @Test("paired only when pairingState is exactly `paired`")
    func pairedFlag() {
        func paired(_ state: JSONValue) -> Bool {
            DeviceList.parse(list(["properties": ["connection": ["pairingState": state]]]))[0].paired
        }
        #expect(paired("paired"))
        #expect(!paired("unpaired"))
        #expect(!paired("Paired"))
        #expect(!paired(nil))
        #expect(!paired(true))
    }

    // MARK: - findCandidates

    @Test("matches an exact name, ignoring case and outer whitespace")
    func candidatesByName() {
        let devices = DeviceList.parse(list(phone(name: "Test iPhone")))
        #expect(DeviceList.findCandidates(devices, query: "Test iPhone", platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: "  test IPHONE ", platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: "Test", platform: "ios").isEmpty)
        #expect(DeviceList.findCandidates(devices, query: "Test iPhone 2", platform: "ios").isEmpty)
    }

    @Test("curly apostrophes in the name or the query match straight ones")
    func curlyApostrophes() {
        let curly = DeviceList.parse(list(phone(name: "Owner\u{2019}s iPhone")))
        #expect(DeviceList.findCandidates(curly, query: "Owner's iPhone", platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(curly, query: "Owner\u{2019}s iPhone", platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(curly, query: "Owner\u{2018}s iPhone", platform: "ios").count == 1)
        let straight = DeviceList.parse(list(phone(name: "Owner's iPhone")))
        #expect(DeviceList.findCandidates(straight, query: "Owner\u{2019}s iPhone", platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(straight, query: "Owners iPhone", platform: "ios").isEmpty)
    }

    @Test("matches a UDID or CoreDevice ID, case-insensitively")
    func candidatesByID() {
        let devices = DeviceList.parse(list(phone()))
        #expect(DeviceList.findCandidates(devices, query: savedUdid("1"), platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: savedUdid("1").lowercased(), platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: savedCoreId("1"), platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: savedCoreId("1").lowercased(), platform: "ios").count == 1)
        #expect(DeviceList.findCandidates(devices, query: savedUdid("2"), platform: "ios").isEmpty)
        #expect(DeviceList.findCandidates(devices, query: String(savedUdid("1").dropLast()), platform: "ios").isEmpty)
    }

    @Test("excludes simulators even when the ID matches")
    func candidatesExcludeSimulators() {
        let devices = DeviceList.parse(list(phone(reality: "simulated")))
        #expect(DeviceList.findCandidates(devices, query: "Test iPhone", platform: "ios").isEmpty)
        #expect(DeviceList.findCandidates(devices, query: savedUdid("1"), platform: "ios").isEmpty)
        #expect(DeviceList.findCandidates(devices, query: savedCoreId("1"), platform: "ios").isEmpty)
    }

    @Test("filters by platform", arguments: [("ios", 1), ("tvos", 1), ("watchos", 0)])
    func candidatesPlatform(platform: String, count: Int) {
        let devices = DeviceList.parse(list(
            entry(name: "Same Name", udid: savedUdid("1"), coreId: savedCoreId("1"), platform: "iOS"),
            entry(name: "Same Name", udid: savedUdid("2"), coreId: savedCoreId("2"), platform: "tvOS")))
        let found = DeviceList.findCandidates(devices, query: "Same Name", platform: platform)
        #expect(found.count == count)
        #expect(found.allSatisfy { $0.platform == platform })
    }

    @Test("an ambiguous name returns every candidate")
    func candidatesAmbiguous() {
        let devices = DeviceList.parse(list(
            entry(name: "Twin", udid: savedUdid("1"), coreId: savedCoreId("1")),
            entry(name: "Twin", udid: savedUdid("2"), coreId: savedCoreId("2"))))
        #expect(DeviceList.findCandidates(devices, query: "Twin", platform: "ios").count == 2)
        #expect(DeviceList.findCandidates(devices, query: savedUdid("2"), platform: "ios").count == 1)
    }

    // MARK: - findSaved

    @Test("finds the saved device by CoreDevice ID or UDID")
    func findSavedByEitherID() {
        let devices = DeviceList.parse(list(phone()))
        let both = SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios")
        #expect(DeviceList.findSaved(devices, matching: both)?.name == "Test iPhone")
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(udid: savedUdid("1").lowercased())) != nil)
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(coreDeviceId: savedCoreId("1"))) != nil)
        // One ID matching is enough; a wrong one for the other field does not veto it.
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(udid: savedUdid("9"), coreDeviceId: savedCoreId("1"))) != nil)
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("9"))) != nil)
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(udid: savedUdid("9"), coreDeviceId: savedCoreId("9"))) == nil)
    }

    @Test("a saved device with no IDs never matches")
    func findSavedNoIDs() {
        let devices = DeviceList.parse(list(phone()))
        #expect(DeviceList.findSaved(devices, matching: SavedDevice()) == nil)
        #expect(DeviceList.findSaved(devices, matching: SavedDevice(udid: "", coreDeviceId: "")) == nil)
        let blank = DeviceList.parse(list(["properties": ["hardware": ["platform": "iOS"]]]))
        #expect(DeviceList.findSaved(blank, matching: SavedDevice()) == nil)
    }

    @Test("findSaved ignores a simulator that shares the saved ID")
    func findSavedIgnoresSimulator() {
        let devices = DeviceList.parse(list(phone(reality: "simulated")))
        let saved = SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"))
        #expect(DeviceList.findSaved(devices, matching: saved) == nil)
        #expect(DeviceList.visibilityOf(DeviceList.findSaved(devices, matching: saved)) == .absent)
    }

    @Test("findSaved takes a resolved device from Config.requireDevice")
    func findSavedResolved() throws {
        let resolved = try iphoneConfig().requireDevice("iphone")
        let devices = DeviceList.parse(list(phone()))
        #expect(DeviceList.findSaved(devices, matching: resolved) != nil)
    }

    // MARK: - visibilityOf

    @Test("absent, unpaired, unavailable and ok")
    func visibility() {
        let saved = SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"))
        func vis(_ json: JSONValue) -> DeviceVisibility {
            DeviceList.visibilityOf(DeviceList.findSaved(DeviceList.parse(json), matching: saved))
        }
        #expect(vis(list()) == .absent)
        #expect(vis(list(phone(pairing: "unpaired"))) == .unpaired)
        #expect(vis(list(phone(pairing: "unpaired", tunnel: "unavailable"))) == .unpaired)
        #expect(vis(list(phone(tunnel: "unavailable"))) == .unavailable)
        #expect(vis(list(phone())) == .ok)
        #expect(vis(list(phone(tunnel: "disconnected"))) == .ok)
        #expect(DeviceList.visibilityOf(nil) == .absent)
        #expect(DeviceVisibility.allCases.map(\.rawValue) == ["absent", "unpaired", "unavailable", "ok"])
    }
}
