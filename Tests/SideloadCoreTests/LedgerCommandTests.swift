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
    var ledger: Ledger?
    var ledgerText: String?
    var paths: Paths
    var ledgerMode: Int
    var code: String? { envelope.errors.first?.code }
}

/// Runs `argv` through the CLI over fakes and a temp home. `seed` writes a raw ledger file first.
private func invoke(
    _ argv: [String] = ["ledger"], certs: [String] = [TestCerts.paid], profiles: [ProvisioningProfile] = [],
    skipped: Int = 0, keychainFailure: (any Error)? = nil, profileFailure: (any Error)? = nil, seed: String? = nil
) async throws -> World {
    try await withTestHome { paths, _ in
        if let seed { try Data(seed.utf8).write(to: URL(fileURLWithPath: paths.ledger)) }
        let keychain = FakeKeychain(try certs.map { try keychainCert($0) }, failure: keychainFailure)
        let source = FakeProfileSource(profiles, skipped: skipped, failure: profileFailure)
        var (services, runner) = fakeServices(paths, keychain: keychain)
        services.profiles = source
        let envelope = await run(argv: argv, services: services)
        let (text, json) = try envelope.printed()
        return World(
            envelope: envelope, text: text, json: json, runner: runner, keychain: keychain, source: source,
            ledger: try? LedgerStore(paths: paths).load(),
            ledgerText: try? String(contentsOfFile: paths.ledger, encoding: .utf8), paths: paths,
            ledgerMode: modeOf(paths.ledger))
    }
}

@Suite("ledger command")
struct LedgerCommandTests {
    @Test("ledger on an empty home is read-only: nothing read, nothing written")
    func emptyShow() async throws {
        let w = try await invoke()
        #expect(w.envelope.ok && w.json["command"] == "ledger")
        #expect(w.json["certificates"] == [] && w.json["profiles"] == [] && w.json["exports"] == [] && w.json["items"] == [])
        #expect(w.json["updated"] == .null)
        #expect(w.ledgerText == nil, "no ledger.json created")
        #expect(w.keychain.readCount == 0 && w.source.readCount == 0 && w.runner.calls.isEmpty)
    }

    @Test("ledger refresh records the paid cert and profile, then ledger shows them with items")
    func refreshThenShow() async throws {
        let paid = try keychainCert(TestCerts.paid)
        let profile = paidProfile(certs: [paid.reference], expires: daysFromNow(40))
        let w = try await invoke(
            ["ledger", "refresh"], certs: [TestCerts.paid, TestCerts.free], profiles: [profile], skipped: 2)
        #expect(w.envelope.ok && w.json["command"] == "ledger refresh")
        #expect(w.json["refreshed"] == ["certificates": 1, "profiles": 1, "ignoredCertificates": 1, "ignoredProfiles": 0, "skippedProfiles": 2])
        #expect(w.json["updated"] == "2026-10-19T12:00:00Z")
        #expect(w.keychain.readCount == 1 && w.source.readCount == 1)
        #expect(w.runner.calls.isEmpty, "profiles come from the injected source; no subprocess here")

        let certs = try #require(w.json["certificates"]?.array)
        #expect(certs.count == 1)
        #expect(certs[0]["fp8"]?.string == LedgerSync.fp8(paid.reference))
        #expect(certs[0]["team"] == "7AGMPUPP64" && certs[0]["valid"] == true && certs[0]["present"] == true)
        #expect(certs[0]["notAfter"] == "2027-10-16T22:39:42Z")
        let items = try #require(w.json["items"]?.array)
        #expect(items.count == 2)
        #expect(items[0]["kind"] == "profile" && items[0]["level"] == "warn" && items[0]["daysLeft"] == 40)
        #expect(items[1]["kind"] == "certificate" && items[1]["level"] == "ok")

        let profiles = try #require(w.json["profiles"]?.array)
        #expect(profiles[0]["wildcard"] == true && profiles[0]["deviceCount"] == 1)
        #expect(profiles[0]["certFp8s"] == [.string(LedgerSync.fp8(paid.reference))])
        #expect(profiles[0]["uuid"]?.string == Redactor.tail4(profile.uuid), "UUID masked to its last four")

        #expect(w.ledgerMode == 0o600)
        #expect(w.ledger?.certificates.count == 1 && w.ledger?.profiles.count == 1)
    }

    @Test("a second command sees what a refresh stored")
    func showAfterRefresh() async throws {
        try await withTestHome { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid)])
            var (services, _) = fakeServices(paths, keychain: keychain)
            services.profiles = FakeProfileSource([paidProfile(expires: daysFromNow(10))])
            #expect(await run(argv: ["ledger", "refresh"], services: services).ok)
            let before = keychain.readCount
            let shown = await run(argv: ["ledger"], services: services)
            #expect(shown.ok && keychain.readCount == before, "show never reads the keychain")
            #expect(shown.data["items"]?.array?.count == 2)
            // A day later the ledger alone moves the clock.
            services.clock = FixedClock(daysFromNow(1))
            #expect(await run(argv: ["ledger"], services: services).data["items"]?.array?.first?["daysLeft"] == 9)
        }
    }

    @Test("exports in the ledger are listed with whether their cert and profile are known")
    func exportsListed() async throws {
        let paid = try keychainCert(TestCerts.paid)
        let known = paidProfile()
        let fp = LedgerSync.fp8(paid.reference)
        var ledger = Ledger()
        LedgerSync.merge(&ledger, certificates: [paid], profiles: [known], now: testNow)
        ledger.exports = [
            LedgerExport(
                id: "e1", createdAt: testNow, certFp8: fp, profileUuid: known.uuid, p12File: "secrets/p12/a.p12",
                p12Sha256Prefix: "deadbeef", encryption: "pbes2", passwordItem: "keychain", kitPath: "exports/feather-1",
                verified: true),
            LedgerExport(
                id: "e2", createdAt: testNow, certFp8: "00000000", profileUuid: UUID().uuidString, p12File: "secrets/p12/b.p12",
                p12Sha256Prefix: "cafebabe", encryption: "legacy", passwordItem: "keychain", kitPath: "exports/feather-2",
                verified: false),
        ]
        let seed = String(decoding: try LedgerStore.encode(ledger), as: UTF8.self)
        let w = try await invoke(seed: seed)
        let exports = try #require(w.json["exports"]?.array)
        #expect(exports.map { $0["id"]?.string } == ["e1", "e2"])
        #expect(exports[0]["certificateInLedger"] == true && exports[0]["profileInLedger"] == true)
        #expect(exports[1]["certificateInLedger"] == false && exports[1]["profileInLedger"] == false)
        #expect(exports[0]["profileUuid"]?.string == Redactor.tail4(known.uuid))
    }

    @Test("output, ledger file and logs hold no full UDID, no full fingerprint, no identity name")
    func hygiene() async throws {
        let paid = try keychainCert(TestCerts.paid)
        let udid = savedUdid("1")
        let profile = paidProfile(devices: [udid], certs: [paid.reference])
        let w = try await invoke(["ledger", "refresh"], profiles: [profile])
        let ledgerText = try #require(w.ledgerText)
        for haystack in [w.text, ledgerText] {
            #expect(!haystack.contains(udid) && !haystack.contains(udid.lowercased()))
            #expect(!haystack.uppercased().contains(paid.reference))
            #expect(!haystack.contains("Apple Development") && !haystack.contains("Test (TEST"))
        }
        #expect(!w.text.contains(profile.uuid), "printed UUIDs are masked")
        #expect(!FileManager.default.fileExists(atPath: w.paths.commandsLog))
    }

    @Test("a corrupt ledger stops refresh before the keychain or profiles are read, and is left untouched")
    func corrupt() async throws {
        let w = try await invoke(["ledger", "refresh"], seed: "{secretword")
        #expect(w.code == "LEDGER_INVALID" && !w.envelope.ok)
        #expect(w.keychain.readCount == 0 && w.source.readCount == 0)
        #expect(w.ledgerText == nil || w.ledgerText == "{secretword")
        #expect(!w.text.contains("secretword"))
        let show = try await invoke(seed: "{secretword")
        #expect(show.code == "LEDGER_INVALID" && !show.text.contains("secretword"))
    }

    @Test("a keychain read failure is KEYCHAIN_READ_FAILED and writes nothing")
    func keychainFails() async throws {
        let w = try await invoke(["ledger", "refresh"], keychainFailure: KeychainError("locked"))
        #expect(w.code == "KEYCHAIN_READ_FAILED" && w.envelope.errors[0].fix != nil)
        #expect(w.source.readCount == 0 && w.ledgerText == nil)
    }

    @Test("a profile source failure keeps its code and writes nothing")
    func profilesFail() async throws {
        let w = try await invoke(
            ["ledger", "refresh"], profileFailure: SideloadError("PROFILES_UNREADABLE", "nope", fix: "fix it"))
        #expect(w.code == "PROFILES_UNREADABLE" && w.ledgerText == nil)
    }

    @Test("the inert default profile source fails refresh with PROFILES_UNAVAILABLE")
    func inertDefault() async throws {
        try await withTestHome { paths, _ in
            let (services, _) = fakeServices(paths, keychain: FakeKeychain([try keychainCert(TestCerts.paid)]))
            let out = await run(argv: ["ledger", "refresh"], services: services)
            #expect(out.errorCodes == ["PROFILES_UNAVAILABLE"])
            #expect(!FileManager.default.fileExists(atPath: paths.ledger))
        }
    }

    @Test("ledger refresh needs no --yes and takes no operation lock")
    func noConfirmNoOpLock() async throws {
        try await withTestHome { paths, _ in
            let op = try OperationLock.acquire(paths: paths)
            defer { op.release() }
            var (services, _) = fakeServices(paths, keychain: FakeKeychain([try keychainCert(TestCerts.paid)]))
            services.profiles = FakeProfileSource([])
            #expect(await run(argv: ["ledger", "refresh"], services: services).ok)
        }
    }
}

@Suite("ledger CLI")
struct LedgerCLITests {
    @Test("usage errors")
    func usage() async throws {
        for argv in [["ledger", "bogus"], ["ledger", "refresh", "extra"], ["ledger", "--yes"], ["ledger", "refresh", "--device", "x"], ["ledger", "show"]] {
            let w = try await invoke(argv)
            #expect(w.code == "USAGE", "\(argv)")
            #expect(w.keychain.readCount == 0 && w.source.readCount == 0)
        }
    }

    @Test("help lists ledger as built; ledger -h prints help")
    func help() async throws {
        for argv in [["help"], ["ledger", "-h"], ["ledger", "refresh", "--help"]] {
            let w = try await invoke(argv)
            #expect(w.json["command"] == "help")
            #expect(w.json["built"]?.array?.contains("ledger") == true)
            #expect(w.json["commands"]?.array?.contains("ledger") == true)
            #expect(w.json["usage"]?.array?.contains("ledger [refresh]") == true)
        }
    }
}
