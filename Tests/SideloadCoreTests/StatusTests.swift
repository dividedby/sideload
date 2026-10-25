import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

private struct World {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var runner: FakeRunner
    var keychain: FakeKeychain
    var source: FakeProfileSource
    var code: String? { envelope.errors.first?.code }
    var warningCodes: [String] { json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? [] }
}

private func cert(_ fp: String, days: Double, present: Bool = true) -> LedgerCertificate {
    LedgerCertificate(
        fp8: fp, team: Team.id, notBefore: nil, notAfter: daysFromNow(days), firstSeen: testNow, lastSeen: testNow,
        valid: true, present: present)
}

private func profile(days: Double) -> LedgerProfile {
    LedgerProfile(
        uuid: UUID().uuidString, team: Team.id, applicationId: nil, wildcard: true, created: nil, expires: daysFromNow(days),
        deviceCount: 1, deviceTails: [], certFp8s: [], source: "xcode-managed", firstSeen: testNow, lastSeen: testNow,
        present: true)
}

private func canaryLine(_ status: String, code: String? = nil) -> String {
    let codeField = code.map { #","code":"\#($0)""# } ?? ""
    return #"{"ts":"2026-10-19T10:00:00Z","status":"\#(status)"\#(codeField)}"# + "\n"
}

/// Runs `argv` through the CLI over fakes and a temp home seeded with the given files.
private func invoke(
    _ argv: [String] = ["status"], config: Config? = nil, ledger: Ledger? = nil, canaryLog: String? = nil,
    rawLedger: String? = nil, rawConfig: String? = nil
) async throws -> World {
    try await withTestHome(config: config) { paths, _ in
        if let ledger { try await LedgerStore(paths: paths).update { $0 = ledger } }
        if let rawLedger { try Data(rawLedger.utf8).write(to: URL(fileURLWithPath: paths.ledger)) }
        if let rawConfig { try Data(rawConfig.utf8).write(to: URL(fileURLWithPath: paths.config)) }
        if let canaryLog { try Data(canaryLog.utf8).write(to: URL(fileURLWithPath: paths.canaryLog)) }
        let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
        let source = FakeProfileSource([])
        var (services, runner) = fakeServices(paths, keychain: keychain)
        services.profiles = source
        let envelope = await run(argv: argv, services: services)
        let (text, json) = try envelope.printed()
        return World(envelope: envelope, text: text, json: json, runner: runner, keychain: keychain, source: source)
    }
}

@Suite("status command")
struct StatusTests {
    @Test("an empty home is unknown, with nothing read from the keychain, profiles or runner")
    func emptyHome() async throws {
        let w = try await invoke()
        #expect(w.envelope.ok && w.json["command"] == "status")
        #expect(w.json["state"] == "unknown")
        #expect(w.json["generated"] == "2026-10-19T12:00:00Z")
        #expect(w.json["items"] == [] && w.json["devices"] == [] && w.json["apps"] == [] && w.json["warnings"] == [])
        #expect(w.json["ledger"] == ["updated": .null, "present": false])
        #expect(w.json["canary"]?["runs"] == 0 && w.json["canary"]?["last"] == .null)
        #expect(w.keychain.readCount == 0 && w.source.readCount == 0 && w.runner.calls.isEmpty)
    }

    @Test("a blocked last canary run is blocked")
    func blocked() async throws {
        let w = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)]),
            canaryLog: canaryLine("working") + canaryLine("blocked", code: "0xe8008018"))
        #expect(w.json["state"] == "blocked")
        let canary = try #require(w.json["canary"])
        #expect(canary["runs"] == 2 && canary["skipped"] == 0)
        #expect(canary["last"]?["status"] == "blocked" && canary["last"]?["code"] == "0xe8008018")
        #expect(canary["lastWorking"]?["status"] == "working")
        #expect(canary["firstBlockedAfterWorking"]?["status"] == "blocked")
    }

    @Test("expiry outranks blocked")
    func expiryOutranksBlocked() async throws {
        let log = canaryLine("blocked", code: "0xe8008018")
        let warn = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)], profiles: [profile(days: 40)]), canaryLog: log)
        #expect(warn.json["state"] == "warn")
        let critical = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 14)], profiles: [profile(days: 40)]), canaryLog: log)
        #expect(critical.json["state"] == "critical")
        let expired = try await invoke(ledger: Ledger(certificates: [cert("aaaaaaaa", days: -1)]), canaryLog: log)
        #expect(expired.json["state"] == "critical")
        #expect(expired.json["items"]?.array?.first?["level"] == "expired")
    }

    @Test("a working canary with healthy items is ok, and items match ledger")
    func working() async throws {
        let ledger = Ledger(updated: daysFromNow(-1), certificates: [cert("aaaaaaaa", days: 300)])
        let w = try await invoke(ledger: ledger, canaryLog: canaryLine("blocked") + canaryLine("working"))
        #expect(w.json["state"] == "ok")
        #expect(w.json["ledger"] == ["updated": "2026-10-18T12:00:00Z", "present": true])
        let viaLedger = try await invoke(["ledger"], ledger: ledger)
        #expect(w.json["items"] == viaLedger.json["items"])
    }

    @Test("a last canary run of error with no ledger items is unknown, never ok")
    func canaryError() async throws {
        let w = try await invoke(canaryLog: canaryLine("working") + canaryLine("error", code: "BUILD_FAILED"))
        #expect(w.envelope.ok && w.json["state"] == "unknown")
        let healthy = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)]), canaryLog: canaryLine("error"))
        #expect(healthy.json["state"] == "unknown")
        let expiring = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 30)]), canaryLog: canaryLine("error"))
        #expect(expiring.json["state"] == "warn")
    }

    @Test("ledger items alone, with no canary run, are ok")
    func itemsWithoutCanary() async throws {
        let w = try await invoke(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)]))
        #expect(w.json["state"] == "ok")
    }

    @Test("devices print only the last four characters; apps are alias keys")
    func devicesAndApps() async throws {
        var config = iphoneConfig()
        config.apps = ["feather": ["version": "1.0"], "stremio": .null]
        let w = try await invoke(config: config)
        let device = try #require(w.json["devices"]?.array?.first)
        #expect(device["alias"] == "iphone" && device["platform"] == "ios" && device["visibility"] == "unknown")
        #expect(device["udid"]?.string == Redactor.tail4(savedUdid("1")))
        #expect(device["coreDeviceId"]?.string == Redactor.tail4(savedCoreId("1")))
        #expect(!w.text.contains(savedUdid("1")) && !w.text.contains(savedCoreId("1")))
        #expect(w.json["apps"] == ["feather", "stremio"])
        #expect(!w.text.contains("1.0"))
        #expect(w.runner.calls.isEmpty)
    }

    @Test("a corrupt ledger is a warning with an empty section, and the file content is not echoed")
    func corruptLedger() async throws {
        let w = try await invoke(rawLedger: "{ not json LEDGER-SECRET-MARKER")
        #expect(w.envelope.ok && w.envelope.exitCode == 0)
        #expect(w.warningCodes == ["LEDGER_INVALID"])
        #expect(w.json["items"] == [] && w.json["ledger"] == ["updated": .null, "present": true])
        #expect(!w.text.contains("LEDGER-SECRET-MARKER"))
    }

    @Test("a corrupt ledger leaves the slots unknown: no free count, no lent list, never a guessed free slot")
    func corruptLedgerSlotsUnknown() async throws {
        let w = try await invoke(config: iphoneConfig(), rawLedger: "{ not json")
        let device = try #require(w.json["slots"]?["devices"]?.array?.first)
        #expect(device["unknown"] == true && device["free"] == .null && device["used"] == .null)
        #expect(device["lent"] == .null && device["pending"] == .null && device["apps"] == .null)
        #expect(w.json["lent"] == .null)
        // A readable ledger says known.
        let fine = try await invoke(config: iphoneConfig())
        #expect(fine.json["slots"]?["devices"]?.array?.first?["unknown"] == false)
        #expect(fine.json["lent"] == [])
    }

    @Test("an out-of-range stored reserve leaves that device's slots unknown, never a free count from a guessed reserve", arguments: [4, 99, -1])
    func invalidReserveSlotsUnknown(raw: Int) async throws {
        var config = iphoneConfig()
        config.devices["iphone"] = SavedDevice(
            udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", freeSlotsReserved: raw)
        let w = try await invoke(config: config)
        let device = try #require(w.json["slots"]?["devices"]?.array?.first)
        #expect(device["unknown"] == true && device["free"] == .null && device["used"] == .null && device["reserved"] == .null)
    }

    @Test("a corrupt config is a warning, and the other sections still load")
    func corruptConfig() async throws {
        let w = try await invoke(
            ledger: Ledger(certificates: [cert("aaaaaaaa", days: 20)]), rawConfig: "{ not json CONFIG-SECRET-MARKER")
        #expect(w.envelope.ok)
        #expect(w.warningCodes == ["CONFIG_INVALID"])
        #expect(w.json["devices"] == [] && w.json["apps"] == [])
        #expect(w.json["state"] == "warn")
        #expect(!w.text.contains("CONFIG-SECRET-MARKER"))
    }

    @Test("a saved device without IDs is a warning, and the apps and other sections still load")
    func badDevice() async throws {
        var config = iphoneConfig()
        config.devices["broken"] = SavedDevice(platform: "tvos")
        config.apps = ["feather": .null]
        let w = try await invoke(config: config, ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)]))
        #expect(w.envelope.ok)
        #expect(w.warningCodes == ["CONFIG_INVALID"])
        #expect(w.json["devices"] == [])
        #expect(w.json["apps"] == ["feather"])
        #expect(w.json["items"]?.array?.count == 1)
    }

    @Test("a last canary status other than working is unknown, not ok", arguments: ["skipped", "future-status"])
    func unrecognisedCanaryStatus(status: String) async throws {
        let w = try await invoke(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 300)]), canaryLog: canaryLine(status))
        #expect(w.json["state"] == "unknown")
    }

    @Test("a damaged canary log line is skipped and counted")
    func skippedCanaryLine() async throws {
        let w = try await invoke(canaryLog: "garbage\n" + canaryLine("working"))
        #expect(w.json["canary"]?["runs"] == 1 && w.json["canary"]?["skipped"] == 1)
        #expect(w.json["state"] == "ok")
    }

    @Test("--notify, --print-agent and --warn-days are USAGE", arguments: ["--notify", "--print-agent", "--warn-days"])
    func deferredFlags(flag: String) async throws {
        let w = try await invoke(["status", flag])
        #expect(!w.envelope.ok && w.code == "USAGE")
        #expect(w.runner.calls.isEmpty)
    }

    @Test("status takes no positional arguments")
    func positionals() async throws {
        #expect(try await invoke(["status", "extra"]).code == "USAGE")
    }

    @Test("StatusState.worst ranks critical, warn, blocked, unknown (no data or canary error), ok")
    func worst() {
        func item(_ level: ExpiryItem.Level) -> ExpiryItem {
            ExpiryItem(kind: .certificate, name: "cert x", notAfter: testNow, daysLeft: 0, level: level)
        }
        #expect(StatusState.worst(canaryStatus: nil, items: []) == .unknown)
        #expect(StatusState.worst(canaryStatus: "working", items: []) == .ok)
        #expect(StatusState.worst(canaryStatus: "error", items: []) == .unknown)
        #expect(StatusState.worst(canaryStatus: "skipped", items: [item(.ok)]) == .unknown)
        #expect(StatusState.worst(canaryStatus: "skipped", items: [item(.critical)]) == .critical)
        #expect(StatusState.worst(canaryStatus: "error", items: [item(.ok)]) == .unknown)
        #expect(StatusState.worst(canaryStatus: "error", items: [item(.warn)]) == .warn)
        #expect(StatusState.worst(canaryStatus: "error", items: [item(.expired)]) == .critical)
        #expect(StatusState.worst(canaryStatus: nil, items: [item(.ok)]) == .ok)
        #expect(StatusState.worst(canaryStatus: "blocked", items: [item(.ok)]) == .blocked)
        #expect(StatusState.worst(canaryStatus: "blocked", items: [item(.warn), item(.ok)]) == .warn)
        #expect(StatusState.worst(canaryStatus: "working", items: [item(.warn), item(.critical)]) == .critical)
        #expect(StatusState.worst(canaryStatus: "blocked", items: [item(.expired)]) == .critical)
    }
}
