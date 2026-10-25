import Foundation
import Security

/// Approximates `security find-identity -v -p codesigning`: a certificate counts only if a trust evaluation with
/// the Apple code-signing policy succeeds now (chain to a trusted root, unexpired, code-signing usage).
/// Synchronous, non-interactive and offline: network fetch is disabled, so revocation relies on the local cache
/// and can lag `find-identity -v` (design section 6).
public enum CodeSigningTrust {
    public static func isValid(_ certificate: SecCertificate, at date: Date = Date()) -> Bool {
        guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        // Fail closed: never evaluate with the network possibly enabled.
        guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        SecTrustSetVerifyDate(trust, date as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }

    public static func isValid(der: Data, at date: Date = Date()) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        return isValid(certificate, at: date)
    }
}
