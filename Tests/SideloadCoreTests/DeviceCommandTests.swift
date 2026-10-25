import Foundation
import Testing

@testable import SideloadCore

// `device save / list` cases, driven through `DeviceCommand.run`.
// Changed: device names are never echoed (Node printed the real name in `candidate`/`candidates`);
// `ArgParser` (usage errors for flags) is covered in ArgParserTests and CLITests.

private struct Outcome {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var paths: Paths
    var runner: FakeRunner

    var code: String? { envelope.errors.first?.code }
    var config: JSONValue? {
        (try? Data(contentsOf: URL(fileURLWithPath: paths.config))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

private func invoke(
    _ options: DeviceOptions, config: Config? = noDevicesConfig, devices: JSONValue? = deviceListJSON(phoneEntryJSON()),
    _ check: (Outcome) throws -> Void
) async throws {
    try await withTestHome(config: config) { paths, _ in
        let (services, runner) = fakeServices(paths, route: Route(devices: devices))
        let envelope = await DeviceCommand.run(services, options)
        let (text, json) = try envelope.printed()
        try check(Outcome(envelope: envelope, text: text, json: json, paths: paths, runner: runner))
    }
}

private let noDevicesConfig = Config(devices: [:])

private func save(_ extra: (inout DeviceOptions) -> Void = { _ in }) -> DeviceOptions {
    var options = DeviceOptions(sub: "save", alias: "iphone", match: "Test iPhone", platform: "ios")
    extra(&options)
    return options
}

@Suite("device command")
struct DeviceCommandTests {
    @Test("without --yes prints the redacted candidate and CONFIRM_REQUIRED, saving nothing")
    func confirmRequired() async throws {
        try await invoke(save()) { out in
            #expect(!out.envelope.ok)
            #expect(out.envelope.exitCode == 1)
            #expect(out.code == "CONFIRM_REQUIRED")
            #expect(out.json["candidate"]?["udid"] == .string("…" + savedUdid("1").suffix(4)))
            #expect(out.json["candidate"]?["name"] == "<device>")
            #expect(!out.text.contains(savedUdid("1")) && !out.text.contains(savedCoreId("1")))
            #expect(!out.text.contains("Test iPhone"))
            #expect(out.config?["devices"] == [:])
        }
    }

    @Test("with --yes stores both ids (full values in config, redacted in output)")
    func saves() async throws {
        try await invoke(save { $0.yes = true }) { out in
            #expect(out.envelope.ok)
            #expect(out.envelope.exitCode == 0)
            #expect(out.json["command"] == "device save")
            #expect(!out.text.contains(savedUdid("1")) && !out.text.contains(savedCoreId("1")))
            #expect(out.config?["devices"]?["iphone"] == [
                "udid": .string(savedUdid("1")), "coreDeviceId": .string(savedCoreId("1")), "platform": "ios",
                "name": "Test iPhone",
            ])
            #expect(out.json["device"]?["name"] == "<device>")
            #expect(out.json["device"]?["alias"] == "iphone")
            #expect(out.json["device"]?["coreDeviceId"] == .string("…" + savedCoreId("1").suffix(4)))
            #expect(modeOf(out.paths.config) == 0o600)
        }
    }

    @Test("matches by UDID or CoreDevice ID too")
    func matchesByID() async throws {
        for query in [savedUdid("1"), savedCoreId("1"), savedUdid("1").lowercased()] {
            try await invoke(save { $0.alias = "p"; $0.match = query; $0.yes = true }) { out in
                #expect(out.envelope.ok)
            }
        }
    }

    @Test("refuses simulators, wrong platform and zero matches")
    func notFound() async throws {
        try await invoke(save { $0.yes = true }, devices: deviceListJSON(phoneEntryJSON(reality: "simulated"))) { out in
            #expect(out.code == "DEVICE_NOT_FOUND")
        }
        try await invoke(save { $0.alias = "tv"; $0.platform = "tvos"; $0.yes = true }) { out in
            #expect(out.code == "DEVICE_NOT_FOUND")
            #expect(out.envelope.errors[0].fix?.contains("Remotes and Devices") == true)
        }
        try await invoke(save { $0.yes = true }, devices: deviceListJSON()) { out in
            #expect(out.code == "DEVICE_NOT_FOUND")
            #expect(out.envelope.errors[0].fix?.contains("trust this Mac") == true)
            #expect(out.config?["devices"] == [:])
        }
    }

    @Test("requires exactly one match")
    func ambiguous() async throws {
        let dup = deviceListJSON(
            phoneEntryJSON(), deviceEntryJSON(name: "Test iPhone", udid: savedUdid("2"), coreId: savedCoreId("2")))
        try await invoke(save { $0.yes = true }, devices: dup) { out in
            #expect(out.code == "AMBIGUOUS_MATCH")
            #expect(out.envelope.errors[0].message == "2 devices matched.")
            #expect(!out.text.contains(savedUdid("2")) && !out.text.contains(savedUdid("1")))
            #expect(!out.text.contains("Test iPhone"))
            let candidates = out.json["candidates"]?.array
            #expect(candidates?.count == 2)
            #expect(candidates?[1]["udid"] == .string("…" + savedUdid("2").suffix(4)))
            #expect(out.config?["devices"] == [:])
        }
    }

    @Test("refuses to overwrite an alias that points at a different device")
    func aliasExists() async throws {
        let config = Config(devices: ["iphone": SavedDevice(udid: savedUdid("5"), coreDeviceId: savedCoreId("5"), platform: "ios")])
        try await invoke(save { $0.yes = true }, config: config) { out in
            #expect(out.code == "ALIAS_EXISTS")
            #expect(out.config?["devices"]?["iphone"]?["udid"] == .string(savedUdid("5")))
        }
    }

    @Test("re-saving the same device keeps its name, hostnames and unknown fields")
    func resave() async throws {
        let prior = SavedDevice(
            udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", name: "Old Name",
            hostnames: ["old.example.invalid"], extra: ["note": "keep"])
        let devices = deviceListJSON(deviceEntryJSON(
            name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), hostnames: ["new.example.invalid"]))
        try await invoke(save { $0.yes = true }, config: Config(devices: ["iphone": prior]), devices: devices) { out in
            #expect(out.envelope.ok)
            let saved = out.config?["devices"]?["iphone"]
            #expect(saved?["name"] == "Old Name")
            #expect(saved?["hostnames"] == ["old.example.invalid"])
            #expect(saved?["note"] == "keep")
        }
    }

    @Test("a first save records the device's hostnames, never in the output")
    func hostnames() async throws {
        let devices = deviceListJSON(deviceEntryJSON(
            name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), hostnames: ["h.example.invalid"]))
        try await invoke(save { $0.yes = true }, devices: devices) { out in
            #expect(out.config?["devices"]?["iphone"]?["hostnames"] == ["h.example.invalid"])
            #expect(!out.text.contains("h.example.invalid"))
        }
    }

    @Test("the save works against an existing config with other devices and keeps them")
    func keepsOthers() async throws {
        let config = Config(devices: ["tv": SavedDevice(udid: savedUdid("4"), platform: "tvos")], minFreeGB: 3)
        try await invoke(save { $0.yes = true }, config: config) { out in
            #expect(out.config?["devices"]?["tv"]?["platform"] == "tvos")
            #expect(out.config?["minFreeGB"] == 3)
        }
    }

    @Test("list shows redacted ids and visibility")
    func list() async throws {
        try await invoke(DeviceOptions(sub: "list"), config: iphoneConfig()) { out in
            #expect(out.envelope.ok)
            #expect(out.json["command"] == "device list")
            let device = out.json["devices"]?.array?.first
            #expect(device?["alias"] == "iphone")
            #expect(device?["platform"] == "ios")
            #expect(device?["visibility"] == "ok")
            #expect(device?["udid"] == .string("…" + savedUdid("1").suffix(4)))
            #expect(out.json["warnings"] == [])
            #expect(!out.text.contains(savedUdid("1")) && !out.text.contains(savedCoreId("1")))
        }
        try await invoke(DeviceOptions(sub: "list"), config: iphoneConfig(), devices: deviceListJSON()) { out in
            #expect(out.json["devices"]?.array?.first?["visibility"] == "absent")
        }
        let tunnelDown = deviceListJSON(phoneEntryJSON(tunnel: "unavailable"))
        try await invoke(DeviceOptions(sub: "list"), config: iphoneConfig(), devices: tunnelDown) { out in
            #expect(out.json["devices"]?.array?.first?["visibility"] == "unavailable")
        }
    }

    @Test("list with nothing saved is empty and never runs devicectl")
    func listEmpty() async throws {
        try await invoke(DeviceOptions(sub: "list")) { out in
            #expect(out.json["devices"] == [])
            #expect(out.json["warnings"] == [])
            #expect(out.runner.calls.isEmpty)
        }
    }

    @Test("list sorts by alias and reports a devicectl failure as a warning with unknown visibility")
    func listWarning() async throws {
        let config = Config(devices: [
            "zz": SavedDevice(udid: savedUdid("2"), platform: "ios"),
            "aa": SavedDevice(udid: savedUdid("1"), platform: "ios"),
        ])
        try await withTestHome(config: config) { paths, _ in
            let (services, _) = fakeServices(paths, route: Route(devices: nil, devicectlCode: 1))
            let (_, json) = try await DeviceCommand.run(services, DeviceOptions(sub: "list")).printed()
            #expect(json["ok"] == true)
            #expect(json["devices"]?.array?.compactMap { $0["alias"]?.string } == ["aa", "zz"])
            #expect(json["devices"]?.array?.allSatisfy { $0["visibility"] == "unknown" } == true)
            #expect(json["warnings"]?.array?.first?["code"] == "DEVICECTL_FAILED")
            #expect(json["warnings"]?.array?.first?["fix"] == "Check that Xcode is installed, then retry.")
        }
    }

    @Test("devicectl failing during save is DEVICECTL_FAILED")
    func saveDevicectlFails() async throws {
        try await invoke(save { $0.yes = true }, devices: nil) { out in
            #expect(out.code == "DEVICECTL_FAILED")
        }
    }

    @Test("usage errors for missing fields, a bad alias, a bad platform and an unknown subcommand")
    func usage() async throws {
        try await invoke(DeviceOptions(sub: "save", alias: "x")) { out in
            #expect(out.code == "USAGE")
            #expect(out.runner.calls.isEmpty)
        }
        try await invoke(DeviceOptions(sub: "save", alias: "x", match: "y", platform: "macos")) { out in
            #expect(out.code == "USAGE")
            #expect(out.envelope.errors[0].message == "Unknown platform \"macos\".")
        }
        try await invoke(DeviceOptions(sub: "save", alias: "x", match: "", platform: "ios")) { out in
            #expect(out.code == "USAGE")
        }
        try await invoke(DeviceOptions(sub: "wat")) { out in
            #expect(out.code == "USAGE")
            #expect(out.envelope.command == "device")
        }
        try await invoke(DeviceOptions(sub: nil)) { out in
            #expect(out.envelope.errors[0].message == "Unknown device subcommand \"\".")
        }
    }

    @Test("alias syntax", arguments: [
        ("iphone", true), ("a", true), ("a-b_c", true), ("A1", true), (String(repeating: "a", count: 32), true),
        (String(repeating: "a", count: 33), false), ("", false), ("-a", false), ("_a", false), ("a b", false),
        ("a.b", false), ("ä", false), ("a\n", false),
    ])
    func alias(alias: String, valid: Bool) {
        #expect(DeviceCommand.isValidAlias(alias) == valid)
    }

    @Test("an invalid alias is USAGE and saves nothing")
    func badAlias() async throws {
        try await invoke(save { $0.alias = "bad alias"; $0.yes = true }) { out in
            #expect(out.code == "USAGE")
            #expect(out.envelope.errors[0].message.hasPrefix("Alias must be 1-32 chars"))
            #expect(out.runner.calls.isEmpty)
        }
    }
}
