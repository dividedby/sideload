import CryptoKit
import Foundation

/// The App Store Connect API bearer token: an ES256 JWT, valid for 10 minutes (Apple's limit is 20), minted
/// once per run. No `scope` claim. The signature is the raw r||s form JWS requires, not DER.
public enum ASCToken {
    static let lifetime = 600
    static let audience = "appstoreconnect-v1"

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func make(_ credentials: ASCCredentials, now: Date) throws -> ASCSecret {
        let key: P256.Signing.PrivateKey
        do {
            key = try credentials.privateKey.reveal { try P256.Signing.PrivateKey(pemRepresentation: $0) }
        } catch {
            throw SideloadError(
                "ASC_KEY_INVALID", "The API key file is not a P-256 private key in PEM form.",
                fix: "Download the key again from App Store Connect and replace the file in $SIDELOAD_HOME/asc/.")
        }
        let iat = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Header: Encodable {
            let alg = "ES256"
            let kid: String
            let typ = "JWT"
        }
        struct Claims: Encodable {
            let iss: String
            let iat: Int
            let exp: Int
            let aud: String
        }
        do {
            let header = base64url(try encoder.encode(Header(kid: credentials.keyId)))
            let claims = base64url(
                try encoder.encode(Claims(iss: credentials.issuerId, iat: iat, exp: iat + lifetime, aud: audience)))
            let input = header + "." + claims
            let signature = try key.signature(for: Data(input.utf8))
            return ASCSecret(input + "." + base64url(signature.rawRepresentation))
        } catch {
            throw SideloadError(
                "ASC_KEY_INVALID", "Signing the API token failed.",
                fix: "Download the key again from App Store Connect and replace the file in $SIDELOAD_HOME/asc/.")
        }
    }
}
