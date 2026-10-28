import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `status` free installs (docs/design.md section 18, "Ledger and expiry"): `items` of kind `install`, the `installs` list
// and the expiry warnings, read from the ledger and the config only.

private func install(
    _ app: ProvisionApp, alias: String = "iphone", days: Double, present: Bool = true,
    refresh: LedgerInstallRefresh = LedgerInstallRefresh()
) -> LedgerInstall {
    var record = installRecord(app, alias: alias, present: present, refresh: refresh)
    record.profileExpires = daysFromNow(days)
    return record
}

private func status(
    config: Config? = provisionConfig(), ledger: Ledger? = nil, rawLedger: String? = nil, rawConfig: String? = nil
) async throws -> (json: JSONValue, text: String, runner: FakeRunner) {
    try await withTestHome(config: config) { paths, _ in
        if let ledger { try await LedgerStore(paths: paths).update { $0 = ledger } }
        if let rawLedger { try Data(rawLedger.utf8).write(to: URL(fileURLWithPath: paths.ledger)) }
        if let rawConfig { try Data(rawConfig.utf8).write(to: URL(fileURLWithPath: paths.config)) }
        let (services, runner) = fakeServices(paths)
        let (text, json) = try await run(argv: ["status"], services: services).printed()
        return (json, text, runner)
    }
}

private func codes(_ json: JSONValue) -> [String] { json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? [] }

@Suite("status free installs")
struct StatusInstallsTests {
    @Test("a healthy install is an ok item and an installs row, with no warning and no subprocess")
    func healthy() async throws {
        let (json, _, runner) = try await status(ledger: Ledger(installs: [install(.stremioIOS, days: 5)]))
        let item = try #require(json["items"]?.array?.first)
        #expect(item["kind"] == "install" && item["name"] == "stremio-ios @ iphone" && item["level"] == "ok")
        #expect(item["daysLeft"] == 5)
        let row = try #require(json["installs"]?.array?.first)
        #expect(row["id"] == "iphone/stremio-ios" && row["device"] == "iphone" && row["app"] == "stremio-ios")
        #expect(row["level"] == "ok" && row["daysLeft"] == 5 && row["notAfter"] == "2026-10-24T12:00:00Z")
        #expect(row["autoRefresh"] == false && row["lastResult"] == .null && row["nextEligible"] == .null)
        #expect(row["suspended"] == false)
        #expect(codes(json) == [] && json["state"] == "ok")
        #expect(runner.calls.isEmpty)
    }

    @Test("the free thresholds: due at 3 days or fewer, critical at 1 or fewer, then expired", arguments: [
        (3.5, "ok", "ok", nil), (3.0, "warn", "warn", "INSTALL_EXPIRING"), (2.5, "warn", "warn", "INSTALL_EXPIRING"),
        (1.0, "critical", "critical", "INSTALL_EXPIRING"), (0.25, "critical", "critical", "INSTALL_EXPIRING"),
        (-0.5, "expired", "critical", "INSTALL_EXPIRED"),
    ] as [(Double, String, String, String?)])
    func levels(days: Double, level: String, state: String, code: String?) async throws {
        let (json, _, _) = try await status(ledger: Ledger(installs: [install(.stremioIOS, days: days)]))
        #expect(json["items"]?.array?.first?["level"]?.string == level)
        #expect(json["installs"]?.array?.first?["level"]?.string == level)
        #expect(json["state"]?.string == state)
        #expect(codes(json) == (code.map { [$0] } ?? []))
        if let warning = json["warnings"]?.array?.first {
            #expect(warning["fix"] == "The owner runs `sideload refresh --device iphone --app stremio-ios --yes`.")
            #expect(warning["message"]?.string?.contains("stremio-ios on device \"iphone\"") == true)
        }
    }

    @Test("the warning says how long is left in plain words")
    func wording() async throws {
        let (two, _, _) = try await status(ledger: Ledger(installs: [install(.apollo, days: 2.5)]))
        #expect(two["warnings"]?.array?.first?["message"]?.string?.contains("ends in 2 days (warn)") == true)
        let (one, _, _) = try await status(ledger: Ledger(installs: [install(.apollo, days: 1)]))
        #expect(one["warnings"]?.array?.first?["message"]?.string?.contains("ends in 1 day (critical)") == true)
        let (hours, _, _) = try await status(ledger: Ledger(installs: [install(.apollo, days: 0.25)]))
        #expect(hours["warnings"]?.array?.first?["message"]?.string?.contains("ends in less than a day (critical)") == true)
    }

    @Test("an install off the device, or on a device no longer saved, is not listed and does not warn")
    func ignored() async throws {
        let ledger = Ledger(installs: [
            install(.stremioIOS, days: 0.5, present: false), install(.apollo, alias: "retired", days: -1),
        ])
        let (json, _, _) = try await status(ledger: ledger)
        #expect(json["items"] == [] && json["installs"] == [] && codes(json) == [])
        #expect(json["state"] == "unknown")
    }

    @Test("paid and free items are one list, soonest first; `ledger` keeps listing the paid items only")
    func merged() async throws {
        let cert = LedgerCertificate(
            fp8: "aaaaaaaa", team: Team.id, notBefore: nil, notAfter: daysFromNow(2), firstSeen: testNow, lastSeen: testNow,
            valid: true, present: true)
        let ledger = Ledger(
            certificates: [cert],
            installs: [install(.stremioTVOS, alias: "appletv", days: 4), install(.apollo, days: 1.5)])
        let (json, _, _) = try await status(ledger: ledger)
        #expect(json["items"]?.array?.compactMap { $0["name"]?.string } == ["apollo @ iphone", "cert aaaaaaaa", "stremio-tvos @ appletv"])
        #expect(json["installs"]?.array?.compactMap { $0["id"]?.string } == ["iphone/apollo", "appletv/stremio-tvos"])
        let viaLedger = try await withTestHome(config: provisionConfig()) { paths, _ in
            try await LedgerStore(paths: paths).update { $0 = ledger }
            return try await run(argv: ["ledger"], services: fakeServices(paths).0).printed().1
        }
        #expect(viaLedger["items"]?.array?.compactMap { $0["name"]?.string } == ["cert aaaaaaaa"])
    }

    @Test("the refresh bookkeeping and the device's auto-refresh opt-in are passed through")
    func refreshFields() async throws {
        var config = provisionConfig()
        config.devices["iphone"]?.autoRefresh = true
        let refresh = LedgerInstallRefresh(
            lastAttempt: daysFromNow(-1), lastResult: "failed", lastCode: "INSTALL_FAILED", consecutiveFailures: 2,
            nextEligible: daysFromNow(0.5), suspended: true)
        let (json, text, _) = try await status(config: config, ledger: Ledger(installs: [install(.apollo, days: 4, refresh: refresh)]))
        let row = try #require(json["installs"]?.array?.first)
        #expect(row["autoRefresh"] == true && row["lastResult"] == "failed" && row["suspended"] == true)
        #expect(row["nextEligible"] == "2026-10-20T00:00:00Z")
        #expect(!text.contains(savedUdid("1")) && !text.contains("0F0F0F0F-1111"), "no device ID and no profile UUID")
    }

    @Test("an unreadable ledger or config leaves installs and pendingRestores null")
    func unknown() async throws {
        let (badLedger, _, _) = try await status(rawLedger: "{ not json")
        #expect(badLedger["installs"] == .null && badLedger["pendingRestores"] == .null)
        let (badConfig, _, _) = try await status(rawLedger: nil, rawConfig: "{ not json")
        #expect(badConfig["installs"] == .null && badConfig["pendingRestores"] == .null)
        // With no config at all there is no saved device, so nothing is listed.
        let (noConfig, _, _) = try await status(config: nil, ledger: Ledger(installs: [install(.apollo, days: 0.5)]))
        #expect(noConfig["installs"] == [] && noConfig["pendingRestores"] == [])
        #expect(noConfig["items"] == [] && !codes(noConfig).contains("INSTALL_EXPIRING"))
        let (fine, _, _) = try await status()
        #expect(fine["installs"] == [] && fine["pendingRestores"] == [])
    }
}
