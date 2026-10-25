import Foundation
import Testing

@testable import SideloadCore

private let paidExpiry = utcDate(2027, 10, 16).addingTimeInterval(22 * 3600 + 39 * 60 + 42)
private let noDevices = Config(devices: [:])

private func severity(_ results: [CheckResult]) -> [CheckResult.Severity] { results.map(\.severity) }

/// The tvOS entry shape used by the Apple TV tests.
private func tvConfig() -> Config {
    var config = iphoneConfig()
    config.devices["tv"] = SavedDevice(udid: savedUdid("4"), coreDeviceId: savedCoreId("4"), platform: "tvos")
    return config
}

private func tvEntry() -> JSONValue {
    deviceEntryJSON(name: "TV", udid: savedUdid("4"), coreId: savedCoreId("4"), platform: "tvOS")
}

// Doctor checks and command (ported from the former Node suite: 23 cases).
// Changed expectations are marked "Changed:" and follow docs/design.md section 14.

@Suite("doctor: parsers")
struct DoctorParserTests {
    // Node parses `security`/`openssl` text; Swift reads the certificate in-process (design section 6).
    @Test("reads the team OU and expiry of the paid and free certificates")
    func certificates() throws {
        let paid = try keychainCert(TestCerts.paid)
        #expect(paid.info.teamOU == "7AGMPUPP64")
        #expect(paid.info.notAfter == paidExpiry)
        #expect(try keychainCert(TestCerts.free).info.teamOU == "6ZU5Z6ZKK7")
    }

    @Test("parses modern devicectl device entries and ignores simulators")
    func deviceEntries() {
        let list = DeviceList.parse(
            deviceListJSON(
                phoneEntryJSON(),
                deviceEntryJSON(name: "Sim", udid: savedUdid("3"), coreId: savedCoreId("3"), reality: "simulated")))
        #expect(list.count == 2)
        #expect(list.map(\.physical) == [true, false])
        #expect(list[0].platform == "ios")
        #expect(list[0].paired)
    }
}

@Suite("doctor: cert check")
struct DoctorCertTests {
    @Test("passes for the paid team OU and never prints the identity name, hash or email")
    func paid() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let paid = try keychainCert(TestCerts.paid)
            let (services, runner) = fakeServices(paths, keychain: FakeKeychain([paid]))
            let out = try await CertificateCheck().run(services)
            #expect(out.count == 1)
            #expect(out[0].status == "ok")
            #expect(out[0].message.contains("team 7AGMPUPP64"))
            let text = out.map { $0.json }.map { "\($0)" }.joined()
            #expect(!text.contains(paid.reference) && !text.contains("TEST000001") && !text.contains("Apple Development:"))
            // Changed: Node ran `security` and `openssl` (PEM on stdin); Swift reads Security.framework in-process.
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("reports the free team as \"other team, ignored\" and fails when it is the only cert")
    func freeOnly() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths, keychain: FakeKeychain([try keychainCert(TestCerts.free)]))
            let out = try await CertificateCheck().run(services)
            #expect(out[0].id == "cert")
            #expect(out[0].severity == .fail)
            let other = try #require(out.first { $0.id == "cert-other-team" })
            #expect(other.severity == .info)
            #expect(other.message.hasPrefix("other team, ignored"))
        }
    }

    @Test("warns under 60 days and fails when expired")
    func warnAndExpired() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            let (near, _) = fakeServices(paths, keychain: keychain, now: utcDate(2027, 10, 1))
            let value = try await CertificateCheck().run(near)[0].severity
            #expect(value == .warn)
            let (gone, _) = fakeServices(paths, keychain: keychain, now: utcDate(2028, 1, 1))
            let out = try await CertificateCheck().run(gone)
            #expect(out[0].severity == .fail)
            // Changed: Node says "expired"; Swift applies `find-identity -v` semantics (design section 14).
            #expect(out[0].message == "No Apple Development certificate for team 7AGMPUPP64 in the keychain.")
        }
    }

    @Test("fails when there are no identities")
    func none() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths)
            let value = try await CertificateCheck().run(services)[0].severity
            #expect(value == .fail)
        }
    }

    @Test("passes with both teams present and ignores the free one")
    func both() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid), try keychainCert(TestCerts.free)])
            let (services, _) = fakeServices(paths, keychain: keychain)
            let out = try await CertificateCheck().run(services)
            #expect(out.map(\.id) == ["cert", "cert-other-team"])
            #expect(severity(out) == [.ok, .info])
        }
    }

    @Test("an unreadable keychain is a fail row")
    func unreadable() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths, keychain: FakeKeychain(failure: KeychainError("boom")))
            let out = try await CertificateCheck().run(services)
            #expect(out.count == 1 && out[0].severity == .fail)
            #expect(out[0].fix == "Check that the login keychain is unlocked.")
        }
    }
}

@Suite("doctor: device and appletv checks")
struct DoctorDeviceTests {
    private func run<T>(
        config: Config = iphoneConfig(), route: Route, _ body: (Services, FakeRunner) async throws -> T
    ) async throws -> T {
        try await withTestHome(config: config) { paths, _ in
            let (services, runner) = fakeServices(paths, route: route)
            return try await body(services, runner)
        }
    }

    @Test("device passes when the saved iPhone is visible and paired")
    func visible() async throws {
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, _ in
            let out = try await DeviceCheck().run(services)
            #expect(out[0].severity == .ok)
            #expect(out[0].message == "iphone: visible and paired.")
        }
    }

    @Test("device fails when absent, warns when known but unavailable")
    func absentAndAway() async throws {
        try await run(route: Route(devices: deviceListJSON())) { services, _ in
            let out = try await DeviceCheck().run(services)
            #expect(out[0].severity == .fail)
            #expect(out[0].fix == "Connect the device by USB, unlock it, and tap Trust if asked.")
        }
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON(tunnel: "unavailable")))) { services, _ in
            let out = try await DeviceCheck().run(services)
            #expect(out[0].severity == .warn)
            #expect(out[0].message == "iphone: known but unavailable (locked or unplugged).")
        }
        let unpaired = deviceEntryJSON(
            name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), pairing: "unpaired")
        try await run(route: Route(devices: deviceListJSON(unpaired))) { services, _ in
            let value = try await DeviceCheck().run(services)[0].message
            #expect(value == "iphone: known but not paired.")
        }
    }

    @Test("device ignores a simulator that shares the saved ID")
    func simulator() async throws {
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON(reality: "simulated")))) { services, _ in
            let value = try await DeviceCheck().run(services)[0].severity
            #expect(value == .fail)
        }
    }

    @Test("missing saved iPhone fails with the device-save fix")
    func missingSaved() async throws {
        try await run(config: noDevices, route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, runner in
            let out = try await DeviceCheck().run(services)
            #expect(out.count == 1)
            #expect(out[0].severity == .fail)
            #expect(out[0].message == "No saved iPhone.")
            #expect(out[0].fix == "sideload device save --alias iphone --match <device name> --platform ios --yes")
            #expect(runner.calls.isEmpty, "nothing to look up, so devicectl is not run")
        }
    }

    @Test("an alias filter restricts the device check")
    func aliasFilter() async throws {
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, _ in
            let other = try await DeviceCheck(aliases: ["other"]).run(services)[0].message
            #expect(other == "No saved iPhone.")
            let own = try await DeviceCheck(aliases: ["iphone"]).run(services)[0].severity
            #expect(own == .ok)
        }
    }

    @Test("appletv is not-paired/info with the exact message when none is saved")
    func tvNoneSaved() async throws {
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, runner in
            let out = try await AppleTVCheck().run(services)
            #expect(out.count == 1)
            #expect(out[0].status == "not-paired")
            #expect(out[0].severity == .info)
            #expect(out[0].message == "not paired with this Mac (atvloadly serves it)")
            #expect(out[0].message == AppleTVCheck.notPairedMessage)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("appletv stays not-paired when a saved one is not visible")
    func tvNotVisible() async throws {
        try await run(config: tvConfig(), route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, _ in
            let out = try await AppleTVCheck().run(services)
            #expect(out[0].status == "not-paired")
            #expect(out[0].severity == .info)
        }
    }

    @Test("appletv is checked like the iPhone once saved and visible")
    func tvVisible() async throws {
        try await run(config: tvConfig(), route: Route(devices: deviceListJSON(phoneEntryJSON(), tvEntry()))) { services, _ in
            let value = try await AppleTVCheck().run(services)[0].status
            #expect(value == "ok")
        }
        let away = deviceEntryJSON(
            name: "TV", udid: savedUdid("4"), coreId: savedCoreId("4"), platform: "tvOS", tunnel: "unavailable")
        try await run(config: tvConfig(), route: Route(devices: deviceListJSON(away))) { services, _ in
            let out = try await AppleTVCheck().run(services)
            #expect(out[0].severity == .warn)
            #expect(out[0].message == "tv: paired but unavailable (asleep or off-network).")
            #expect(out[0].fix == "Wake the Apple TV and retry.")
        }
    }

    @Test("a failed devicectl listing keeps the Apple TV row informational")
    func tvListFails() async throws {
        try await run(config: tvConfig(), route: Route(devices: nil, devicectlCode: 1)) { services, _ in
            let value = try await AppleTVCheck().run(services)[0].severity
            #expect(value == .info)
        }
    }

    @Test("devicectl list failing makes the device check fail (not warn) with an actionable fix")
    func devicectlFails() async throws {
        try await run(route: Route(devices: nil, devicectlCode: 1)) { services, _ in
            let out = try await DeviceCheck().run(services)
            #expect(out[0].severity == .fail)
            #expect(try #require(out[0].fix).contains("devicectl list devices"))
            #expect(out[0].message == "iphone: `devicectl list devices` failed, so the device state is unknown.")
        }
        // Exit 0 without parseable output counts as a failure too.
        try await run(route: Route(devices: nil, devicectlCode: 0)) { services, _ in
            let value = try await DeviceCheck().run(services)[0].severity
            #expect(value == .fail)
        }
    }

    @Test("devicectl runs through the wrapper with a timeout and --json-output")
    func devicectlArguments() async throws {
        try await run(route: Route(devices: deviceListJSON(phoneEntryJSON()))) { services, runner in
            _ = try await DeviceCheck().run(services)
            let spec = try #require(runner.calls.first)
            #expect(spec.executable == "xcrun")
            #expect(Array(spec.args.prefix(3)) == ["devicectl", "list", "devices"])
            #expect(spec.args.contains("--json-output") && spec.args.contains("--timeout"))
            #expect(spec.timeout > .zero)
        }
    }
}

@Suite("doctor: disk check")
struct DoctorDiskTests {
    private func severity(gb: Double, config: Config = iphoneConfig()) async throws -> CheckResult {
        try await withTestHome(config: config) { paths, _ in
            let (services, _) = fakeServices(paths, fs: .free(gb: gb))
            return try await DiskCheck().run(services)[0]
        }
    }

    @Test("ok / warn / fail thresholds")
    func thresholds() async throws {
        #expect(try await severity(gb: 50).severity == .ok)
        #expect(try await severity(gb: 3).severity == .warn)
        #expect(try await severity(gb: 1).severity == .fail)
        #expect(try await severity(gb: 5).severity == .ok)
        #expect(try await severity(gb: 4.99).severity == .warn)
        #expect(try await severity(gb: 2).severity == .warn)
        #expect(try await severity(gb: 1.99).severity == .fail)
    }

    @Test("messages and fixes match Node, including minFreeGB")
    func messages() async throws {
        let ok = try await severity(gb: 50)
        #expect(ok.message == "50.0 GB free on the sideload volume.")
        #expect(ok.fix == nil)
        let warn = try await severity(gb: 3)
        #expect(warn.fix == "Free up space; builds need headroom (warning below 5 GB).")
        let fail = try await severity(gb: 1)
        #expect(fail.fix == "Free up space; at least 2 GB is required.")
        var strict = iphoneConfig()
        strict.minFreeGB = 8.5
        let strictWarn = try await severity(gb: 8, config: strict)
        #expect(strictWarn.severity == .fail)
        #expect(strictWarn.fix == "Free up space; at least 8.5 GB is required.")
        var zero = iphoneConfig()
        zero.minFreeGB = 0
        #expect(try await severity(gb: 1, config: zero).severity == .fail, "a non-positive minFreeGB falls back to 2")
    }

    @Test("rounds like JavaScript toFixed(1): exact ties go up")
    func rounding() {
        #expect(DiskCheck.oneDecimal(12.25) == "12.3")
        #expect(DiskCheck.oneDecimal(12.75) == "12.8")
        #expect(DiskCheck.oneDecimal(0.15) == "0.1")  // 0.15 is just below the tie in binary
        #expect(DiskCheck.oneDecimal(3.0) == "3.0")
        #expect(DiskCheck.number(2) == "2")
        #expect(DiskCheck.number(2.5) == "2.5")
    }

    @Test("reads statfs of the sideload home")
    func realStatfs() async throws {
        try await withTestHome { paths, _ in
            let free = try SystemFileSystem().freeBytes(at: paths.home)
            #expect(free > 0)
            #expect(throws: SideloadError.self) { try SystemFileSystem().freeBytes(at: paths.home + "/missing") }
        }
    }
}

@Suite("doctor: xcode check")
struct DoctorXcodeTests {
    private func check(_ route: Route) async throws -> (CheckResult, FakeRunner) {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, runner) = fakeServices(paths, route: route)
            return (try await XcodeCheck().run(services)[0], runner)
        }
    }

    @Test("ok for Xcode 27 with its build, using argument arrays and timeouts")
    func ok() async throws {
        let (result, runner) = try await check(Route())
        #expect(result.severity == .ok)
        #expect(result.message == "Xcode 27.0 (27A266a), developer directory and devicectl present.")
        #expect(runner.calls.map(\.executable) == ["xcodebuild", "xcode-select", "xcrun"])
        #expect(runner.calls.map(\.args) == [["-version"], ["-p"], ["--find", "devicectl"]])
        #expect(runner.calls.allSatisfy { $0.timeout > .zero })
    }

    @Test("warns below Xcode 27")
    func old() async throws {
        let (result, _) = try await check(Route(xcodebuild: RunResult(stdout: "Xcode 26.4\nBuild version 26E1\n")))
        #expect(result.severity == .warn)
        #expect(result.message == "Xcode 26.4 (26E1) found; Xcode 27+ is expected.")
        #expect(result.fix == "Update Xcode to 27 or later.")
    }

    @Test("fails without xcodebuild, a developer directory, or devicectl")
    func failures() async throws {
        let install =
            "Install Xcode 27 from the App Store, then select it with xcode-select -s /Applications/Xcode.app (owner action, needs root)."
        let (noXcode, _) = try await check(Route(xcodebuild: RunResult(code: 1)))
        #expect(noXcode.severity == .fail)
        #expect(noXcode.message == "xcodebuild is not available.")
        #expect(noXcode.fix == install)
        let (garbled, _) = try await check(Route(xcodebuild: RunResult(stdout: "nonsense")))
        #expect(garbled.message == "xcodebuild is not available.")
        let (spawn, _) = try await check(Route(xcodebuild: RunResult(code: nil, spawnError: "ENOENT")))
        #expect(spawn.severity == .fail)
        let (noSelect, _) = try await check(Route(xcodeSelect: RunResult(stdout: "\n")))
        #expect(noSelect.message == "No developer directory selected (xcode-select -p failed).")
        let (noCtl, _) = try await check(Route(missingTools: ["devicectl"]))
        #expect(noCtl.message == "devicectl was not found in the selected Xcode.")
    }

    @Test("parses version text")
    func parse() {
        #expect(XcodeCheck.parseVersion("Xcode 27.0\nBuild version 27A266a\n") == .init(version: "27.0", build: "27A266a", major: 27))
        #expect(XcodeCheck.parseVersion("Xcode 27\n") == .init(version: "27", build: nil, major: 27))
        #expect(XcodeCheck.parseVersion("junk\nXcode 26.1.1\n")?.major == 26)
        #expect(XcodeCheck.parseVersion("Xcode beta") == nil)
    }
}

@Suite("doctor: clt check")
struct DoctorCLTTests {
    private func run(_ route: Route) async throws -> (CheckResult, FakeRunner) {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, runner) = fakeServices(paths, route: route)
            return (try await CLTCheck().run(services)[0], runner)
        }
    }

    @Test("ok when tools resolve and the standalone package is installed")
    func ok() async throws {
        let (r, runner) = try await run(Route())
        #expect(r.id == "clt")
        #expect(r.severity == .ok)
        let find = runner.calls.filter { $0.args.first == "--find" }.map { $0.args[1] }
        #expect(find == ["codesign", "clang", "swiftc"])
        #expect(runner.calls.allSatisfy { $0.timeout > .zero })
        #expect(runner.calls.last?.executable == "/usr/sbin/pkgutil")
    }

    @Test("info (not fail) when only the standalone package is absent")
    func packageAbsent() async throws {
        let (r, _) = try await run(Route(pkgInstalled: false))
        #expect(r.severity == .info)
        #expect(r.message.contains("not installed"))
    }

    @Test("fail when a needed tool does not resolve")
    func missing() async throws {
        let (r, runner) = try await run(Route(missingTools: ["clang"]))
        #expect(r.severity == .fail)
        #expect(r.message == "Command-line tools not found via xcrun: clang.")
        #expect(r.fix != nil)
        #expect(!runner.calls.contains { $0.executable == "/usr/sbin/pkgutil" })
    }
}

@Suite("doctor command")
struct DoctorCommandTests {
    @Test("real-shaped run: iPhone check fails, Apple TV info, cert ok; ok:false")
    func realShaped() async throws {
        try await withTestHome(config: noDevices) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            let (services, _) = fakeServices(paths, route: Route(devices: deviceListJSON()), keychain: keychain)
            let out = await Doctor.run(services)
            #expect(!out.ok)
            let checks = try #require(out.data["checks"]?.array)
            let by = Dictionary(uniqueKeysWithValues: checks.map { ($0["id"]!.string!, $0) })
            #expect(by["cert"]?["severity"] == "ok")
            #expect(by["device"]?["severity"] == "fail")
            #expect(by["appletv"]?["severity"] == "info")
            #expect(by["xcode"]?["severity"] == "ok")
            #expect(out.errors.count == 1)
            #expect(out.errors[0].code == "CHECK_DEVICE")
            #expect(out.errors[0].fix == DeviceCheck.fixSave)
        }
    }

    @Test("ok:true when nothing fails (warnings and info allowed)")
    func allGood() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            let (services, _) = fakeServices(paths, route: Route(devices: deviceListJSON(phoneEntryJSON())), keychain: keychain)
            let out = await Doctor.run(services)
            #expect(out.ok)
            #expect(out.errors.isEmpty)
            #expect(out.exitCode == 0)
            let checks = try #require(out.data["checks"]?.array)
            #expect(checks.compactMap { $0["id"]?.string } == ["xcode", "clt", "cert", "device", "appletv", "disk"])
        }
    }

    @Test("a crashing check becomes a fail, not an exception")
    func crash() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            let (services, _) = fakeServices(
                paths, route: Route(devices: deviceListJSON(phoneEntryJSON())), keychain: keychain,
                fs: FakeFileSystem(freeBytes: nil))
            let out = await Doctor.run(services)
            #expect(!out.ok)
            let disk = try #require(out.data["checks"]?.array?.first { $0["id"] == "disk" })
            #expect(disk["severity"] == "fail")
            #expect(disk["message"]?.string?.hasPrefix("Check crashed:") == true)
            #expect(disk["fix"] == "Re-run `sideload doctor`; if it persists this is a bug.")
            #expect(out.errorCodes == ["CHECK_DISK"])
        }
    }

    @Test("a SideloadError from a check reports its code and fix")
    func crashWithCode() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            try Data("{not json".utf8).write(to: URL(fileURLWithPath: paths.config))
            let (services, _) = fakeServices(paths)
            let out = await Doctor.run(services)
            let device = try #require(out.data["checks"]?.array?.first { $0["id"] == "device" })
            #expect(device["message"] == "Check crashed: CONFIG_INVALID")
            #expect(device["fix"] == "Fix or remove $SIDELOAD_HOME/config.json.")
            _ = store
        }
    }

    @Test("check JSON carries id, status, severity, message, and fix/daysLeft only when set")
    func rowShape() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            let (services, _) = fakeServices(paths, route: Route(devices: deviceListJSON(phoneEntryJSON())), keychain: keychain)
            let checks = try #require(await Doctor.run(services).data["checks"]?.array)
            let cert = try #require(checks.first { $0["id"] == "cert" })
            guard case .object(let fields) = cert else { Issue.record("not an object"); return }
            #expect(Set(fields.keys) == ["id", "status", "severity", "message", "daysLeft"])
            #expect(cert["daysLeft"] == 362)
            guard case .object(let xcode) = checks[0] else { Issue.record("not an object"); return }
            #expect(Set(xcode.keys) == ["id", "status", "severity", "message"])
        }
    }

    @Test("printed output hides ids, names and the home directory")
    func printedRedaction() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid), try keychainCert(TestCerts.free)])
            let (services, _) = fakeServices(paths, route: Route(devices: deviceListJSON(phoneEntryJSON())), keychain: keychain)
            let (text, json) = try await Doctor.run(services).printed()
            #expect(json["command"] == "doctor")
            #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")))
            #expect(!text.contains("Test iPhone") && !text.contains("Apple Development:"))
        }
    }
}
