import Foundation
import Testing

@testable import SideloadCore

private func cert(_ pem: String) throws -> KeychainCertificate {
    let der = try #require(Data(base64Encoded: pem, options: .ignoreUnknownCharacters))
    var read = try #require(CertificateReader.read(der: der))
    read.isValidForCodeSigning = true  // what `SecurityKeychain` reports for a trusted, unexpired identity
    return read
}

private func hand(_ reference: String, _ info: CertInfo, valid: Bool = true) -> KeychainCertificate {
    KeychainCertificate(reference: reference, info: info, isValidForCodeSigning: valid)
}

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// 2026-10-19 12:00 UTC, the `NOW` of the Node doctor tests.
private let now = utc(2026, 10, 19, 12)

private let paidExpiry = utc(2027, 10, 16, 22, 39, 42)

/// Every string a finding carries, for leak assertions.
private func text(_ findings: [CheckResult]) -> String {
    findings.map { "\($0.id) \($0.message) \($0.fix ?? "") \($0.daysLeft.map(String.init) ?? "")" }.joined(separator: "\n")
}

@Suite("certificate reader")
struct CertificateReaderTests {
    // Mirrors "parses identities, certificates and openssl multiline subjects" (openssl-paid/free fixtures).
    @Test func paidCertificateGivesTeamOUAndExpiry() throws {
        let paid = try cert(TestCerts.paid)
        #expect(paid.info.ous == ["7AGMPUPP64"])
        #expect(paid.info.teamOU == "7AGMPUPP64")
        #expect(paid.info.notAfter == paidExpiry)
        #expect(paid.info.isAppleDevelopment)
        #expect(paid.info.isPaidTeam)
    }

    @Test func freeCertificateGivesDenyListedOU() throws {
        let free = try cert(TestCerts.free)
        #expect(free.info.ous == ["6ZU5Z6ZKK7"])
        #expect(free.info.notAfter == paidExpiry)
        #expect(free.info.carriesDeniedOU)
        #expect(!free.info.isPaidTeam)
    }

    @Test func otherTeamIsNotPaidAndNotDenied() throws {
        let other = try cert(TestCerts.other)
        #expect(other.info.ous == ["TESTTEAM01"])
        #expect(other.info.notAfter == utc(2030, 12, 31))
        #expect(!other.info.isPaidTeam)
        #expect(!other.info.carriesDeniedOU)
    }

    @Test func multipleOUsKeepOrderAndGeneralizedTimeParses() throws {
        let multi = try cert(TestCerts.multi)
        #expect(multi.info.ous == ["TESTTEAM02", "7AGMPUPP64"])
        #expect(multi.info.notAfter == utc(2055, 12, 31, 23, 59, 59))
        // Node's first-OU rule: the first OU is another team, so this is not the paid team's certificate.
        #expect(multi.info.teamOU == "TESTTEAM02")
        #expect(!multi.info.isPaidTeam)
    }

    @Test func certificateWithoutOUHasNoTeam() throws {
        let noOU = try cert(TestCerts.noou)
        #expect(noOU.info.ous.isEmpty)
        #expect(noOU.info.teamOU == nil)
        #expect(!noOU.info.isPaidTeam)
    }

    @Test func referenceIsAStableSHA1AndDiffersPerCertificate() throws {
        let a = try cert(TestCerts.paid)
        let again = try cert(TestCerts.paid)
        let b = try cert(TestCerts.free)
        #expect(a.reference == again.reference)
        #expect(a.reference != b.reference)
        #expect(a.reference.count == 40)
        #expect(a.reference.allSatisfy { $0.isHexDigit && !$0.isLowercase })
    }

    @Test func garbageIsNotACertificate() {
        #expect(CertificateReader.read(der: Data([0x30, 0x03, 0x01, 0x02, 0x03])) == nil)
        #expect(CertificateReader.read(der: Data()) == nil)
    }

    @Test func commonNameIsNotKept() throws {
        let paid = try cert(TestCerts.paid)
        let dump = String(describing: paid)
        #expect(!dump.contains("Test (TEST"))
        #expect(!dump.contains("Apple Development:"))
    }
}

@Suite("cert check")
struct CertCheckTests {
    // "passes for the paid team OU and never prints the identity name, hash or email"
    @Test func passesForPaidTeamAndLeaksNothing() throws {
        let paid = try cert(TestCerts.paid)
        let out = CertCheck.run(keychain: FakeKeychain([paid]), now: now)
        #expect(out.count == 1)
        #expect(out[0].id == "cert")
        #expect(out[0].severity == .ok)
        #expect(out[0].message == "Apple Development (team 7AGMPUPP64) valid until 2027-10-16 (362 days).")
        #expect(out[0].daysLeft == 362)
        let all = text(out)
        #expect(!all.contains(paid.reference))
        #expect(!all.contains("TEST000001"))
        #expect(!all.contains("Apple Development:"))
    }

    // "reports the free team as 'other team, ignored' and fails when it is the only cert"
    @Test func freeTeamIsIgnoredAndFailsWhenAlone() throws {
        let out = CertCheck.run(keychain: FakeKeychain([try cert(TestCerts.free)]), now: now)
        #expect(out[0].id == "cert")
        #expect(out[0].severity == .fail)
        #expect(out[0].message == "No Apple Development certificate for team 7AGMPUPP64 in the keychain.")
        let other = try #require(out.first { $0.id == "cert-other-team" })
        #expect(other.severity == .info)
        #expect(other.message.hasPrefix("other team, ignored"))
        #expect(other.message == "other team, ignored (6ZU5Z6ZKK7, deny-listed)")
    }

    // "warns under 60 days and fails when expired"
    @Test func warnsUnder60DaysAndFailsWhenExpired() throws {
        let paid = try cert(TestCerts.paid)
        let near = CertCheck.run(keychain: FakeKeychain([paid]), now: utc(2027, 10, 1))
        #expect(near[0].severity == .warn)
        #expect(near[0].daysLeft == 15)
        #expect(near[0].fix != nil)

        let gone = CertCheck.run(keychain: FakeKeychain([paid]), now: utc(2028, 1, 1))
        #expect(gone[0].severity == .fail)
        // Swift applies `find-identity -v` semantics to every input, so a past notAfter is "none" (Node's parser
        // path would say "expired"; on a real keychain both say none: design section 14).
        #expect(gone[0].message == "No Apple Development certificate for team 7AGMPUPP64 in the keychain.")
    }

    @Test func warnBoundaryIsSixtyDays() throws {
        let paid = try cert(TestCerts.paid)
        // 60 full days left is ok; one second less is 59 days and warns.
        let sixty = CertCheck.run(keychain: FakeKeychain([paid]), now: paidExpiry.addingTimeInterval(-60 * 86_400))
        #expect(sixty[0].severity == .ok)
        let fiftyNine = CertCheck.run(
            keychain: FakeKeychain([paid]), now: paidExpiry.addingTimeInterval(-60 * 86_400 + 1))
        #expect(fiftyNine[0].severity == .warn)
        #expect(fiftyNine[0].daysLeft == 59)
    }

    // "fails when there are no identities"
    @Test func failsWithNoIdentities() {
        let out = CertCheck.run(keychain: FakeKeychain([]), now: now)
        #expect(out.count == 1)
        #expect(out[0].severity == .fail)
    }

    // "passes with both teams present and ignores the free one"
    @Test func bothTeamsPassAndIgnoreFree() throws {
        let out = CertCheck.run(keychain: FakeKeychain([try cert(TestCerts.paid), try cert(TestCerts.free)]), now: now)
        #expect(out.map(\.id) == ["cert", "cert-other-team"])
        #expect(out.map(\.severity) == [.ok, .info])
    }

    @Test func keychainFailureIsAFailFinding() {
        let out = CertCheck.run(keychain: FakeKeychain(failure: KeychainError("SecItemCopyMatching failed (OSStatus -25308)")), now: now)
        #expect(out.count == 1)
        #expect(out[0].severity == .fail)
        #expect(out[0].message == "Could not read signing identities: SecItemCopyMatching failed (OSStatus -25308).")
        #expect(out[0].fix == "Check that the login keychain is unlocked.")
    }

    @Test func nonKeychainErrorsAreGeneric() {
        struct Boom: Error, CustomStringConvertible { var description: String { "Apple Development: a@b.invalid" } }
        let out = CertCheck.run(keychain: FakeKeychain(failure: Boom()), now: now)
        #expect(out[0].severity == .fail)
        #expect(!text(out).contains("a@b.invalid"))
    }

    @Test func freeTeamIsNeverSelectedEvenWithAFurtherFutureExpiry() throws {
        let paid = try cert(TestCerts.paid)
        let free = try cert(TestCerts.free)
        var later = free
        later.info.notAfter = utc(2099, 1, 1)
        let out = CertCheck.evaluate([later, paid], now: now)
        #expect(out[0].message.contains("valid until 2027-10-16"))
        #expect(CertCheck.evaluate([later], now: now)[0].severity == .fail)
    }

    @Test func subjectCarryingBothPaidAndDeniedOUIsNotSelected() {
        let mixed = hand("AA", CertInfo(ous: ["7AGMPUPP64", "6ZU5Z6ZKK7"], notAfter: utc(2099, 1, 1)))
        let out = CertCheck.evaluate([mixed], now: now)
        #expect(out[0].severity == .fail)
        #expect(out.map(\.id) == ["cert", "cert-other-team"])
        #expect(out[1].message == "other team, ignored (6ZU5Z6ZKK7, deny-listed)")
    }

    @Test func deniedOUFirstIsLabelledDenyListedEvenWithPaidOUSecond() {
        let mixed = hand("AB", CertInfo(ous: ["6ZU5Z6ZKK7", "7AGMPUPP64"], notAfter: utc(2099, 1, 1)))
        let out = CertCheck.evaluate([mixed], now: now)
        #expect(out[0].severity == .fail)
        #expect(out[1].message == "other team, ignored (6ZU5Z6ZKK7, deny-listed)")
    }

    // Node's first-OU rule: [other, paid] is another team's certificate.
    @Test func paidOUSecondIsAnotherTeam() throws {
        let out = CertCheck.evaluate([try cert(TestCerts.multi)], now: now)
        #expect(out.map(\.severity) == [.fail, .info])
        #expect(out[1].message == "other team, ignored")
    }

    @Test func expiredPaidPlusValidOtherReportsNoneAndTheOtherTeam() throws {
        let out = CertCheck.evaluate([try cert(TestCerts.paid), try cert(TestCerts.other)], now: utc(2028, 1, 1))
        #expect(out.map(\.severity) == [.fail, .info])
        #expect(out[0].message == "No Apple Development certificate for team 7AGMPUPP64 in the keychain.")
        #expect(out[1].message == "other team, ignored")
    }

    @Test func picksTheLatestExpiryAmongPaidCerts() throws {
        let early = try cert(TestCerts.paid)
        let late = hand("LATE", CertInfo(ous: ["7AGMPUPP64"], notAfter: utc(2055, 12, 31, 23, 59, 59)))
        let out = CertCheck.evaluate([early, late], now: now)
        #expect(out.count == 1)
        #expect(out[0].message.contains("valid until 2055-12-31"))
    }

    @Test func duplicateReferencesCountOnce() throws {
        let free = try cert(TestCerts.free)
        let other = try cert(TestCerts.other)
        let out = CertCheck.evaluate([free, free, other, other], now: now)
        #expect(out.map(\.id) == ["cert", "cert-other-team", "cert-other-team"])
    }

    @Test func sameOtherTeamIsReportedOnce() {
        let a = hand("A1", CertInfo(ous: ["TESTTEAM01"], notAfter: utc(2030, 1, 1)))
        let b = hand("B2", CertInfo(ous: ["TESTTEAM01"], notAfter: utc(2031, 1, 1)))
        #expect(CertCheck.evaluate([a, b], now: now).filter { $0.id == "cert-other-team" }.count == 1)
    }

    @Test func nonDevelopmentCertificatesAreIgnored() {
        let dist = hand("C3", CertInfo(ous: ["7AGMPUPP64"], notAfter: utc(2099, 1, 1), isAppleDevelopment: false))
        let out = CertCheck.evaluate([dist], now: now)
        #expect(out.count == 1)
        #expect(out[0].severity == .fail)
    }

    @Test func unreadableExpiryIsNotValid() {
        let out = CertCheck.evaluate([hand("D4", CertInfo(ous: ["7AGMPUPP64"], notAfter: nil))], now: now)
        #expect(out.count == 1)
        #expect(out[0].severity == .fail)
    }

    // `find-identity -v` parity: untrusted/revoked identities do not count, whatever their team.
    @Test func identitiesNotValidForCodeSigningAreIgnored() throws {
        var paid = try cert(TestCerts.paid)
        paid.isValidForCodeSigning = false
        var other = try cert(TestCerts.other)
        other.isValidForCodeSigning = false
        let out = CertCheck.evaluate([paid, other], now: now)
        #expect(out.map(\.id) == ["cert"])
        #expect(out[0].severity == .fail)
        #expect(out[0].message == "No Apple Development certificate for team 7AGMPUPP64 in the keychain.")
    }

    @Test func unvalidatedIdentitiesDefaultToInvalid() {
        #expect(!KeychainCertificate(reference: "E5", info: CertInfo(ous: ["7AGMPUPP64"])).isValidForCodeSigning)
    }

    @Test func expiredOtherTeamsAreNotReported() throws {
        let expiredOther = hand("X9", CertInfo(ous: ["TESTTEAM01"], notAfter: utc(2020, 1, 1)))
        let out = CertCheck.evaluate([try cert(TestCerts.paid), expiredOther], now: now)
        #expect(out.map(\.id) == ["cert"])
        #expect(out[0].severity == .ok)
    }

    @Test func expiredPaidCertAloneFails() throws {
        let out = CertCheck.evaluate([try cert(TestCerts.expired)], now: now)
        #expect(out.map(\.severity) == [.fail])
    }

    @Test func otherTeamsAreDeduplicatedOnTheFirstOU() {
        let a = hand("F6", CertInfo(ous: ["TESTTEAM01", "TESTTEAM02"], notAfter: utc(2030, 1, 1)))
        let b = hand("G7", CertInfo(ous: ["TESTTEAM01", "TESTTEAM03"], notAfter: utc(2030, 1, 1)))
        let c = hand("H8", CertInfo(ous: ["TESTTEAM02"], notAfter: utc(2030, 1, 1)))
        #expect(CertCheck.evaluate([a, b, c], now: now).filter { $0.id == "cert-other-team" }.count == 2)
    }

    @Test func readsTheKeychainOnce() throws {
        let fake = FakeKeychain([try cert(TestCerts.paid)])
        _ = CertCheck.run(keychain: fake, now: now)
        #expect(fake.readCount == 1)
    }
}

@Suite("code-signing trust")
struct CodeSigningTrustTests {
    private func der(_ pem: String) throws -> Data {
        try #require(Data(base64Encoded: pem, options: .ignoreUnknownCharacters))
    }

    // Self-signed throwaway certificates chain to no trusted root.
    @Test func selfSignedCertificateIsUntrusted() throws {
        #expect(!CodeSigningTrust.isValid(der: try der(TestCerts.paid)))
        #expect(!CodeSigningTrust.isValid(der: try der(TestCerts.free)))
    }

    @Test func expiredCertificateIsNotValid() throws {
        #expect(!CodeSigningTrust.isValid(der: try der(TestCerts.expired)))
    }

    @Test func garbageIsNotValid() {
        #expect(!CodeSigningTrust.isValid(der: Data([0x30, 0x00])))
    }
}

@Suite("security keychain")
struct SecurityKeychainTests {
    private static let enabled = ProcessInfo.processInfo.environment["SIDELOAD_REAL_KEYCHAIN"] == "1"

    /// Opt-in: reads the real login keychain, read-only. Asserts only the team OU and a future expiry; prints nothing.
    @Test(.enabled(if: enabled, "set SIDELOAD_REAL_KEYCHAIN=1"))
    func realKeychainHasAPaidTeamIdentity() throws {
        let identities = try SecurityKeychain().developmentIdentities()
        let paid = identities.filter { $0.isValidForCodeSigning && $0.info.isPaidTeam }
        #expect(!paid.isEmpty)
        #expect(paid.contains { ($0.info.notAfter ?? .distantPast) > Date() })
    }
}
