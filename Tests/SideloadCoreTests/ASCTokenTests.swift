import CryptoKit
import Foundation
import Testing

@testable import SideloadCore

@Suite("portal API token")
struct ASCTokenTests {
    private func b64urlDecode(_ s: String) throws -> Data {
        #expect(!s.contains("=") && !s.contains("+") && !s.contains("/"), "base64url without padding")
        var padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return try #require(Data(base64Encoded: padded))
    }

    private func credentials(_ key: P256.Signing.PrivateKey) -> ASCCredentials {
        ASCCredentials(
            keyId: testKeyId, issuerId: testIssuerId, role: nil, privateKey: ASCSecret(key.pemRepresentation))
    }

    @Test("an ES256 JWT with the documented header and claims, signed r||s")
    func token() throws {
        let key = P256.Signing.PrivateKey()
        let secret = try ASCToken.make(credentials(key), now: testNow)
        let jwt = secret.reveal { $0 }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 3)

        let header = try decodeJSON(String(decoding: try b64urlDecode(parts[0]), as: UTF8.self))
        #expect(header == ["alg": "ES256", "kid": .string(testKeyId), "typ": "JWT"])

        let claims = try decodeJSON(String(decoding: try b64urlDecode(parts[1]), as: UTF8.self))
        let iat = Int(testNow.timeIntervalSince1970)
        #expect(
            claims == ["iss": .string(testIssuerId), "iat": .number(Double(iat)), "exp": .number(Double(iat + 600)), "aud": "appstoreconnect-v1"])
        #expect(claims["scope"] == nil, "no scope claim")

        let signature = try b64urlDecode(parts[2])
        #expect(signature.count == 64, "raw r||s, not DER")
        let verified = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        #expect(key.publicKey.isValidSignature(verified, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test("a signature from another key does not verify")
    func wrongKey() throws {
        let jwt = try ASCToken.make(credentials(P256.Signing.PrivateKey()), now: testNow).reveal { $0 }
        let parts = jwt.split(separator: ".").map(String.init)
        let other = P256.Signing.PrivateKey().publicKey
        var padded = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: padded)))
        #expect(!other.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test("the token prints as <redacted>")
    func opaque() throws {
        let secret = try ASCToken.make(credentials(P256.Signing.PrivateKey()), now: testNow)
        let jwt = secret.reveal { $0 }
        #expect("\(secret)" == "<redacted>")
        #expect(!String(reflecting: secret).contains(jwt))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains(jwt))
        let request = HTTPRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/devices")!, bearer: secret)
        #expect(!String(describing: request).contains(jwt))
        #expect(!String(reflecting: request).contains(jwt))
    }

    @Test("an unusable key is ASC_KEY_INVALID without the key text")
    func invalidKey() {
        let creds = ASCCredentials(keyId: testKeyId, issuerId: testIssuerId, role: nil, privateKey: ASCSecret("ECHOMARKER"))
        do {
            _ = try ASCToken.make(creds, now: testNow)
            Issue.record("minted a token from garbage")
        } catch let error as SideloadError {
            #expect(error.code == "ASC_KEY_INVALID")
            #expect(!error.message.contains("ECHOMARKER") && !(error.fix ?? "").contains("ECHOMARKER"))
        } catch {
            Issue.record("unexpected error")
        }
    }

    @Test("the redactor masks a JWT and a PEM private key, also unterminated")
    func redactor() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try ASCToken.make(credentials(key), now: testNow).reveal { $0 }
        let pem = key.pemRepresentation
        #expect(Redactor.redactPatterns("Authorization: Bearer \(jwt) end") == "Authorization: Bearer <jwt> end")
        #expect(Redactor.redactPatterns("key:\n\(pem)\nafter") == "key:\n<private key>\nafter")
        let cut = String(pem.dropLast(40))
        let masked = Redactor.redactPatterns("x \(cut)")
        #expect(masked == "x <private key>")
        let body = try #require(pem.split(separator: "\n").dropFirst().first.map(String.init))
        let rendered = try Output.render(.result("x", ["jwt": .string(jwt), "pem": .string(pem), "nested": ["k": .string("a \(jwt) b")]]))
        #expect(!rendered.contains(jwt) && !rendered.contains(body))
        #expect(rendered.contains("<jwt>") && rendered.contains("<private key>"))
        #expect(Redactor.redactPatterns("plain text, a.b.c and eyJ alone") == "plain text, a.b.c and eyJ alone")
    }
}
