import Foundation
import Testing

@testable import SideloadCore

@Suite("Expiry items")
struct ExpiryItemsTests {
    private func level(days: Double, extra seconds: Double = 0) -> (Int, ExpiryItem.Level) {
        let r = ExpiryItems.level(notAfter: testNow.addingTimeInterval(days * 86_400 + seconds), now: testNow)
        return (r.daysLeft, r.level)
    }

    @Test("levels at the 60, 14 and 0 day boundaries", arguments: [
        (90.0, 90, ExpiryItem.Level.ok), (61.0, 61, .ok), (60.0, 60, .warn), (15.0, 15, .warn),
        (14.0, 14, .critical), (1.0, 1, .critical), (0.0, 0, .expired), (-1.0, -1, .expired),
    ])
    func boundaries(days: Double, left: Int, want: ExpiryItem.Level) {
        let r = level(days: days)
        #expect(r.0 == left && r.1 == want)
    }

    @Test("a partial day rounds down; time left today is critical, not expired")
    func partialDays() {
        #expect(level(days: 60, extra: -1).0 == 59)
        #expect(level(days: 60, extra: -1).1 == .warn)
        #expect(level(days: 60, extra: 1) == (60, .warn))
        #expect(level(days: 61, extra: -1) == (60, .warn))
        #expect(level(days: 0, extra: 3600) == (0, .critical))
        #expect(level(days: 0, extra: -1) == (-1, .expired))
    }

    @Test("only present items, soonest first, named without full IDs")
    func compute() {
        let uuid = UUID().uuidString
        func cert(_ fp: String, _ days: Double, present: Bool = true) -> LedgerCertificate {
            LedgerCertificate(
                fp8: fp, team: Team.id, notBefore: nil, notAfter: daysFromNow(days), firstSeen: testNow, lastSeen: testNow,
                valid: true, present: present)
        }
        let profile = LedgerProfile(
            uuid: uuid, team: Team.id, applicationId: nil, wildcard: true, created: nil, expires: daysFromNow(10),
            deviceCount: 1, deviceTails: [], certFp8s: [], source: "xcode-managed", firstSeen: testNow, lastSeen: testNow,
            present: true)
        var stale = profile
        stale.uuid = UUID().uuidString
        stale.present = false
        let ledger = Ledger(
            certificates: [cert("aaaaaaaa", 300), cert("bbbbbbbb", 40), cert("cccccccc", -2), cert("dddddddd", 5, present: false)],
            profiles: [profile, stale])

        let items = ExpiryItems.compute(ledger, now: testNow)
        #expect(items.map(\.name) == ["cert cccccccc", "profile …" + uuid.suffix(4), "cert bbbbbbbb", "cert aaaaaaaa"])
        #expect(items.map(\.level) == [.expired, .critical, .warn, .ok])
        #expect(items.map(\.kind) == [.certificate, .profile, .certificate, .certificate])
        #expect(items.map(\.daysLeft) == [-2, 10, 40, 300])
        #expect(!items.contains { $0.name.contains(uuid) })
        #expect(ExpiryItems.compute(Ledger(), now: testNow).isEmpty)
    }
}
