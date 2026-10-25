import Foundation
import Testing

@testable import SideloadCore

private func listing(_ rows: [JSONValue], truncated: Bool = false) -> Result<PortalListing, SideloadError> {
    let items = rows.map { row -> PortalItem in
        var attributes: [String: JSONValue] = [:]
        if case .object(let a)? = row["attributes"] { attributes = a }
        return PortalItem(id: row["id"]?.string ?? "?", attributes: attributes)
    }
    return .success(PortalListing(items: items, truncated: truncated))
}

private func report(
    certificates: [JSONValue]? = nil, bundleIds: [JSONValue]? = nil, devices: [JSONValue]? = nil,
    profiles: [JSONValue]? = nil, failing: [PortalResource: SideloadError] = [:], prefix: String? = "com.example",
    saved: Set<String>? = [], keychain: Set<String>? = [], showIdentifiers: Bool = false,
    requested: [PortalResource] = PortalResource.allCases, now: Date = testNow
) -> (envelope: Envelope, keychainReads: Int) {
    var results: [PortalResource: Result<PortalListing, SideloadError>] = [:]
    for (resource, rows) in [
        (PortalResource.certificates, certificates), (.bundleIds, bundleIds), (.devices, devices), (.profiles, profiles),
    ] {
        if let error = failing[resource] {
            results[resource] = .failure(error)
        } else if requested.contains(resource) {
            results[resource] = listing(rows ?? [])
        }
    }
    let reads = ReadCounter()
    let envelope = PortalReport.build(
        PortalReportInput(
            requested: requested, results: results, role: "Developer", keyIdTail: "2345", bundleIdPrefix: prefix,
            savedUDIDs: saved, keychainReferences: { reads.bump(); return keychain }, now: now,
            showIdentifiers: showIdentifiers))
    return (envelope, reads.count)
}

private final class ReadCounter: @unchecked Sendable {
    var count = 0
    func bump() { count += 1 }
}

private func reference(_ base64: String) throws -> String {
    try keychainCert(base64).reference
}

@Suite("portal report")
struct PortalReportTests {
    @Test("certificate items carry only the allowlisted fields")
    func certificateFields() throws {
        let paidRef = try reference(TestCerts.paid)
        let out = report(
            certificates: [
                certRow("CERT000001", content: TestCerts.paid),
                certRow("CERT000002", content: TestCerts.expired, expires: "2021-01-01T00:00:00.000+0000"),
                certRow("CERT000003", type: "DISTRIBUTION", content: TestCerts.paid),
            ], keychain: [paidRef])
        let items = try #require(out.envelope.section("certificates")?["items"]?.array)
        #expect(items.count == 3)
        // Sorted by expiry, then id.
        #expect(items.compactMap { $0["id"]?.string } == ["CERT000002", "CERT000001", "CERT000003"])
        #expect(Set(try #require(items[0].objectKeys)) == ["id", "type", "platform", "activated", "expires", "issued", "certFp", "inKeychain"])

        let first = items[1]
        #expect(first["type"] == "DEVELOPMENT" && first["platform"] == "IOS" && first["activated"] == true)
        #expect(first["expires"] == "2027-10-16" && first["issued"] == "2026-01-01")
        #expect(first["certFp"] == .string(String(paidRef.prefix(8)).lowercased()))
        #expect(first["inKeychain"] == true)
        #expect(items[0]["inKeychain"] == false)
        #expect(items[2]["inKeychain"] == .null, "not checked for other types")

        let text = try out.envelope.printed().text
        for secret in Canary.all + ["Test 00000", "TEST000001", paidRef] { #expect(!text.contains(secret)) }
        #expect(out.envelope.json["summary"]?["certificatesNotInKeychain"] == 1)
        #expect(out.envelope.json["summary"]?["certificatesByType"] == ["DEVELOPMENT": 2, "DISTRIBUTION": 1])
        let warnings = out.envelope.json["warnings"]?.array?.compactMap { $0["code"]?.string }
        #expect(warnings == ["CERT_NOT_IN_KEYCHAIN"])
        #expect(out.envelope.ok)
    }

    @Test("an unreadable certificate keeps its row with null fingerprint and a warning")
    func unreadableCertificate() throws {
        let out = report(certificates: [certRow("CERT000009", content: "bm90IGEgY2VydA==")])
        let item = try #require(out.envelope.section("certificates")?["items"]?.array?.first)
        #expect(item["certFp"] == .null && item["inKeychain"] == .null && item["issued"] == .null)
        #expect(out.envelope.json["warnings"]?.array?.compactMap { $0["code"]?.string } == ["TEAM_UNVERIFIED", "CERT_UNREADABLE"])
        #expect(out.keychainReads == 0)
        #expect(out.envelope.ok)
    }

    @Test("the keychain is read once, and only for development certificates")
    func keychainReads() throws {
        let none = report(certificates: [certRow("A", type: "DISTRIBUTION")])
        #expect(none.keychainReads == 0)
        let many = report(certificates: [certRow("A"), certRow("B", content: TestCerts.expired)])
        #expect(many.keychainReads == 1)
        let unreadable = report(certificates: [certRow("A")], keychain: nil)
        let item = try #require(unreadable.envelope.section("certificates")?["items"]?.array?.first)
        #expect(item["inKeychain"] == .null)
        #expect(unreadable.envelope.json["warnings"]?.array?.compactMap { $0["code"]?.string } == ["KEYCHAIN_UNREADABLE"])
    }

    @Test("App IDs show only identifiers under the configured prefix")
    func bundleIds() throws {
        let rows = [
            bundleRow("B1", "com.example.app"), bundleRow("B2", "com.example"),
            bundleRow("B3", Canary.foreignIdentifier), bundleRow("B4", "*"), bundleRow("B5", "com.examplex.app"),
        ]
        let out = report(bundleIds: rows)
        let items = try #require(out.envelope.section("bundleIds")?["items"]?.array)
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0["id"]!.string!, $0) })
        #expect(byId["B1"]?["identifier"] == "com.example.app" && byId["B1"]?["underPrefix"] == true)
        #expect(byId["B2"]?["identifier"] == "com.example" && byId["B2"]?["underPrefix"] == true)
        #expect(byId["B3"]?["identifier"] == "<other>" && byId["B3"]?["underPrefix"] == false)
        #expect(byId["B3"]?["components"] == 3)
        #expect(byId["B4"]?["identifier"] == "*")
        #expect(byId["B5"]?["identifier"] == "<other>", "a longer first component is not the prefix")
        #expect(out.envelope.json["summary"]?["otherPrefixBundleIds"] == 3)
        let text = try out.envelope.printed().text
        #expect(!text.contains(Canary.foreignIdentifier))
        #expect(!text.contains(Canary.appName))
    }

    @Test("--show-identifiers prints every identifier, still never the App ID name")
    func showIdentifiers() throws {
        let out = report(bundleIds: [bundleRow("B3", Canary.foreignIdentifier)], showIdentifiers: true)
        let text = try out.envelope.printed().text
        #expect(text.contains(Canary.foreignIdentifier))
        #expect(!text.contains(Canary.appName))
        let item = try #require(out.envelope.section("bundleIds")?["items"]?.array?.first)
        #expect(item["underPrefix"] == false)
    }

    @Test("without a configured prefix identifiers stay hidden and a warning says why")
    func noPrefix() throws {
        let out = report(bundleIds: [bundleRow("B1", "com.example.app")], prefix: nil)
        let item = try #require(out.envelope.section("bundleIds")?["items"]?.array?.first)
        #expect(item["identifier"] == "<other>" && item["underPrefix"] == .null)
        #expect(out.envelope.json["warnings"]?.array?.compactMap { $0["code"]?.string } == ["BUNDLE_ID_PREFIX_UNSET"])
    }

    @Test("devices print only the last four of the UDID and never the name")
    func devices() throws {
        let known = savedUdid("1")
        let unknown = savedUdid("2")
        let out = report(
            devices: [
                deviceRow("D1", udid: known), deviceRow("D2", udid: unknown, cls: "APPLE_TV", added: "2026-01-01T00:00:00.000+0000"),
            ], saved: [known.lowercased()])
        let items = try #require(out.envelope.section("devices")?["items"]?.array)
        #expect(items.count == 2)
        #expect(items[0]["added"] == "2026-01-01" && items[0]["deviceClass"] == "APPLE_TV")
        #expect(items[0]["udid"] == .string(Redactor.tail4(unknown)))
        #expect(items[0]["savedLocally"] == false && items[1]["savedLocally"] == true)
        #expect(items[1]["model"] == "iPhone 17" && items[1]["status"] == "ENABLED")
        let text = try out.envelope.printed().text
        for secret in [known, unknown, Canary.deviceName] { #expect(!text.contains(secret)) }
        #expect(out.envelope.json["summary"]?["devicesByClass"] == ["IPHONE": 1, "APPLE_TV": 1])
    }

    @Test("savedLocally is null when config.json is absent")
    func savedNull() throws {
        let out = report(devices: [deviceRow("D1", udid: savedUdid("1"))], saved: nil)
        #expect(out.envelope.section("devices")?["items"]?.array?.first?["savedLocally"] == .null)
    }

    @Test("profiles report their dates, state and whether they have expired")
    func profiles() throws {
        let out = report(
            profiles: [
                profileRow("P1", expires: "2027-03-04T10:00:00.000+0000"),
                profileRow("P2", state: "EXPIRED", created: "2025-01-01T00:00:00.000+0000", expires: "2026-01-01T00:00:00.000+0000"),
                profileRow("P3", expires: "garbage"),
            ])
        let items = try #require(out.envelope.section("profiles")?["items"]?.array)
        #expect(items.compactMap { $0["id"]?.string } == ["P2", "P1", "P3"])
        #expect(items[0]["expired"] == true && items[0]["state"] == "EXPIRED")
        #expect(items[1]["expired"] == false && items[1]["created"] == "2026-03-04" && items[1]["expires"] == "2027-03-04")
        #expect(items[2]["expired"] == .null && items[2]["expires"] == .null)
        #expect(out.envelope.json["summary"]?["expiredProfiles"] == 1)
        #expect(out.envelope.json["summary"]?["profilesByState"] == ["ACTIVE": 2, "EXPIRED": 1])
        let text = try out.envelope.printed().text
        #expect(!text.contains(Canary.profileName) && !text.contains(Canary.profileContent))
    }

    @Test("timestamps parse in Apple's shape and the usual ISO forms")
    func dates() {
        #expect(PortalReport.date("2027-10-16T22:39:42.000+0000") == Date(timeIntervalSince1970: 1_823_726_382))
        #expect(PortalReport.date("2027-10-16T22:39:42Z") == Date(timeIntervalSince1970: 1_823_726_382))
        #expect(PortalReport.date("2027-10-16T22:39:42+00:00") == Date(timeIntervalSince1970: 1_823_726_382))
        #expect(PortalReport.date("yesterday") == nil && PortalReport.date(nil) == nil)
        #expect(PortalReport.utcDay("2027-10-16T22:39:42.000+0000") == "2027-10-16")
        #expect(PortalReport.utcDay("27-10-16") == nil && PortalReport.utcDay("2027/10/16 x") == nil)
    }

    @Test("days are UTC days whatever offset the timestamp carries")
    func utcDays() throws {
        // `utcDay` formats with a GMT style built in, so the Mac's time zone cannot change it.
        #expect(PortalReport.utcDay("2026-03-04T23:30:00.000+0000") == "2026-03-04")
        #expect(PortalReport.utcDay("2026-03-05T00:30:00.000+0000") == "2026-03-05")
        #expect(PortalReport.utcDay("2026-03-04T23:30:00Z") == "2026-03-04")
        #expect(PortalReport.utcDay("2026-03-05T00:30:00Z") == "2026-03-05")
        // Offsets: 23:30 at -0500 is 04:30Z the next day; 00:30 at +0100 is 23:30Z the day before.
        #expect(PortalReport.utcDay("2026-03-04T23:30:00.000-0500") == "2026-03-05")
        #expect(PortalReport.utcDay("2026-03-05T00:30:00.000+0100") == "2026-03-04")
        #expect(PortalReport.utcDay("2026-03-05T00:30:00+01:00") == "2026-03-04")
        #expect(PortalReport.utcDay("2026-03-04") == "2026-03-04")
        let instant = Date(timeIntervalSince1970: 1_772_667_000)  // 2026-03-04T23:30:00Z
        #expect(PortalReport.utcDay(of: instant) == "2026-03-04")
        #expect(PortalReport.utcDay(of: instant.addingTimeInterval(3600)) == "2026-03-05")

        // The same through the projection: a profile created at 23:30Z and one at 00:30Z.
        let out = report(
            profiles: [
                profileRow("P1", created: "2026-03-04T23:30:00.000+0000", expires: "2027-03-04T23:30:00.000+0000"),
                profileRow("P2", created: "2026-03-05T00:30:00.000+0000", expires: "2027-03-05T00:30:00.000+0000"),
            ])
        let items = try #require(out.envelope.section("profiles")?["items"]?.array)
        #expect(items.compactMap { $0["created"]?.string } == ["2026-03-04", "2026-03-05"])
        #expect(items.compactMap { $0["expires"]?.string } == ["2027-03-04", "2027-03-05"])
    }

    @Test("requested sections only: the rest are skipped")
    func skipped() throws {
        let out = report(devices: [deviceRow("D1", udid: savedUdid("1"))], requested: [.devices])
        #expect(out.envelope.section("devices")?["status"] == "ok")
        for name in ["certificates", "bundleIds", "profiles"] {
            #expect(out.envelope.section(name)?["status"] == "skipped")
            #expect(out.envelope.section(name)?["items"] == [])
        }
        #expect(out.envelope.ok)
    }

    @Test("a failing section is reported and the others are kept")
    func partialFailure() throws {
        let error = SideloadError("ASC_FORBIDDEN", "no", fix: "switch", data: ["appleCode": "FORBIDDEN_ERROR"])
        let out = report(
            devices: [deviceRow("D1", udid: savedUdid("1"))], profiles: [profileRow("P1")], failing: [.certificates: error])
        #expect(!out.envelope.ok)
        #expect(out.envelope.exitCode == 1)
        #expect(out.envelope.errorCodes == ["ASC_FORBIDDEN"])
        let section = try #require(out.envelope.section("certificates"))
        #expect(section["status"] == "error" && section["code"] == "ASC_FORBIDDEN")
        #expect(section["appleCode"] == nil, "the Apple code stays in the error's data, not in the section")
        let printed = try out.envelope.printed().text
        #expect(!printed.contains("FORBIDDEN_ERROR"))
        #expect(out.envelope.section("devices")?["count"] == 1)
        #expect(out.envelope.section("profiles")?["status"] == "ok")
    }

    @Test("a truncated list keeps its items but is an error")
    func truncated() throws {
        var results: [PortalResource: Result<PortalListing, SideloadError>] = [:]
        results[.devices] = listing([deviceRow("D1", udid: savedUdid("1"))], truncated: true)
        let envelope = PortalReport.build(
            PortalReportInput(
                requested: [.devices], results: results, role: nil, keyIdTail: "2345", bundleIdPrefix: nil,
                savedUDIDs: [], keychainReferences: { nil }, now: testNow, showIdentifiers: false))
        #expect(!envelope.ok)
        #expect(envelope.errorCodes == ["PORTAL_TRUNCATED"])
        #expect(envelope.section("devices")?["truncated"] == true)
        #expect(envelope.section("devices")?["count"] == 1)
        #expect(envelope.json["key"]?["role"] == .null)
    }

    // MARK: Team guard

    private func expectWithheld(_ out: (envelope: Envelope, keychainReads: Int), _ code: String) throws {
        #expect(!out.envelope.ok)
        #expect(out.envelope.errorCodes == [code])
        #expect(out.envelope.json["sections"] == nil && out.envelope.json["summary"] == nil)
        #expect(out.envelope.json["counts"] != nil)
        let text = try out.envelope.printed().text
        #expect(!text.contains("CERT0") && !text.contains("DEV"))
    }

    @Test("a certificate of the free team withholds the listing", arguments: [TestCerts.free])
    func freeCertificate(cert: String) throws {
        let out = report(
            certificates: [certRow("CERT0A", content: TestCerts.paid), certRow("CERT0B", content: cert)],
            devices: [deviceRow("DEV1", udid: savedUdid("1"))])
        try expectWithheld(out, "FREE_TEAM_SELECTED")
        #expect(out.envelope.json["counts"]?["certificates"] == 2 && out.envelope.json["counts"]?["devices"] == 1)
    }

    @Test("a certificate of another team, with another first OU or with none, withholds the listing", arguments: [
        TestCerts.other, TestCerts.multi, TestCerts.noou,
    ])
    func otherTeamCertificate(cert: String) throws {
        try expectWithheld(report(certificates: [certRow("CERT0A", content: cert)]), "TEAM_MISMATCH")
    }

    @Test("a free-team OU anywhere in the subject is treated as the free team")
    func freeAnywhere() throws {
        // `multi` has OUs TESTTEAM02 then the paid team; the deny-list check is separate from the first-OU check.
        let info = CertInfo(ous: ["7AGMPUPP64", "6ZU5Z6ZKK7"])
        let cert = KeychainCertificate(reference: "AA", info: info)
        #expect(PortalReport.teamGuard([cert], [])?.code == "FREE_TEAM_SELECTED")
    }

    @Test("an App ID seed of another team withholds the listing")
    func seedMismatch() throws {
        try expectWithheld(report(bundleIds: [bundleRow("B1", "com.example.a", seed: "OTHERTEAM1")]), "TEAM_MISMATCH")
        try expectWithheld(report(bundleIds: [bundleRow("B1", "com.example.a", seed: "6ZU5Z6ZKK7")]), "FREE_TEAM_SELECTED")
    }

    @Test("TEAM_UNVERIFIED when no certificate or App ID was there to check", arguments: [
        PortalResource.devices, .profiles, .certificates, .bundleIds,
    ])
    func teamUnverified(only: PortalResource) throws {
        let out = report(
            devices: [deviceRow("D1", udid: savedUdid("1"))], profiles: [profileRow("P1")], requested: [only])
        let warnings = out.envelope.json["warnings"]?.array ?? []
        let unverified = try #require(warnings.first { $0["code"] == "TEAM_UNVERIFIED" })
        #expect(unverified["fix"]?.string?.isEmpty == false)
        #expect(out.envelope.ok)
    }

    @Test("TEAM_UNVERIFIED when certificates failed and there are no App IDs, not when a team check ran")
    func teamUnverifiedCases() {
        let forbidden = SideloadError("ASC_FORBIDDEN", "no", fix: "f")
        let failed = report(devices: [], failing: [.certificates: forbidden])
        #expect(failed.envelope.json["warnings"]?.array?.contains { $0["code"] == "TEAM_UNVERIFIED" } == true)
        let viaCert = report(certificates: [certRow("C1")])
        #expect(viaCert.envelope.json["warnings"]?.array?.contains { $0["code"] == "TEAM_UNVERIFIED" } == false)
        let viaSeed = report(bundleIds: [bundleRow("B1", "com.example.a")], failing: [.certificates: forbidden])
        #expect(viaSeed.envelope.json["warnings"]?.array?.contains { $0["code"] == "TEAM_UNVERIFIED" } == false)
    }

    @Test("data of the paid team passes the guard")
    func guardPasses() {
        let out = report(
            certificates: [certRow("CERT0A", content: TestCerts.paid), certRow("CERT0B", content: TestCerts.expired)],
            bundleIds: [bundleRow("B1", "com.example.a")])
        #expect(out.envelope.ok)
        #expect(out.envelope.json["team"] == "7AGMPUPP64")
        #expect(PortalReport.teamGuard([], []) == nil)
    }
}

extension JSONValue {
    fileprivate var objectKeys: [String]? {
        if case .object(let o) = self { return Array(o.keys) }
        return nil
    }
}
