import Foundation
import Security

/// Exports one signing identity as a password-protected PKCS#12 (design section 6). The password travels in
/// process memory only: never argv, never a log. Exporting a private key makes the keychain show an access
/// dialog, so callers run it under `PromptGuard`.
public protocol IdentityExporter: Sendable {
    /// Throws `KeychainFailure` only: `.notFound` (no such identity), `.notPaidTeam` (never exported),
    /// `.denied`, `.unavailable` or `.status`.
    func exportP12(reference: CertReference, password: String) throws -> Data
}

/// The default in `Services`: a test that forgets to inject an exporter can never reach the real keychain.
public struct UnavailableIdentityExporter: IdentityExporter {
    public init() {}

    public func exportP12(reference: CertReference, password: String) throws -> Data {
        throw KeychainFailure.unavailable
    }
}

/// Picks the identity to export. Pure, so the paid-team rule is testable without a keychain.
enum IdentitySelection {
    /// The candidate whose certificate reference matches, provided it is the paid team's: first OU is the paid
    /// team and the free team's OU appears nowhere in the subject. The check is repeated here on purpose, so a
    /// bug upstream can never export another team's key.
    static func pick<Item>(_ candidates: [(certificate: KeychainCertificate, item: Item)], reference: CertReference) throws
        -> Item
    {
        guard let match = candidates.first(where: { $0.certificate.reference == reference.hex })
        else { throw KeychainFailure.notFound }
        guard match.certificate.info.isPaidTeam else { throw KeychainFailure.notPaidTeam }
        return match.item
    }
}

/// `IdentityExporter` over `SecItemExport(kSecFormatPKCS12)` with the passphrase in
/// `SecItemImportExportKeyParameters`. Lists identity references (no key access), matches the certificate's
/// SHA-1, re-checks the paid team, and only then asks for the key.
public struct SecurityIdentityExporter: IdentityExporter {
    /// Search only this keychain instead of the user's search list. Tests use it for a throwaway keychain.
    let target: KeychainTarget?

    public init() {
        self.target = nil
    }

    init(target: KeychainTarget?) {
        self.target = target
    }

    public func exportP12(reference: CertReference, password: String) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        KeychainTarget.scope(&query, to: target)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainFailure.notFound }
        guard status == errSecSuccess else { throw KeychainFailure.from(status: status) }
        let identities = (result as? [SecIdentity]) ?? []

        var candidates: [(certificate: KeychainCertificate, item: SecIdentity)] = []
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                let read = CertificateReader.read(certificate: certificate)
            else { continue }
            candidates.append((read, identity))
        }
        let identity = try IdentitySelection.pick(candidates, reference: reference)

        // The parameters hold the passphrase unretained: keep the CFString alive across the call.
        let passphrase = password as CFString
        var parameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION), flags: [],
            passphrase: Unmanaged<CFTypeRef>.passUnretained(passphrase),
            alertTitle: nil, alertPrompt: nil, accessRef: nil, keyUsage: nil, keyAttributes: nil)
        var exported: CFData?
        let exportStatus = withExtendedLifetime(passphrase) {
            SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
        }
        guard exportStatus == errSecSuccess else { throw KeychainFailure.from(status: exportStatus) }
        guard let exported else { throw KeychainFailure.status(errSecInternalError) }
        return exported as Data
    }
}
