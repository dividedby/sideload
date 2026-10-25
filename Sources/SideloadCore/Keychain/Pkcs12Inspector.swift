import Foundation

/// The password-based encryption schemes found in a PKCS#12 file.
public struct Pkcs12Encryption: Sendable, Equatable {
    public enum Algorithm: String, Sendable, CaseIterable {
        /// PBES2 (PBKDF2 with an AES or similar cipher): what OpenSSL 3 reads without its legacy provider.
        case pbes2
        /// pbeWithSHAAnd3-KeyTripleDES-CBC.
        case pkcs12ThreeDES = "pkcs12-3des"
        /// pbeWithSHAAnd40BitRC2-CBC.
        case pkcs12RC2_40 = "pkcs12-rc2-40"

        /// Needs the OpenSSL 3 legacy provider (RC2) or is a pre-PBES2 scheme: unverified on Feather.
        var isLegacy: Bool { self != .pbes2 }

        /// 1.2.840.113549.1: the RSA Data Security arc (`iso.member-body.us.rsadsi.pkcs`) every scheme here sits under.
        private static let pkcsArc: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01]

        /// DER of the OBJECT IDENTIFIER, tag and length included.
        fileprivate var der: [UInt8] {
            let tail: [UInt8]
            switch self {
            case .pbes2: tail = [0x05, 0x0D]
            case .pkcs12ThreeDES: tail = [0x0C, 0x01, 0x03]
            case .pkcs12RC2_40: tail = [0x0C, 0x01, 0x06]
            }
            let body = Self.pkcsArc + tail
            return [0x06, UInt8(body.count)] + body
        }
    }

    /// Every scheme found, in `Algorithm.allCases` order.
    public var algorithms: [Algorithm]

    public init(algorithms: [Algorithm]) {
        self.algorithms = algorithms
    }

    /// Any scheme other than PBES2 is present.
    public var isLegacy: Bool { algorithms.contains { $0.isLegacy } }

    /// The ledger value: the schemes joined with `+`, or `unknown` when none was recognised.
    public var label: String {
        algorithms.isEmpty ? "unknown" : algorithms.map(\.rawValue).joined(separator: "+")
    }
}

/// Byte-searches a PKCS#12 file for the known encryption OIDs. It does not parse the structure and never
/// decrypts anything: the OIDs of the bag and key encryption are in the clear.
public enum Pkcs12Inspector {
    public static func inspect(_ p12: Data) -> Pkcs12Encryption {
        let bytes = [UInt8](p12)
        return Pkcs12Encryption(
            algorithms: Pkcs12Encryption.Algorithm.allCases.filter { contains(bytes, $0.der) })
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<start + needle.count].elementsEqual(needle) { return true }
        }
        return false
    }
}
