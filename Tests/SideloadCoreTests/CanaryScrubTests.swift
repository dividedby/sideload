import Foundation
import Testing

@testable import SideloadCore

// Scrubbing of the saved install JSON: device-identifying values and names are replaced.

private let device = "<device>"

private func scrub(_ value: JSONValue, _ literals: [String] = []) -> JSONValue {
    InstallScrubber.scrub(value, literals: literals)
}

@Suite("canary: install JSON scrubbing")
struct CanaryScrubTests {
    @Test("the value of a device-identifying key is replaced whatever its type", arguments: [
        "deviceName", "hostname", "hostName", "dnsName", "potentialHostnames", "serialNumber", "ecid",
    ])
    func sensitiveKeys(key: String) {
        for value: JSONValue in ["x", 12345, ["a", "b"], ["nested": "x"], nil, true] {
            #expect(scrub([key: value]) == [key: .string(device)])
        }
    }

    @Test("other keys are untouched; the key match is exact")
    func keysExact() {
        let tree: JSONValue = ["deviceNames": "x", "Hostname": "y", "ecids": 1, "outcome": "failed"]
        #expect(scrub(tree) == tree)
    }

    @Test("sensitive keys are found at any depth, inside arrays too")
    func nested() {
        let tree: JSONValue = ["a": [["b": ["deviceName": "Owner", "keep": "yes"]]]]
        #expect(scrub(tree) == ["a": [["b": ["deviceName": .string(device), "keep": "yes"]]]])
    }

    @Test("literals of three or more characters are replaced as substrings, in values and keys")
    func longLiterals() {
        let out = scrub(
            ["msg": "on Test iPhone (owner.local)", "Test iPhone": "as a key", "n": 5],
            ["Test iPhone", "owner.local"])
        #expect(out == ["msg": "on <device> (<device>)", "<device>": "as a key", "n": 5])
    }

    @Test("literals shorter than three characters match whole words in values only, never in keys")
    func shortLiterals() {
        let out = scrub(["Ab": "Ab, Table, ab, Ab_1 and (Ab)", "k": "Ab"], ["Ab"])
        #expect(out == ["Ab": "<device>, Table, ab, Ab_1 and (<device>)", "k": .string(device)])
    }

    @Test("regex metacharacters in a short literal are matched literally")
    func metacharacters() {
        #expect(scrub(["m": "a.b a-b"], [".."]) == ["m": "a.b a-b"])
        #expect(scrub(["m": "x (+) y a+b"], ["+"]) == ["m": "x (<device>) y a+b"], "a symbol between non-word characters")
    }

    @Test("a longer name is replaced before a shorter one it contains")
    func longestFirst() {
        let literals = InstallScrubber.literals(
            config: Config(devices: ["a": SavedDevice(name: "Phone"), "b": SavedDevice(name: "Owner Phone")]), listed: nil)
        #expect(literals == ["Owner Phone", "Phone"])
        #expect(scrub(["m": "Owner Phone"], literals) == ["m": .string(device)])
    }

    @Test("literals come from every saved device and the physical devices devicectl lists, de-duplicated")
    func literalSources() {
        let config = Config(devices: [
            "a": SavedDevice(name: "One", hostnames: ["one.local", ""]), "b": SavedDevice(name: "Two"),
        ])
        let listed = [
            ListedDevice(name: "One", platform: "ios", physical: true, hostnames: ["one.coredevice.local"]),
            ListedDevice(name: "Sim", platform: "ios", physical: false, hostnames: ["sim.local"]),
            ListedDevice(name: "", platform: "ios", physical: true),
        ]
        #expect(
            InstallScrubber.literals(config: config, listed: listed)
                == ["one.coredevice.local", "one.local", "One", "Two"])
        #expect(InstallScrubber.literals(config: config, listed: nil) == ["one.local", "One", "Two"])
    }

    @Test("equal-length literals keep insertion order (aliases sorted, name then hostnames, then listed), not alphabetical")
    func insertionOrder() {
        let config = Config(devices: [
            "a": SavedDevice(name: "Zed", hostnames: ["Yak"]), "b": SavedDevice(name: "Abe"),
        ])
        let listed = [ListedDevice(name: "Mia", platform: "ios", physical: true, hostnames: ["Ann"])]
        #expect(InstallScrubber.literals(config: config, listed: listed) == ["Zed", "Yak", "Abe", "Mia", "Ann"])
    }

    @Test("listDevicesForScrubbing parses JSON from a failed listing; listDevices still treats it as a failure")
    func failedListing() async throws {
        let devices = deviceListJSON(phoneEntryJSON())
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths, route: Route(devices: devices, devicectlCode: 1))
            let normal = try await services.deviceCtl.listDevices()
            #expect(normal == nil)
            let scrub = try await services.deviceCtl.listDevicesForScrubbing()
            #expect(scrub?.map(\.name) == ["Test iPhone"])
        }
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths, route: Route(devices: nil, devicectlCode: 1))
            let none = try await services.deviceCtl.listDevicesForScrubbing()
            #expect(none == nil)
        }
    }

    @Test("info.environment and info.arguments are dropped; a missing document becomes a note")
    func dropsEnvironment() {
        let json: JSONValue = ["info": ["outcome": "failed", "environment": ["HOME": "/Users/x"], "arguments": ["--device", "id"]]]
        #expect(InstallScrubber.scrubbed(json, literals: []) == ["info": ["outcome": "failed"]])
        #expect(InstallScrubber.scrubbed(nil, literals: []) == ["note": "devicectl wrote no JSON"])
    }

    @Test("the scrubbed document is redacted too: UDIDs, CoreDevice ids, emails, user paths")
    func redacted() throws {
        let json: JSONValue = [
            "m": .string("\(savedUdid("1")) \(savedCoreId("1")) me@example.invalid /Users/someone/x"),
        ]
        let text = try #require(InstallScrubber.scrubbed(json, literals: [])["m"]?.string)
        #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")))
        #expect(text.contains("<email>") && text.contains("/Users/<user>/x"))
    }
}
