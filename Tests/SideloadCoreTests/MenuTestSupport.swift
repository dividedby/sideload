import Foundation

@testable import SideloadCore

// Fixtures shared by the menu tests (MenuSnapshotTests, MenuPresenceTests, MenuModelTests). Fake IDs come from
// `savedUdid` / `savedCoreId`.

let menuPrefix = "io.github.dividedby"

/// The bundle ID `install` gives an app (`<prefix>.free.<suffix>`).
func menuBundleId(_ app: String) -> String { menuPrefix + ".free." + (ProvisionApp(rawValue: app)?.suffix ?? app) }

func menuConfig(
    reserved: [String: Int] = [:], auto: Set<String> = [], devices: [String] = ["iphone"], prefix: String? = menuPrefix
) -> Config {
    var saved: [String: SavedDevice] = [:]
    for (i, alias) in devices.enumerated() {
        saved[alias] = SavedDevice(
            udid: savedUdid("\(i + 1)"), coreDeviceId: savedCoreId("\(i + 1)"),
            platform: alias == "appletv" ? "tvos" : "ios", name: "Robin's \(alias)", autoRefresh: auto.contains(alias),
            freeSlotsReserved: reserved[alias] ?? 0)
    }
    return Config(devices: saved, bundleIdPrefix: prefix)
}

func menuListed(
    _ seed: String = "1", link: String = "disconnected", transport: DeviceTransport = .network, paired: Bool = true,
    lastSeen: Date? = nil
) -> ListedDevice {
    ListedDevice(
        name: "Robin's Secret Phone", udid: savedUdid(seed), coreDeviceId: savedCoreId(seed), platform: "ios",
        paired: paired, link: link, transport: transport, lastConnection: lastSeen)
}

/// One `installs[]` record as `install` leaves it, expiring `days` from `testNow`.
func menuInstall(
    _ device: String, _ app: String, days: Double, refresh: LedgerInstallRefresh = LedgerInstallRefresh(),
    present: Bool = true
) -> LedgerInstall {
    LedgerInstall(
        id: "\(device)/\(app)", device: device, deviceTail: "…0001", app: app, bundleId: menuBundleId(app),
        profileUuid: "UUID-1", profileCreated: nil, profileExpires: daysFromNow(days), certFp8: "12345678", version: "1.0",
        sha256Prefix: "0a1b2c3d", signedAt: testNow, installedAt: testNow, strippedExtensions: [],
        droppedEntitlements: [], present: present, refresh: refresh)
}

/// The ledger after `install` put these apps on devices: an `installs[]` record and a present slot each.
func menuLedger(_ installed: [(device: String, app: String, days: Double)] = [], base: Ledger = Ledger()) -> Ledger {
    var ledger = base
    for entry in installed {
        ledger.installs.append(menuInstall(entry.device, entry.app, days: entry.days))
        ledger.slots.append(LedgerSlot(device: entry.device, app: entry.app, presence: .present))
    }
    SlotRule.project(&ledger)
    return ledger
}

/// What `devicectl device info apps` showed: these bundle IDs, all developer-signed.
func menuSnapshot(_ ids: [String]) -> AppSnapshot {
    AppSnapshot(apps: Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }))
}

func menuBuild(
    config: Config = menuConfig(), ledger: Ledger = Ledger(), canary: String? = nil,
    probe: DeviceProbe = .listed([menuListed()]), apps: [String: DeviceAppsProbe] = [:],
    autoRefreshAvailable: Bool = false, ledgerReadable: Bool = true, renewFailed: Bool = false
) -> MenuSnapshot {
    MenuSnapshotBuilder.build(
        MenuInputs(
            now: testNow, canaryStatus: canary, config: config, ledger: ledger, probe: probe,
            ledgerReadable: ledgerReadable, autoRefreshAvailable: autoRefreshAvailable, renewFailed: renewFailed,
            deviceApps: apps))
}

/// A fake `xcrun devicectl`: answers `list devices` with `devices` and `device info apps` with `apps(deviceID)`, writing
/// the JSON to the `--json-output` file like the real one. Everything else is an exit 0 that writes nothing.
func menuDeviceScript(
    devices: JSONValue?, apps: @escaping @Sendable (String) -> RunResultWithJSON
) -> FakeRunner.Script {
    { spec in
        guard spec.executable == "xcrun", spec.args.first == "devicectl" else { return RunResult() }
        func flag(_ name: String) -> String? { spec.args.firstIndex(of: name).map { spec.args[$0 + 1] } }
        let reply: RunResultWithJSON
        if spec.args.contains("list") {
            reply = RunResultWithJSON(result: RunResult(), json: devices)
        } else if spec.args.contains("apps") {
            reply = apps(flag("--device") ?? "")
        } else {
            reply = RunResultWithJSON(result: RunResult(), json: nil)
        }
        if let json = reply.json, let path = flag("--json-output"), let data = try? JSONEncoder().encode(json) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return reply.result
    }
}

struct RunResultWithJSON: Sendable {
    var result: RunResult
    var json: JSONValue?

    static func apps(_ ids: [String]) -> RunResultWithJSON {
        RunResultWithJSON(result: RunResult(), json: appsJSON(Dictionary(uniqueKeysWithValues: ids.map { ($0, true) })))
    }

    static let locked = RunResultWithJSON(result: RunResult(code: 1, stderr: "The device is locked."), json: nil)
    static let timedOut = RunResultWithJSON(result: RunResult(code: nil, timedOut: true), json: nil)
}
