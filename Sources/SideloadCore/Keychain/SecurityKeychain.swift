import Foundation
import LocalAuthentication
import Security

/// `KeychainClient` over Security.framework (design section 6). Lists identity references with
/// `SecItemCopyMatching` and reads each certificate; it never asks for a private key, so it does not prompt
/// while the login keychain is unlocked. The locked case is unverified (design sections 6 and 16).
public struct SecurityKeychain: KeychainClient {
    public init() {}

    public func developmentIdentities() throws -> [KeychainCertificate] {
        // Asks for no interaction. Data Protection items honour this; the legacy file-based login
        // keychain may ignore it, so a locked login keychain could still show an unlock dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecUseAuthenticationContext as String: context,
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainError("SecItemCopyMatching failed (OSStatus \(status))")
        }
        guard let identities = result as? [SecIdentity] else { return [] }

        var out: [KeychainCertificate] = []
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                var read = CertificateReader.read(certificate: certificate), read.info.isAppleDevelopment
            else { continue }
            read.isValidForCodeSigning = CodeSigningTrust.isValid(certificate)
            out.append(read)
        }
        return out
    }
}
