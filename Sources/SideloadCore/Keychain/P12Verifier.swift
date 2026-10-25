import Foundation
import Security

/// Opens an exported .p12 with its password to prove the file and the stored password agree (design section 6).
public protocol P12Verifier: Sendable {
    /// The reference of every identity in the file. Throws `KeychainFailure` only: `.wrongPassword`,
    /// `.unavailable`, or `.status` for a file that is not a PKCS#12.
    func identityReferences(p12: Data, password: String) throws -> [CertReference]
}

/// The default in `Services`: a test that forgets to inject a verifier can never reach the real keychain.
public struct UnavailableP12Verifier: P12Verifier {
    public init() {}

    public func identityReferences(p12: Data, password: String) throws -> [CertReference] {
        throw KeychainFailure.unavailable
    }
}

/// `P12Verifier` over `SecPKCS12Import` with `kSecImportToMemoryOnly`: nothing is written to any keychain
/// (spike result, design section 6).
public struct SecurityP12Verifier: P12Verifier {
    /// Spike only: also offer this keychain, which the import must ignore in memory-only mode. Tests use it to
    /// prove nothing lands there.
    let target: KeychainTarget?

    public init() {
        self.target = nil
    }

    init(target: KeychainTarget?) {
        self.target = target
    }

    public func identityReferences(p12: Data, password: String) throws -> [CertReference] {
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        KeychainTarget.offer(&options, to: target)
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw KeychainFailure.fromImport(status: status) }
        var references: [CertReference] = []
        for entry in (items as? [[String: Any]]) ?? [] {
            guard let value = entry[kSecImportItemIdentity as String] else { continue }
            guard CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
                throw KeychainFailure.status(errSecDecode)
            }
            let identity = unsafeDowncast(value as AnyObject, to: SecIdentity.self)
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
            references.append(CertReference(der: SecCertificateCopyData(certificate) as Data))
        }
        return references
    }
}
