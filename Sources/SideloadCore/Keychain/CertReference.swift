import Foundation

/// A certificate's join key: the SHA-1 of its DER as 40 upper-case hex digits (the same value as
/// `KeychainCertificate.reference`). Validated on creation so a malformed string never reaches a keychain
/// query. Not a secret, but never printed in full (output shows the first 8 digits).
public struct CertReference: Sendable, Hashable, CustomStringConvertible {
    public let hex: String

    /// Nil unless `text` is exactly 40 hex digits (either case).
    public init?(_ text: String) {
        guard text.utf8.count == 40, text.utf8.allSatisfy(Self.isHexDigit) else { return nil }
        self.hex = text.uppercased()
    }

    /// The reference of a certificate's DER bytes.
    init(der: Data) {
        self.hex = CertificateReader.sha1Hex(der)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    public var description: String { hex }
}
