import Synchronization

@testable import SideloadCore

/// Replays a fixed identity list (or an error) and counts reads (design section 13).
final class FakeKeychain: KeychainClient {
    private let identities: [KeychainCertificate]
    private let failure: (any Error)?
    private let reads = Mutex(0)

    init(_ identities: [KeychainCertificate] = [], failure: (any Error)? = nil) {
        self.identities = identities
        self.failure = failure
    }

    var readCount: Int { reads.withLock { $0 } }

    func developmentIdentities() throws -> [KeychainCertificate] {
        reads.withLock { $0 += 1 }
        if let failure { throw failure }
        return identities
    }
}
