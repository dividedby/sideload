import Darwin
import Foundation
import Testing

@testable import SideloadCore

private func thrownCode(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return errorCode(of: error)
    }
}

private func cert(_ base64: String, valid: Bool = true) throws -> KeychainCertificate {
    var c = try keychainCert(base64)
    c.isValidForCodeSigning = valid
    return c
}

@Suite("Ledger store")
struct LedgerStoreTests {
    private func sample() -> Ledger {
        Ledger(
            updated: testNow,
            certificates: [
                LedgerCertificate(
                    fp8: "0a1b2c3d", team: Team.id, notBefore: daysFromNow(-30), notAfter: daysFromNow(335),
                    firstSeen: daysFromNow(-5), lastSeen: testNow, valid: true, present: true)
            ],
            profiles: [
                LedgerProfile(
                    uuid: UUID().uuidString, team: Team.id, applicationId: Team.id + ".*", wildcard: true,
                    created: nil, expires: daysFromNow(100), deviceCount: 1, deviceTails: ["a001"], certFp8s: ["0a1b2c3d"],
                    source: "xcode-managed", firstSeen: testNow, lastSeen: testNow, present: true)
            ],
            exports: [
                LedgerExport(
                    id: "e1", createdAt: testNow, certFp8: "0a1b2c3d", profileUuid: "P", p12File: "secrets/p12/x.p12",
                    p12Sha256Prefix: "deadbeef", encryption: "pbes2", passwordItem: "keychain",
                    kitPath: "exports/feather-1", verified: true)
            ])
    }

    @Test("a missing file is an empty ledger; update writes 0600 and round-trips")
    func roundTrip() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            #expect(try store.load() == Ledger())
            let ledger = sample()
            try await store.update { $0 = ledger }
            #expect(modeOf(paths.ledger) == 0o600)
            #expect(modeOf(paths.ledgerLock) == 0o600)
            #expect(try store.load() == ledger)
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
            let text = try String(contentsOfFile: paths.ledger, encoding: .utf8)
            #expect(text.contains("\"schema\" : 1"))
            #expect(text.contains("2026-10-19T12:00:00Z"), "ISO 8601 UTC")
        }
    }

    @Test("unknown top-level keys survive a rewrite")
    func unknownKeys() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            let doc = #"{"schema":1,"certificates":[],"profiles":[],"exports":[],"future":{"a":[1,2]},"note":"keep"}"#
            try Data(doc.utf8).write(to: URL(fileURLWithPath: paths.ledger))
            try await store.update { $0.updated = testNow }
            let after = try decodeJSON(try String(contentsOfFile: paths.ledger, encoding: .utf8))
            #expect(after["future"] == ["a": [1, 2]])
            #expect(after["note"] == "keep")
            #expect(after["schema"] == 1)
        }
    }

    @Test("unknown keys inside certificate, profile and export entries survive a rewrite and a merge")
    func unknownEntryKeys() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            let paid = try keychainCert(TestCerts.paid)
            let uuid = UUID().uuidString
            let doc = """
                {"schema":1,
                 "certificates":[{"fp8":"\(LedgerSync.fp8(paid.reference))","team":"7AGMPUPP64",
                   "notAfter":"2027-10-16T22:39:42Z","firstSeen":"2026-10-01T00:00:00Z",
                   "lastSeen":"2026-10-01T00:00:00Z","valid":true,"present":true,"label":{"k":[1]}}],
                 "profiles":[{"uuid":"\(uuid)","team":"7AGMPUPP64","wildcard":true,"expires":"2027-01-01T00:00:00Z",
                   "deviceCount":0,"deviceTails":[],"certFp8s":[],"source":"xcode-managed",
                   "firstSeen":"2026-10-01T00:00:00Z","lastSeen":"2026-10-01T00:00:00Z","present":true,"pinned":true}],
                 "exports":[{"id":"e","createdAt":"2026-10-02T00:00:00Z","certFp8":"0a1b2c3d","profileUuid":"\(uuid)",
                   "p12File":"f","p12Sha256Prefix":"00000000","encryption":"pbes2","passwordItem":"keychain",
                   "kitPath":"k","verified":true,"note":"mine"}]}
                """
            try Data(doc.utf8).write(to: URL(fileURLWithPath: paths.ledger))

            // Rewrite as is: nothing is lost.
            try await store.update { $0.updated = testNow }
            let after = try decodeJSON(try String(contentsOfFile: paths.ledger, encoding: .utf8))
            #expect(after["certificates"]?.array?[0]["label"] == ["k": [1]])
            #expect(after["profiles"]?.array?[0]["pinned"] == true)
            #expect(after["exports"]?.array?[0]["note"] == "mine")

            // A refresh that sees the same certificate and profile replaces the entries; the extras stay.
            var profile = paidProfile(uuid: uuid)
            profile.expires = daysFromNow(200)
            try await store.update { LedgerSync.merge(&$0, certificates: [paid], profiles: [profile], now: testNow) }
            let merged = try store.load()
            #expect(merged.certificates[0].extra == ["label": ["k": [1]]])
            #expect(merged.profiles[0].extra == ["pinned": true])
            #expect(merged.exports[0].extra == ["note": "mine"])
            #expect(merged.profiles[0].expires == daysFromNow(200), "known fields are refreshed")
            #expect(merged.certificates[0].firstSeen == Date(timeIntervalSince1970: 1_790_812_800), "2026-10-01")
        }
    }

    @Test("invalid files are LEDGER_INVALID and never echo their content", arguments: [
        "", "not json", "[]", #"{"schema":2,"certificates":[],"profiles":[],"exports":[]}"#,
        #"{"certificates":[],"profiles":[],"exports":[]}"#, #"{"schema":1,"certificates":"secretword","profiles":[],"exports":[]}"#,
        #"{"schema":1,"certificates":[{"fp8":"secretword"}],"profiles":[],"exports":[]}"#,
    ])
    func invalid(doc: String) async throws {
        try await withTestHome { paths, _ in
            try Data(doc.utf8).write(to: URL(fileURLWithPath: paths.ledger))
            let store = LedgerStore(paths: paths)
            #expect(await thrownCode { _ = try store.load() } == "LEDGER_INVALID")
            #expect(await thrownCode { try await store.update { $0.updated = testNow } } == "LEDGER_INVALID")
            #expect(try String(contentsOfFile: paths.ledger, encoding: .utf8) == doc, "left untouched")
            do {
                _ = try store.load()
            } catch let error as SideloadError {
                #expect(!error.message.contains("secretword") && !(error.fix ?? "").contains("secretword"))
            }
        }
    }

    @Test("BUSY after the bounded wait while the ledger lock is held; nothing is written")
    func busy() async throws {
        try await withTestHome { paths, _ in
            let held = try #require(try FileLock.tryAcquire(path: paths.ledgerLock))
            let store = LedgerStore(paths: paths, lockTimeout: .milliseconds(150), retryInterval: .milliseconds(10))
            let start = ContinuousClock.now
            #expect(await thrownCode { try await store.update { $0.updated = testNow } } == "BUSY")
            #expect(ContinuousClock.now - start >= .milliseconds(150))
            #expect(!FileManager.default.fileExists(atPath: paths.ledger))
            held.release()
            try await store.update { $0.updated = testNow }
            #expect(try store.load().updated == testNow)
        }
    }

    @Test("ledger.json is 0600 after every write and the lock is free again once update returns")
    func modeAndLockAfterWrite() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            for day in 0..<2 {
                try await store.update { $0.updated = daysFromNow(Double(day)) }
                #expect(modeOf(paths.ledger) == 0o600)
                #expect(modeOf(paths.ledgerLock) == 0o600)
                let again = try #require(try FileLock.tryAcquire(path: paths.ledgerLock), "lock released after the write")
                again.release()
            }
            // Loosened by hand, the next write restores 0600.
            #expect(chmod(paths.ledger, 0o644) == 0)
            try await store.update { $0.updated = testNow }
            #expect(modeOf(paths.ledger) == 0o600)
            // A failing body also releases the lock.
            struct Boom: Error {}
            _ = await thrownCode { try await store.update { (_: inout Ledger) in throw Boom() } }
            let free = try #require(try FileLock.tryAcquire(path: paths.ledgerLock))
            free.release()
        }
    }

    @Test("the config lock does not block the ledger")
    func independentLocks() async throws {
        try await withTestHome { paths, _ in
            let held = try #require(try FileLock.tryAcquire(path: paths.configLock))
            defer { held.release() }
            try await LedgerStore(paths: paths).update { $0.updated = testNow }
        }
    }

    @Test("a body that throws writes nothing")
    func bodyThrows() async throws {
        try await withTestHome { paths, _ in
            struct Boom: Error {}
            let store = LedgerStore(paths: paths)
            try await store.update { $0 = sample() }
            let before = try Data(contentsOf: URL(fileURLWithPath: paths.ledger))
            do {
                try await store.update { (l: inout Ledger) in
                    l.exports.removeAll()
                    throw Boom()
                }
            } catch {}
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) == before)
        }
    }

    @Test("a failed write is LEDGER_WRITE_FAILED, leaves the old ledger, and the real writer cleans its temp file")
    func writeFails() async throws {
        try await withTestHome { paths, _ in
            let good = LedgerStore(paths: paths)
            try await good.update { $0.updated = testNow }
            let before = try Data(contentsOf: URL(fileURLWithPath: paths.ledger))
            let failing = LedgerStore(paths: paths) { _, _ in throw ioError("rename", ENOSPC) }
            #expect(await thrownCode { try await failing.update { $0.updated = daysFromNow(1) } } == "LEDGER_WRITE_FAILED")
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) == before)
            // The real writer, with the last step failing, removes its temp file.
            #expect(throws: SideloadError.self) {
                try AtomicFile.write(Data("x".utf8), to: paths.ledger, rename: { _, _ in -1 })
            }
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test("the new paths live under the home")
    func paths() {
        let p = Paths(home: "/h")
        #expect(p.ledger == "/h/ledger.json" && p.ledgerLock == "/h/.ledger.lock")
        #expect(p.p12Dir == "/h/secrets/p12" && p.exports == "/h/exports")
        #expect(!Paths.subdirectories.contains("exports") && !Paths.subdirectories.contains("p12"))
    }
}

@Suite("Ledger sync")
struct LedgerSyncTests {
    @Test("records only the paid team; the free team and other teams are counted and dropped")
    func paidOnly() throws {
        var ledger = Ledger()
        let paid = try cert(TestCerts.paid)
        let certs = [paid, try cert(TestCerts.free), try cert(TestCerts.other), try cert(TestCerts.multi)]
        let ours = paidProfile(certs: [paid.reference])
        var free = paidProfile()
        free.team = "6ZU5Z6ZKK7"
        var other = paidProfile()
        other.team = "TESTTEAM01"
        var undated = paidProfile()
        undated.expires = nil

        let s = LedgerSync.merge(&ledger, certificates: certs, profiles: [ours, free, other, undated], now: testNow)
        #expect(s.certificates == 1 && s.ignoredCertificates == 3)
        #expect(s.profiles == 1 && s.ignoredProfiles == 3)
        #expect(ledger.certificates.map(\.fp8) == [LedgerSync.fp8(paid.reference)])
        #expect(ledger.certificates[0].fp8.count == 8 && ledger.certificates[0].fp8 == ledger.certificates[0].fp8.lowercased())
        #expect(ledger.certificates[0].team == Team.id)
        #expect(ledger.certificates[0].valid && ledger.certificates[0].present)
        #expect(ledger.profiles.map(\.uuid) == [ours.uuid])
        #expect(ledger.profiles[0].certFp8s == [LedgerSync.fp8(paid.reference)])
        #expect(ledger.profiles[0].wildcard && ledger.profiles[0].deviceCount == 1)
        #expect(ledger.profiles[0].deviceTails == [String(savedUdid("1").lowercased().suffix(4))])
        #expect(ledger.updated == testNow)
    }

    @Test("a [paid, free] subject is never recorded")
    func mixedSubject() throws {
        var ledger = Ledger()
        var mixed = try cert(TestCerts.paid)
        mixed.info.ous = [Team.id, "6ZU5Z6ZKK7"]
        LedgerSync.merge(&ledger, certificates: [mixed], profiles: [], now: testNow)
        #expect(ledger.certificates.isEmpty)
    }

    @Test("a later refresh keeps firstSeen, updates lastSeen, and marks what vanished as history")
    func merges() throws {
        var ledger = Ledger()
        let paid = try cert(TestCerts.paid)
        let expired = try cert(TestCerts.expired, valid: false)
        let p1 = paidProfile()
        LedgerSync.merge(&ledger, certificates: [paid, expired], profiles: [p1], now: testNow)
        #expect(ledger.certificates.count == 2)
        let expiredEntry = try #require(ledger.certificates.first { $0.fp8 == LedgerSync.fp8(expired.reference) })
        #expect(!expiredEntry.valid && expiredEntry.present, "expired: seen, not valid")

        let later = testNow.addingTimeInterval(3 * 86_400 + 0.7)
        var renewed = p1
        renewed.expires = daysFromNow(400)
        let p2 = paidProfile()
        LedgerSync.merge(&ledger, certificates: [paid], profiles: [renewed, p2], now: later)
        let kept = try #require(ledger.certificates.first { $0.fp8 == LedgerSync.fp8(paid.reference) })
        #expect(kept.firstSeen == testNow && kept.lastSeen == Date(timeIntervalSince1970: testNow.timeIntervalSince1970 + 3 * 86_400))
        let gone = try #require(ledger.certificates.first { $0.fp8 == LedgerSync.fp8(expired.reference) })
        #expect(!gone.present && !gone.valid && gone.lastSeen == testNow)
        #expect(ledger.profiles.count == 2)
        #expect(ledger.profiles.first { $0.uuid == p1.uuid }?.expires == daysFromNow(400))
        #expect(ledger.profiles.first { $0.uuid == p1.uuid }?.firstSeen == testNow)

        LedgerSync.merge(&ledger, certificates: [paid], profiles: [p2], now: later)
        #expect(ledger.profiles.first { $0.uuid == p1.uuid }?.present == false)
        #expect(ledger.profiles.count == 2, "history is kept")
    }

    @Test("an untrusted or expired certificate is present but not valid; exports and unknown keys are untouched")
    func validity() throws {
        let export = LedgerExport(
            id: "e", createdAt: testNow, certFp8: "ffffffff", profileUuid: "P", p12File: "f", p12Sha256Prefix: "00000000",
            encryption: "pbes2", passwordItem: "keychain", kitPath: "k", verified: true)
        var ledger = Ledger(exports: [export], extra: ["future": 1])
        LedgerSync.merge(
            &ledger, certificates: [try cert(TestCerts.paid, valid: false), try cert(TestCerts.expired)],
            profiles: [], now: testNow)
        #expect(ledger.certificates.allSatisfy { $0.present && !$0.valid })
        #expect(ledger.exports == [export] && ledger.extra == ["future": 1])
    }

    @Test("duplicate identities and profiles are recorded once")
    func duplicates() throws {
        var ledger = Ledger()
        let paid = try cert(TestCerts.paid)
        let p = paidProfile()
        LedgerSync.merge(&ledger, certificates: [paid, paid], profiles: [p, p], now: testNow)
        #expect(ledger.certificates.count == 1 && ledger.profiles.count == 1)
    }
}
