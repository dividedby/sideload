import Foundation
import Security
import Synchronization

@testable import SideloadCore

/// Fakes for the private-key and password layer (design sections 6 and 13). None touches a keychain.

final class FakeIdentityExporter: IdentityExporter {
    struct Call: Equatable {
        var reference: CertReference
        var password: String
    }

    private let outcome: Result<Data, KeychainFailure>
    private let recorded = Mutex<[Call]>([])
    /// Runs inside the call, so a test can check ordering against other fakes.
    private let onCall: (@Sendable () -> Void)?

    init(_ outcome: Result<Data, KeychainFailure> = .success(Data("fake-p12".utf8)), onCall: (@Sendable () -> Void)? = nil) {
        self.outcome = outcome
        self.onCall = onCall
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func exportP12(reference: CertReference, password: String) throws -> Data {
        recorded.withLock { $0.append(Call(reference: reference, password: password)) }
        onCall?()
        return try outcome.get()
    }
}

final class FakeSecretStore: SecretStore {
    enum Event: Equatable {
        case read
        case add(String)
    }

    private let state: Mutex<(password: String?, events: [Event])>
    private let failure: KeychainFailure?

    init(password: String? = nil, failure: KeychainFailure? = nil) {
        self.state = Mutex((password, []))
        self.failure = failure
    }

    var events: [Event] { state.withLock { $0.events } }
    var stored: String? { state.withLock { $0.password } }

    func readPassword() throws -> String? {
        try state.withLock { s in
            s.events.append(.read)
            if let failure { throw failure }
            return s.password
        }
    }

    func addPassword(_ password: String) throws {
        try state.withLock { s in
            s.events.append(.add(password))
            if let failure { throw failure }
            if s.password != nil { throw KeychainFailure.passwordStoreFailed(errSecDuplicateItem) }
            s.password = password
        }
    }
}

/// Opens a p12 by comparing the password with the one it was told is right.
final class FakeP12Verifier: P12Verifier {
    private let references: [CertReference]
    private let expectedPassword: String?
    private let recorded = Mutex(0)

    init(references: [CertReference], expectedPassword: String? = nil) {
        self.references = references
        self.expectedPassword = expectedPassword
    }

    var callCount: Int { recorded.withLock { $0 } }

    func identityReferences(p12: Data, password: String) throws -> [CertReference] {
        recorded.withLock { $0 += 1 }
        if let expectedPassword, expectedPassword != password { throw KeychainFailure.wrongPassword }
        return references
    }
}
