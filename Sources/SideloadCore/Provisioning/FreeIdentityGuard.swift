import Foundation

/// Crash-safe identity check for every free-team command that lets Xcode run (design section 18). A command
/// writes `freeProvisionInFlight` (the free-OU identity set, by 8-hex fingerprint) before the build and clears it
/// in the same ledger write that records the after-comparison. If the process dies in between (a signal, a crash),
/// the marker survives, and the next command calls `settleInFlight` before it does anything else, so a certificate
/// Xcode created in the dead run can never be absorbed into a later "before" snapshot.
public enum FreeIdentityGuard {
    public struct Change: Sendable, Equatable {
        public let addedFp8: [String]
        public let removedFp8: [String]

        public var changed: Bool { !addedFp8.isEmpty || !removedFp8.isEmpty }
    }

    /// Sorted, de-duplicated 8-hex fingerprints of every free-OU identity (valid or not).
    public static func fp8s(_ certificates: [KeychainCertificate]) -> [String] {
        Array(Set(FreeIdentitySnapshot(certificates).sha1s.map(LedgerSync.fp8))).sorted()
    }

    public static func diff(before: [String], after: [String]) -> Change {
        Change(
            addedFp8: Set(after).subtracting(before).sorted(), removedFp8: Set(before).subtracting(after).sorted())
    }

    /// Settles a marker left by a run that never recorded its after-comparison. With no marker it does nothing
    /// (a read, no write). With one it compares the current free-OU set with the recorded one, clears the marker
    /// and, for any difference, records `freeSuspended` (`FREE_CERT_CHANGED`) in the same ledger write; it returns
    /// the change. An unchanged set returns nil. A failed ledger write throws, leaving the marker in place.
    /// Call it under `.op.lock`, after a successful keychain read and before anything else.
    public static func settleInFlight(
        ledgerStore: LedgerStore, current: [KeychainCertificate], now: Date
    ) async throws -> Change? {
        guard try ledgerStore.load().freeProvisionInFlight != nil else { return nil }
        let after = fp8s(current)
        return try await ledgerStore.update { ledger -> Change? in
            guard let marker = ledger.freeProvisionInFlight else { return nil }
            let change = diff(before: marker.beforeFp8, after: after)
            ledger.freeProvisionInFlight = nil
            guard change.changed else { return nil }
            ledger.freeSuspended = LedgerFreeSuspension(
                code: "FREE_CERT_CHANGED", at: now, addedFp8: change.addedFp8, removedFp8: change.removedFp8)
            return change
        }
    }
}
