import Foundation
import Testing

@testable import SideloadCore

private func hex40(_ digit: Character) -> String { String(repeating: digit, count: 40) }

private func paidCert(_ digit: Character, days: Double = 300, ous: [String] = [Team.id], valid: Bool = true)
    -> KeychainCertificate
{
    KeychainCertificate(
        reference: hex40(digit), info: CertInfo(ous: ous, notAfter: daysFromNow(days)), isValidForCodeSigning: valid)
}

private let udid = savedUdid("1")

private func profile(
    _ uuid: String, wildcard: Bool = true, certs: [Character] = ["A"], devices: [String]? = nil, days: Double = 300,
    team: String = Team.id, getTaskAllow: Bool = true, platforms: [String] = ["iOS"]
) -> ProvisioningProfile {
    ProvisioningProfile(
        uuid: uuid, team: team, applicationIdentifier: wildcard ? team + ".*" : team + ".io.example.app",
        getTaskAllow: getTaskAllow, platforms: platforms, created: daysFromNow(-30), expires: daysFromNow(days),
        devices: (devices ?? [udid]).map { $0.lowercased() }, certFingerprints: certs.map { hex40($0) })
}

private let u1 = "00000000-0000-0000-0000-000000000001"
private let u2 = "00000000-0000-0000-0000-000000000002"
private let u3 = "00000000-0000-0000-0000-000000000003"

private func plan(
    certs: [KeychainCertificate], profiles: [ProvisioningProfile], profileUUID: String? = nil
) throws -> ExportPlanner.Plan {
    try ExportPlanner.plan(
        certificates: certs, profiles: profiles, udid: udid, profileUUID: profileUUID, now: testNow)
}

private func failure(_ body: () throws -> ExportPlanner.Plan) -> ExportPlanner.Failure? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as? ExportPlanner.Failure
    }
}

@Suite("export planner")
struct ExportPlannerTests {
    @Test("a certificate whose subject carries the free OU is never chosen, even first")
    func freeOUNeverChosen() throws {
        let mixed = paidCert("B", days: 900, ous: [Team.id, "6ZU5Z6ZKK7"])
        let p = profile(u1, certs: ["A", "B"])
        #expect(failure { try plan(certs: [mixed], profiles: [p]) } == .certNotFound)
        let chosen = try plan(certs: [mixed, paidCert("A")], profiles: [p])
        #expect(chosen.certificate.reference == hex40("A"))
        let freeFirst = paidCert("C", ous: ["6ZU5Z6ZKK7"])
        #expect(failure { try plan(certs: [freeFirst], profiles: [profile(u1, certs: ["C"])]) } == .certNotFound)
    }

    @Test("expired, untrusted and other-team certificates are out")
    func certificateFilters() {
        let p = profile(u1, certs: ["A", "B", "C"])
        let expired = paidCert("A", days: -1)
        let untrusted = paidCert("B", valid: false)
        let other = paidCert("C", ous: ["OTHERTEAM1"])
        #expect(failure { try plan(certs: [expired, untrusted, other], profiles: [p]) } == .certNotFound)
    }

    @Test("a wildcard profile beats an explicit one, whatever their expiry")
    func wildcardFirst() throws {
        let explicit = profile(u1, wildcard: false, days: 360)
        let wild = profile(u2, wildcard: true, days: 100)
        let chosen = try plan(certs: [paidCert("A")], profiles: [explicit, wild])
        #expect(chosen.profile.uuid == u2)
        #expect(!chosen.warnsNotWildcard)
        let onlyExplicit = try plan(certs: [paidCert("A")], profiles: [explicit])
        #expect(onlyExplicit.warnsNotWildcard)
    }

    @Test("then the later certificate expiry, then the later profile expiry, then the UUID")
    func tieBreaks() throws {
        let older = paidCert("A", days: 100)
        let newer = paidCert("B", days: 200)
        let both = profile(u1, certs: ["A", "B"])
        #expect(try plan(certs: [older, newer], profiles: [both]).certificate.reference == hex40("B"))

        let short = profile(u1, days: 100)
        let long = profile(u2, days: 200)
        #expect(try plan(certs: [paidCert("A")], profiles: [short, long]).profile.uuid == u2)

        let a = profile(u3), b = profile(u1), c = profile(u2)
        #expect(try plan(certs: [paidCert("A")], profiles: [a, b, c]).profile.uuid == u1)
        #expect(try plan(certs: [paidCert("A")], profiles: [c, a, b]).profile.uuid == u1)
    }

    @Test("a profile without the certificate is out; none left is PROFILE_CERT_MISMATCH")
    func certMustBeInProfile() throws {
        let withoutCert = profile(u1, certs: ["Z"])
        #expect(failure { try plan(certs: [paidCert("A")], profiles: [withoutCert]) } == .certMismatch)
        let chosen = try plan(certs: [paidCert("A")], profiles: [withoutCert, profile(u2, wildcard: false)])
        #expect(chosen.profile.uuid == u2)
    }

    @Test("the device must be in the profile, compared without regard to case")
    func deviceMustBeIncluded() throws {
        let other = profile(u1, devices: [savedUdid("2")])
        #expect(failure { try plan(certs: [paidCert("A")], profiles: [other]) } == .deviceNotInProfile)
        let upper = profile(u2, devices: [udid.uppercased()])
        #expect(try plan(certs: [paidCert("A")], profiles: [other, upper]).profile.uuid == u2)
    }

    @Test("expired, other-team, non-development and non-iOS profiles are not candidates")
    func profileFilters() {
        let candidates = [
            profile(u1, days: -1), profile(u2, team: "OTHERTEAM1"), profile(u3, getTaskAllow: false),
            profile("00000000-0000-0000-0000-000000000004", platforms: ["tvOS"]),
            profile("00000000-0000-0000-0000-000000000005", devices: []),
        ]
        #expect(failure { try plan(certs: [paidCert("A")], profiles: candidates) } == .profileNotFound)
        #expect(failure { try plan(certs: [paidCert("A")], profiles: []) } == .profileNotFound)
    }

    @Test("--profile picks that profile only; an unknown or unusable UUID is PROFILE_NOT_FOUND")
    func profileOverride() throws {
        let wild = profile(u1)
        let explicit = profile(u2, wildcard: false)
        let chosen = try plan(certs: [paidCert("A")], profiles: [wild, explicit], profileUUID: u2.lowercased())
        #expect(chosen.profile.uuid == u2)
        #expect(failure { try plan(certs: [paidCert("A")], profiles: [wild], profileUUID: u3) } == .profileNotFound)
        let expired = profile(u3, days: -2)
        #expect(failure { try plan(certs: [paidCert("A")], profiles: [wild, expired], profileUUID: u3) } == .profileNotFound)
        let elsewhere = profile(u3, devices: [savedUdid("2")])
        #expect(
            failure { try plan(certs: [paidCert("A")], profiles: [wild, elsewhere], profileUUID: u3) }
                == .deviceNotInProfile)
    }

    @Test("failures carry their own code and a fix")
    func failureCodes() {
        let codes = [
            ExportPlanner.Failure.certNotFound: "CERT_NOT_FOUND", .profileNotFound: "PROFILE_NOT_FOUND",
            .deviceNotInProfile: "DEVICE_NOT_IN_PROFILE", .certMismatch: "PROFILE_CERT_MISMATCH",
        ]
        for (failure, code) in codes {
            #expect(failure.sideloadError.code == code)
            #expect(failure.sideloadError.fix?.isEmpty == false)
        }
    }
}

@Suite("CertCheck.paidCandidates")
struct PaidCandidatesTests {
    @Test("valid paid-team certificates, latest expiry first; free, expired and untrusted ones dropped")
    func ordering() throws {
        let certs = [
            paidCert("A", days: 100), paidCert("B", days: 300), paidCert("C", days: 200),
            paidCert("D", days: 900, ous: ["6ZU5Z6ZKK7"]), paidCert("E", days: 900, ous: [Team.id, "6ZU5Z6ZKK7"]),
            paidCert("F", days: -5), paidCert("0", days: 900, valid: false), paidCert("1", days: 900, ous: ["OTHERTEAM1"]),
            paidCert("B", days: 300),
        ]
        let refs = CertCheck.paidCandidates(certs, now: testNow).map { $0.reference.first! }
        #expect(refs == ["B", "C", "A"])
    }

    @Test("real fixtures: only the paid one")
    func fixtures() throws {
        let all = try [TestCerts.paid, TestCerts.free, TestCerts.other, TestCerts.multi, TestCerts.noou, TestCerts.expired]
            .map { try keychainCert($0) }
        let paid = CertCheck.paidCandidates(all, now: testNow)
        #expect(paid.count == 1)
        #expect(paid.first?.reference == (try keychainCert(TestCerts.paid)).reference)
    }
}
