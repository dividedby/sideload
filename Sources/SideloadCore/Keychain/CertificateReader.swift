import CryptoKit
import Foundation
import Security

/// Extracts OU, `notAfter` and the Apple Development flag from a certificate with
/// `SecCertificateCopyValues` (available and not deprecated in the macOS 27 SDK; see design.md section 6).
/// Runs in process: no `openssl`, no subprocess.
public enum CertificateReader {
    private static let oidCommonName = "2.5.4.3"
    private static let oidOrganizationalUnit = "2.5.4.11"

    public static func read(der: Data) -> KeychainCertificate? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return read(certificate: certificate)
    }

    public static func read(certificate: SecCertificate) -> KeychainCertificate? {
        let der = SecCertificateCopyData(certificate) as Data
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1ValidityNotBefore] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] else { return nil }

        var ous: [String] = []
        var commonName: String?
        if let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
            let parts = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
        {
            for part in parts {
                guard let label = part[kSecPropertyKeyLabel as String] as? String,
                    let value = part[kSecPropertyKeyValue as String] as? String
                else { continue }
                if label == oidOrganizationalUnit {
                    ous.append(value)
                } else if label == oidCommonName, commonName == nil {
                    commonName = value
                }
            }
        }

        func date(_ oid: CFString) -> Date? {
            guard let validity = values[oid as String] as? [String: Any] else { return nil }
            switch validity[kSecPropertyKeyValue as String] {
            case let date as Date: return date
            // CFAbsoluteTime: seconds since 2001-01-01 UTC.
            case let seconds as NSNumber: return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
            default: return nil
            }
        }
        let notAfter = date(kSecOIDX509V1ValidityNotAfter)
        let notBefore = date(kSecOIDX509V1ValidityNotBefore)

        let info = CertInfo(
            ous: ous, notAfter: notAfter, isAppleDevelopment: commonName?.hasPrefix("Apple Development") ?? false,
            notBefore: notBefore)
        return KeychainCertificate(reference: sha1Hex(der), info: info, commonName: commonName)
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
