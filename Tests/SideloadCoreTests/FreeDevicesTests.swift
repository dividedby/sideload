import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// Free-team build step 3 (design section 18): transport, per-device auto-refresh and slots config, the
// `device auto-refresh` / `device slots` commands, the DeviceCtl allowlist hook and `autoEligible`.
// Fakes only; the transport key is unverified until spike S1, so the raw values live here and nowhere else.

/// A `devicectl list devices` document whose one phone has `transportType` set to `raw` (nil removes the key).
private func phoneList(transport raw: String?, tunnel: String = "connected", pairing: String = "paired") -> JSONValue {
    var entry = deviceEntryJSON(
        name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), pairing: pairing, tunnel: tunnel)
    guard case .object(var top) = entry, case .object(var props)? = top["properties"],
        case .object(var conn)? = props["connection"]
    else { fatalError("fixture shape") }
    conn["transportType"] = raw.map(JSONValue.string)
    props["connection"] = .object(conn)
    top["properties"] = .object(props)
    entry = .object(top)
    return deviceListJSON(entry)
}

private func parsedPhone(transport raw: String?) -> ListedDevice {
    DeviceList.parse(phoneList(transport: raw))[0]
}

private func configWith(_ d: SavedDevice, prefix: String? = nil) -> Config {
    Config(devices: ["iphone": d], bundleIdPrefix: prefix)
}

private func savedPhone(autoRefresh: Bool = false, reserved: Int = 0) -> SavedDevice {
    SavedDevice(
        udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", autoRefresh: autoRefresh,
        freeSlotsReserved: reserved)
}

@Suite("transport")
struct TransportParsingTests {
    @Test("accepted values map to network or wired", arguments: [
        ("localNetwork", DeviceTransport.network), ("network", .network), ("wifi", .network), ("Wi-Fi", .network),
        ("wireless", .network), ("wired", .wired), ("USB", .wired), ("usb", .wired),
    ])
    func accepted(raw: String, expected: DeviceTransport) {
        #expect(parsedPhone(transport: raw).transport == expected)
    }

    @Test("a missing, null, non-string or unrecognised value is unknown", arguments: [nil, "", "bluetooth", "carrierPigeon"])
    func unknown(raw: String?) {
        #expect(parsedPhone(transport: raw).transport == .unknown)
    }

    @Test("the legacy connectionProperties dictionary and the `transport` key are read too")
    func legacyKeys() {
        let legacy: JSONValue = [
            "identifier": .string(savedCoreId("1")),
            "connectionProperties": ["transportType": "localNetwork", "pairingState": "paired"],
        ]
        #expect(DeviceList.parse(deviceListJSON(legacy))[0].transport == .network)
        let alt: JSONValue = [
            "identifier": .string(savedCoreId("1")),
            "properties": ["connection": ["transport": "wired", "pairingState": "paired"]],
        ]
        #expect(DeviceList.parse(deviceListJSON(alt))[0].transport == .wired)
        let number: JSONValue = [
            "identifier": .string(savedCoreId("1")),
            "properties": ["connection": ["transportType": 3]],
        ]
        #expect(DeviceList.parse(deviceListJSON(number))[0].transport == .unknown)
    }
}

@Suite("autoEligible")
struct AutoEligibleTests {
    private static let transports: [DeviceTransport] = [.network, .wired, .unknown]
    /// The reach of an eligible device by its link; a link not here is never eligible.
    private static let reach: [String: DeviceList.AutoReach] = ["connected": .connected, "disconnected": .probe]

    private func listed(
        transport: DeviceTransport, paired: Bool = true, link: String = "connected", physical: Bool = true
    ) -> ListedDevice {
        ListedDevice(
            name: "x", udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", physical: physical,
            paired: paired, link: link, transport: transport)
    }

    @Test("truth table: opt-in, transport, paired and available")
    func truthTable() {
        for optIn in [false, true] {
            for transport in Self.transports {
                for paired in [false, true] {
                    for link in ["connected", "disconnected", "unavailable"] {
                        let saved = savedPhone(autoRefresh: optIn)
                        let entry = listed(transport: transport, paired: paired, link: link)
                        let expected = optIn && transport != .unknown && paired ? Self.reach[link] : nil
                        #expect(DeviceList.autoReach(saved, listed: entry) == expected)
                        #expect(DeviceList.autoEligible(saved, listed: entry) == (expected != nil))
                    }
                }
            }
        }
    }

    @Test("an unavailable or unrecognised link is not available for auto", arguments: ["unavailable", "unknown", "weird", "Connected", ""])
    func notConnected(link: String) {
        for transport in [DeviceTransport.network, .wired] {
            #expect(!DeviceList.autoEligible(savedPhone(autoRefresh: true), listed: listed(transport: transport, link: link)))
        }
    }

    @Test("a paired disconnected device over Wi-Fi or USB is a probe, a connected one is connected")
    func reach() {
        for transport in [DeviceTransport.network, .wired] {
            let saved = savedPhone(autoRefresh: true)
            #expect(DeviceList.autoReach(saved, listed: listed(transport: transport, link: "disconnected")) == .probe)
            #expect(DeviceList.autoReach(saved, listed: listed(transport: transport)) == .connected)
            #expect(DeviceList.autoReach(saved, listed: listed(transport: transport, paired: false, link: "disconnected")) == nil)
        }
    }

    @Test("an absent entry or a simulator is never eligible")
    func absent() {
        #expect(!DeviceList.autoEligible(savedPhone(autoRefresh: true), listed: nil))
        #expect(!DeviceList.autoEligible(savedPhone(autoRefresh: true), listed: listed(transport: .wired, physical: false)))
    }

    @Test("both Wi-Fi and USB are eligible when opted in")
    func bothTransports() {
        #expect(DeviceList.autoEligible(savedPhone(autoRefresh: true), listed: listed(transport: .network)))
        #expect(DeviceList.autoEligible(savedPhone(autoRefresh: true), listed: listed(transport: .wired)))
    }
}

@Suite("saved device config")
struct SavedDeviceConfigTests {
    @Test("defaults when the fields are absent (an older config)")
    func defaults() throws {
        let old = #"{"devices":{"iphone":{"udid":"U","platform":"ios"}}}"#
        let cfg = try Config.parse(Data(old.utf8))
        #expect(cfg.devices["iphone"]?.autoRefresh == false)
        #expect(cfg.devices["iphone"]?.freeSlotsReserved == 0)
        let text = String(decoding: try cfg.encoded(), as: UTF8.self)
        #expect(!text.contains("autoRefresh") && !text.contains("freeSlotsReserved"), "unset fields are not written")
    }

    @Test("round-trips through ConfigStore.update and keeps unmodelled fields")
    func roundTrip() async throws {
        var d = savedPhone(autoRefresh: true, reserved: 2)
        d.extra = ["future": "kept"]
        try await withTestHome(config: configWith(d)) { _, store in
            try await store.update { $0.minFreeGB = 3 }
            let back = try #require(try store.load().devices["iphone"])
            #expect(back.autoRefresh && back.freeSlotsReserved == 2)
            #expect(back.extra["future"] == "kept")
        }
    }

    @Test("a wrong type is CONFIG_INVALID", arguments: [
        #"{"devices":{"a":{"autoRefresh":"yes"}}}"#,
        #"{"devices":{"a":{"freeSlotsReserved":"2"}}}"#,
        #"{"devices":{"a":{"freeSlotsReserved":1.5}}}"#,
    ])
    func invalid(json: String) {
        do {
            _ = try Config.parse(Data(json.utf8))
            Issue.record("expected CONFIG_INVALID")
        } catch {
            #expect(errorCode(of: error) == "CONFIG_INVALID")
        }
    }

    private static let badReserve = [4, -1, 99]

    @Test("an out-of-range reserve still loads (paid paths and the canary's config reads are unaffected)", arguments: [4, -1, 99])
    func outOfRangeLoads(value: Int) async throws {
        let json = #"{"bundleIdPrefix":"io.github.example","devices":{"iphone":{"udid":"U","coreDeviceId":"C","platform":"ios","freeSlotsReserved":\#(value)}}}"#
        let cfg = try Config.parse(Data(json.utf8))
        let d = try #require(cfg.devices["iphone"])
        #expect(d.freeSlotsReserved == nil && d.freeSlotsReservedRaw == value)
        #expect(try cfg.requireDevice("iphone").deviceId == "C")
        #expect(try cfg.savedDevices().count == 1)
        // The raw value survives a save, so nothing is silently "repaired".
        #expect(try Config.parse(cfg.encoded()).devices["iphone"]?.freeSlotsReservedRaw == value)
        // The wrapper the canary uses still resolves and runs against this config.
        try await withTestHome(config: cfg) { _, store in
            let runner = FakeRunner()
            let res = try await DeviceCtl(runner: runner, store: store).run(["device", "info", "apps"], deviceAlias: "iphone")
            #expect(res.code == 0 && runner.calls.count == 1)
        }
    }

    @Test("an invalid reserve fails the free path closed: autoEligible false, requireFreeSlotsReserved CONFIG_INVALID")
    func invalidReserveFailsClosed() {
        for value in Self.badReserve {
            let d = SavedDevice(udid: "U", autoRefresh: true, freeSlotsReserved: value)
            #expect(d.freeSlotsReserved == nil)
            let entry = ListedDevice(
                udid: "U", platform: "ios", paired: true, link: "connected", transport: .wired)
            #expect(!DeviceList.autoEligible(d, listed: entry))
            do {
                _ = try d.requireFreeSlotsReserved(alias: "iphone")
                Issue.record("expected CONFIG_INVALID")
            } catch let e as SideloadError {
                #expect(e.code == "CONFIG_INVALID" && e.message.contains("iphone"))
            } catch { Issue.record("wrong error") }
        }
        let ok = SavedDevice(udid: "U", autoRefresh: true, freeSlotsReserved: 3)
        #expect(ok.freeSlotsReserved == 3)
    }

    @Test("the setter is the only way to change the reserve, and it rejects out-of-range values")
    func setterValidates() throws {
        var d = SavedDevice(udid: "U")
        try d.setFreeSlotsReserved(2)
        #expect(d.freeSlotsReserved == 2)
        for bad in [4, -1] {
            #expect(throws: SideloadError.self) { try d.setFreeSlotsReserved(bad) }
            #expect(d.freeSlotsReserved == 2, "unchanged after a rejected value")
        }
    }
}

private struct Outcome {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var runner: FakeRunner
    var saved: SavedDevice?
    var code: String? { envelope.errors.first?.code }
}

private func invoke(
    _ options: DeviceOptions, config: Config = configWith(savedPhone()), devices: JSONValue = phoneList(transport: "localNetwork"),
    _ check: (Outcome) throws -> Void
) async throws {
    try await withTestHome(config: config) { paths, store in
        let (services, runner) = fakeServices(paths, route: Route(devices: devices))
        let envelope = await DeviceCommand.run(services, options)
        let (text, json) = try envelope.printed()
        try check(
            Outcome(
                envelope: envelope, text: text, json: json, runner: runner, saved: try store.load().devices["iphone"]))
    }
}

@Suite("device auto-refresh and slots")
struct DeviceConfigCommandTests {
    private func autoRefresh(_ extra: (inout DeviceOptions) -> Void = { _ in }) -> DeviceOptions {
        var o = DeviceOptions(sub: "auto-refresh", alias: "iphone", on: true)
        extra(&o)
        return o
    }

    private func slots(_ extra: (inout DeviceOptions) -> Void = { _ in }) -> DeviceOptions {
        var o = DeviceOptions(sub: "slots", alias: "iphone", reserved: "1")
        extra(&o)
        return o
    }

    @Test("auto-refresh without --yes is CONFIRM_REQUIRED and writes nothing")
    func autoRefreshNeedsYes() async throws {
        try await invoke(autoRefresh()) { out in
            #expect(out.code == "CONFIRM_REQUIRED" && !out.envelope.ok)
            #expect(out.saved?.autoRefresh == false)
            #expect(out.runner.calls.isEmpty)
        }
    }

    @Test("auto-refresh --on --yes then --off --yes writes the flag, prints one object, touches no device")
    func autoRefreshToggles() async throws {
        try await withTestHome(config: configWith(savedPhone())) { paths, store in
            let (services, runner) = fakeServices(paths)
            for on in [true, false] {
                let env = await DeviceCommand.run(
                    services, DeviceOptions(sub: "auto-refresh", alias: "iphone", on: on, off: !on, yes: true))
                let (text, json) = try env.printed()
                #expect(env.ok && json["command"] == "device auto-refresh")
                #expect(json["device"]?["autoRefresh"] == .bool(on))
                #expect(json["device"]?["udid"] == .string("…" + savedUdid("1").suffix(4)))
                #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")))
                #expect(try store.load().devices["iphone"]?.autoRefresh == on)
            }
            #expect(runner.calls.isEmpty, "no subprocess at all")
        }
    }

    @Test("auto-refresh: unknown alias is DEVICE_NOT_SAVED (even with --yes), and usage errors are USAGE")
    func autoRefreshErrors() async throws {
        try await invoke(autoRefresh { $0.alias = "nope"; $0.yes = true }) { out in
            #expect(out.code == "DEVICE_NOT_SAVED")
            #expect(out.saved?.autoRefresh == false)
        }
        for tweak in [
            { (o: inout DeviceOptions) in o.on = false },  // neither
            { (o: inout DeviceOptions) in o.off = true },  // both
            { (o: inout DeviceOptions) in o.alias = nil },
        ] {
            try await invoke(autoRefresh { tweak(&$0); $0.yes = true }) { out in
                #expect(out.code == "USAGE")
            }
        }
    }

    @Test("slots without --yes is CONFIRM_REQUIRED; unknown alias is DEVICE_NOT_SAVED")
    func slotsGuards() async throws {
        try await invoke(slots()) { out in
            #expect(out.code == "CONFIRM_REQUIRED")
            #expect(out.saved?.freeSlotsReserved == 0)
        }
        try await invoke(slots { $0.alias = "nope"; $0.yes = true }) { out in
            #expect(out.code == "DEVICE_NOT_SAVED")
        }
    }

    @Test("slots --reserved 0..3 --yes writes the reserve; anything else is USAGE", arguments: ["0", "1", "2", "3"])
    func slotsWrites(value: String) async throws {
        try await invoke(slots { $0.reserved = value; $0.yes = true }) { out in
            #expect(out.envelope.ok && out.json["command"] == "device slots")
            #expect(out.saved?.freeSlotsReserved == Int(value))
            #expect(out.json["device"]?["freeSlotsReserved"] == .number(Double(value)!))
            #expect(out.runner.calls.isEmpty)
        }
    }

    @Test("slots rejects out-of-range and non-numeric reserves, and a missing one", arguments: ["4", "-1", "x", "1.5", ""])
    func slotsRejects(value: String) async throws {
        try await invoke(slots { $0.reserved = value; $0.yes = true }) { out in
            #expect(out.code == "USAGE")
            #expect(out.saved?.freeSlotsReserved == 0)
        }
    }

    @Test("auto-refresh rejects --reserved and slots rejects --on/--off with USAGE, writing nothing")
    func foreignOptions() async throws {
        try await invoke(autoRefresh { $0.reserved = "1"; $0.yes = true }) { out in
            #expect(out.code == "USAGE")
            #expect(out.saved?.autoRefresh == false && out.saved?.freeSlotsReserved == 0)
        }
        for tweak in [
            { (o: inout DeviceOptions) in o.on = true }, { (o: inout DeviceOptions) in o.off = true },
        ] {
            try await invoke(slots { tweak(&$0); $0.yes = true }) { out in
                #expect(out.code == "USAGE")
                #expect(out.saved?.freeSlotsReserved == 0 && out.saved?.autoRefresh == false)
            }
        }
    }

    private func badReserveConfig() -> Config {
        configWith(SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", freeSlotsReserved: 7))
    }

    @Test("device list warns about an invalid reserve, shows null and is never eligible")
    func listWarnsOnInvalidReserve() async throws {
        var config = badReserveConfig()
        config.devices["iphone"]?.autoRefresh = true
        try await invoke(DeviceOptions(sub: "list"), config: config) { out in
            let d = try #require(out.json["devices"]?.array?.first)
            #expect(d["freeSlotsReserved"] == .null && d["autoEligible"] == false)
            let w = try #require(out.json["warnings"]?.array?.first)
            #expect(w["code"] == "CONFIG_INVALID" && w["message"]?.string?.contains("iphone") == true)
            #expect(out.envelope.ok)
        }
    }

    @Test("with an invalid reserve, auto-refresh --on is CONFIG_INVALID naming the alias; --off and slots still work")
    func invalidReserveOperations() async throws {
        try await invoke(autoRefresh { $0.yes = true }, config: badReserveConfig()) { out in
            #expect(out.code == "CONFIG_INVALID" && out.envelope.errors.first?.message.contains("iphone") == true)
            #expect(out.saved?.autoRefresh == false)
        }
        try await invoke(autoRefresh { $0.on = false; $0.off = true; $0.yes = true }, config: badReserveConfig()) { out in
            #expect(out.envelope.ok)
        }
        try await invoke(slots { $0.reserved = "2"; $0.yes = true }, config: badReserveConfig()) { out in
            #expect(out.envelope.ok && out.saved?.freeSlotsReserved == 2)
        }
    }

    @Test("help lists device auto-refresh and device slots")
    func helpUsage() async throws {
        try await withTestHome { paths, _ in
            let (services, _) = fakeServices(paths)
            let (_, json) = try await run(argv: ["help"], services: services).printed()
            let usage = json["usage"]?.array?.compactMap(\.string) ?? []
            #expect(usage.contains { $0.hasPrefix("device auto-refresh") && $0.contains("--on|--off") })
            #expect(usage.contains { $0.hasPrefix("device slots") && $0.contains("--reserved") })
        }
    }

    @Test("device save rejects --on, --off and --reserved instead of ignoring them")
    func saveRejectsForeignOptions() async throws {
        for tweak in [
            { (o: inout DeviceOptions) in o.on = true },
            { (o: inout DeviceOptions) in o.off = true },
            { (o: inout DeviceOptions) in o.reserved = "1" },
        ] {
            var save = DeviceOptions(sub: "save", alias: "other", match: "Test iPhone", platform: "ios", yes: true)
            tweak(&save)
            try await invoke(save) { out in
                #expect(out.code == "USAGE")
                #expect(out.runner.calls.isEmpty)
            }
        }
    }

    @Test("re-saving a device keeps autoRefresh and the reserve")
    func saveKeepsSettings() async throws {
        let config = configWith(savedPhone(autoRefresh: true, reserved: 1))
        let save = DeviceOptions(sub: "save", alias: "iphone", match: "Test iPhone", platform: "ios", yes: true)
        try await invoke(save, config: config) { out in
            #expect(out.envelope.ok)
            #expect(out.saved?.autoRefresh == true && out.saved?.freeSlotsReserved == 1)
        }
    }

    @Test("device list shows transport, the settings and eligibility", arguments: [
        ("localNetwork", "network", true), ("wired", "wired", true), ("bluetooth", "unknown", false),
    ])
    func listShowsTransport(raw: String, shown: String, eligible: Bool) async throws {
        let config = configWith(savedPhone(autoRefresh: true, reserved: 2))
        try await invoke(DeviceOptions(sub: "list"), config: config, devices: phoneList(transport: raw)) { out in
            let d = try #require(out.json["devices"]?.array?.first)
            #expect(d["transport"] == .string(shown))
            #expect(d["autoRefresh"] == true && d["freeSlotsReserved"] == 2)
            #expect(d["autoEligible"] == .bool(eligible))
            #expect(!out.text.contains(raw) || raw == shown, "the raw value is not echoed")
        }
    }

    @Test("device list: transport is unknown when the device is absent or devicectl failed, and never eligible")
    func listUnknown() async throws {
        let config = configWith(savedPhone(autoRefresh: true))
        try await invoke(DeviceOptions(sub: "list"), config: config, devices: deviceListJSON()) { out in
            let d = out.json["devices"]?.array?.first
            #expect(d?["transport"] == "unknown" && d?["autoEligible"] == false)
        }
        try await withTestHome(config: config) { paths, _ in
            let (services, _) = fakeServices(paths, route: Route(devices: nil, devicectlCode: 1))
            let (_, json) = try await DeviceCommand.run(services, DeviceOptions(sub: "list")).printed()
            let d = json["devices"]?.array?.first
            #expect(d?["transport"] == "unknown" && d?["autoEligible"] == false)
        }
    }
}

@Suite("DeviceCtl allowlist hook")
struct DeviceCtlScopeTests {
    private let prefix = "io.github.example"
    private var free: String { prefix + ".free.stremio" }

    private func attempt(
        _ args: [String], positional: [String] = [], scope: DeviceCtl.Scope
    ) async throws -> (code: String?, calls: Int) {
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: prefix)) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            do {
                _ = try await ctl.run(args, deviceAlias: "iphone", positional: positional, scope: scope)
                return (nil, runner.calls.count)
            } catch {
                return (errorCode(of: error), runner.calls.count)
            }
        }
    }

    @Test("free scope: a non-allowlisted bundle ID is BUNDLE_ID_NOT_ALLOWED before the subprocess", arguments: [
        ["device", "uninstall", "app"], ["device", "process", "launch"], ["device", "install", "app"],
    ])
    func freeBlocks(args: [String]) async throws {
        let bad = ["com.apple.mobilesafari", "io.github.example.sideload.canary", "io.github.example.free.", "io.github.example.free.*"]
        for id in bad {
            let r = try await attempt(args, positional: [id], scope: .free(bundleId: id))
            #expect(r.code == "BUNDLE_ID_NOT_ALLOWED" && r.calls == 0)
        }
    }

    @Test("free scope: the argv ID must equal the declared ID")
    func freeMismatch() async throws {
        let r = try await attempt(
            ["device", "uninstall", "app"], positional: ["com.apple.mobilesafari"], scope: .free(bundleId: free))
        #expect(r.code == "BUNDLE_ID_NOT_ALLOWED" && r.calls == 0)
        let none = try await attempt(["device", "uninstall", "app"], scope: .free(bundleId: free))
        #expect(none.code == "BUNDLE_ID_NOT_ALLOWED" && none.calls == 0)
    }

    @Test("free scope: an allowlisted ID runs; a leading flag cannot hide the subcommand")
    func freeAllows() async throws {
        let ok = try await attempt(["device", "uninstall", "app"], positional: [free], scope: .free(bundleId: free))
        #expect(ok.code == nil && ok.calls == 1)
        let install = try await attempt(
            ["device", "install", "app"], positional: ["/x/App.app"], scope: .free(bundleId: free))
        #expect(install.code == nil && install.calls == 1)
        let hidden = try await attempt(
            ["--verbose", "x", "device", "uninstall", "app"], positional: ["com.apple.mobilesafari"],
            scope: .free(bundleId: "com.apple.mobilesafari"))
        #expect(hidden.code == "BUNDLE_ID_NOT_ALLOWED" && hidden.calls == 0)
    }

    @Test("a free ID cannot be passed off as a paid call")
    func paidRefusesFreeIDs() async throws {
        for args in [["device", "uninstall", "app"], ["device", "process", "launch"]] {
            let r = try await attempt(args, positional: [free], scope: .paid)
            #expect(r.code == "BUNDLE_ID_NOT_ALLOWED" && r.calls == 0)
        }
    }

    @Test("paid calls (the canary's bundle ID, installs, info, list) are unaffected")
    func paidUnchanged() async throws {
        let canary = prefix + ".sideload.canary"
        let calls: [([String], [String])] = [
            (["device", "uninstall", "app"], [canary]), (["device", "process", "launch"], [canary]),
            (["device", "install", "app"], ["/x/Canary.app"]), (["device", "info", "apps"], []),
            (["list", "devices"], []),
        ]
        for (args, positional) in calls {
            let r = try await attempt(args, positional: positional, scope: .paid)
            #expect(r.code == nil && r.calls == 1)
        }
    }

    private func attemptLiteral(
        _ args: [String], positional: [String], scope: DeviceCtl.Scope
    ) async throws -> (code: String?, calls: Int) {
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: prefix)) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            do {
                _ = try await ctl.run(args, positional: positional, scope: scope)
                return (nil, runner.calls.count)
            } catch {
                return (errorCode(of: error), runner.calls.count)
            }
        }
    }

    @Test("--device / -d / --device= interleaved in the subcommand cannot skip the check, in either scope", arguments: [
        ["device", "--device", "ID", "uninstall", "app"], ["device", "-d", "ID", "uninstall", "app"],
        ["device", "--device=ID", "uninstall", "app"], ["device", "uninstall", "--device", "ID", "app"],
        ["--device", "ID", "device", "uninstall", "app"], ["device", "process", "-d=ID", "launch"],
    ])
    func interleavedDevice(template: [String]) async throws {
        let id = savedCoreId("1")
        let args = template.map { $0 == "ID" ? id : $0.replacingOccurrences(of: "=ID", with: "=" + id) }
        let wda = "com.facebook.WebDriverAgentRunner.xctrunner"
        // Free scope with a foreign ID, and with a mismatching argv ID.
        let foreign = try await attemptLiteral(args, positional: [wda], scope: .free(bundleId: wda))
        #expect(foreign.code == "BUNDLE_ID_NOT_ALLOWED" && foreign.calls == 0)
        let mismatch = try await attemptLiteral(args, positional: [wda], scope: .free(bundleId: free))
        #expect(mismatch.code == "BUNDLE_ID_NOT_ALLOWED" && mismatch.calls == 0)
        // Paid scope with a free ID.
        let paid = try await attemptLiteral(args, positional: [free], scope: .paid)
        #expect(paid.code == "BUNDLE_ID_NOT_ALLOWED" && paid.calls == 0)
        // The allowed free call still works in the normalized form.
        let ok = try await attemptLiteral(args, positional: [free], scope: .free(bundleId: free))
        #expect(ok.code == nil && ok.calls == 1)
    }

    @Test("the bundle ID can come only from the positional: extra words in args are refused")
    func idOnlyFromPositional() async throws {
        // Paid, the ID in args and no positional.
        let noPositional = try await attempt(["device", "uninstall", "app", free], scope: .paid)
        #expect(noPositional.code == "BUNDLE_ID_NOT_ALLOWED" && noPositional.calls == 0)
        // Free, args carry another ID next to the allowed positional.
        let extra = try await attempt(
            ["device", "uninstall", "app", "com.other"], positional: [free], scope: .free(bundleId: free))
        #expect(extra.code == "BUNDLE_ID_NOT_ALLOWED" && extra.calls == 0)
        // More than one positional, or none.
        let two = try await attempt(["device", "uninstall", "app"], positional: [free, "com.other"], scope: .free(bundleId: free))
        #expect(two.code == "BUNDLE_ID_NOT_ALLOWED" && two.calls == 0)
        let none = try await attempt(["device", "process", "launch"], scope: .paid)
        #expect(none.code == "BUNDLE_ID_NOT_ALLOWED" && none.calls == 0)
        // Unknown shapes with an app verb fail closed, even in the paid scope.
        for args in [["device", "install", "app", "app"], ["device", "uninstall"], ["x", "launch", "device", "process"]] {
            let r = try await attempt(args, positional: [free], scope: .paid)
            #expect(r.code == "BUNDLE_ID_NOT_ALLOWED" && r.calls == 0)
        }
    }

    @Test("a subcommand word in the positionals cannot complete a split subcommand, in either scope")
    func positionalSubcommandWords() async throws {
        for scope in [DeviceCtl.Scope.paid, .free(bundleId: free)] {
            for positional in [
                ["uninstall", "app", free], ["Uninstall", "App", free], ["PROCESS", "LAUNCH", free], ["install"], ["app"],
                [free, "launch"],
            ] {
                let r = try await attempt(["device"], positional: positional, scope: scope)
                #expect(r.code == "BUNDLE_ID_NOT_ALLOWED" && r.calls == 0)
            }
        }
        // A leading "-" is refused as INVALID_ARGUMENT before the hook.
        let dash = try await attempt(["device", "uninstall", "app"], positional: ["-x"], scope: .paid)
        #expect(dash.code == "INVALID_ARGUMENT" && dash.calls == 0)
    }

    @Test("subcommand words are classified case-insensitively", arguments: [
        ["device", "Uninstall", "app"], ["DEVICE", "UNINSTALL", "APP"], ["device", "Process", "Launch"],
        ["device", "INSTALL", "app"],
    ])
    func caseInsensitive(args: [String]) async throws {
        let paid = try await attempt(args, positional: [free], scope: .paid)
        let isInstall = args[1].lowercased() == "install"
        // An install carries a path, so only the other verbs reveal the free ID to the paid scope.
        #expect(isInstall ? paid.code == nil : paid.code == "BUNDLE_ID_NOT_ALLOWED")
        let wrong = try await attempt(args, positional: ["com.other"], scope: .free(bundleId: free))
        #expect(wrong.code == (isInstall ? nil : "BUNDLE_ID_NOT_ALLOWED"))
        let extra = try await attempt(args + ["com.other"], positional: [free], scope: .free(bundleId: free))
        #expect(extra.code == "BUNDLE_ID_NOT_ALLOWED" && extra.calls == 0)
        let ok = try await attempt(args, positional: [free], scope: .free(bundleId: free))
        #expect(ok.code == nil && ok.calls == 1)
    }

    @Test("with no bundleIdPrefix the free scope allows nothing")
    func noPrefix() async throws {
        try await withTestHome(config: iphoneConfig()) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            await #expect(throws: SideloadError.self) {
                _ = try await ctl.run(
                    ["device", "uninstall", "app"], deviceAlias: "iphone", positional: [free],
                    scope: .free(bundleId: free))
            }
            #expect(runner.calls.isEmpty)
        }
    }
}

@Suite("device config commands through the CLI parser")
struct DeviceConfigCLITests {
    private func cli(_ argv: [String]) async throws -> (json: JSONValue, config: Config?) {
        try await withTestHome(config: configWith(savedPhone())) { paths, store in
            let (services, runner) = fakeServices(paths)
            let (_, json) = try await run(argv: argv, services: services).printed()
            #expect(runner.calls.isEmpty)
            return (json, try? store.load())
        }
    }

    @Test("--on/--off/--reserved/--yes parse and reach the commands")
    func parses() async throws {
        let on = try await cli(["device", "auto-refresh", "--alias", "iphone", "--on", "--yes"])
        #expect(on.json["ok"] == true && on.config?.devices["iphone"]?.autoRefresh == true)
        let slots = try await cli(["device", "slots", "--alias", "iphone", "--reserved=2", "--yes"])
        #expect(slots.json["ok"] == true && slots.config?.devices["iphone"]?.freeSlotsReserved == 2)
        let bare = try await cli(["device", "auto-refresh", "--alias", "iphone", "--on"])
        #expect(bare.json["errors"]?.array?.first?["code"] == "CONFIRM_REQUIRED")
        let both = try await cli(["device", "auto-refresh", "--alias", "iphone", "--on", "--off", "--yes"])
        #expect(both.json["errors"]?.array?.first?["code"] == "USAGE")
    }
}
