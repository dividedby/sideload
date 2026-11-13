import Foundation
import Testing

@testable import SideloadCore

// The keychain layer that remains: certificate references and source hygiene. Nothing here touches a keychain.

@Suite("certificate reference")
struct CertReferenceTests {
    @Test func acceptsFortyHexDigitsAndNormalisesCase() throws {
        let lower = try #require(CertReference("0123456789abcdef0123456789abcdef01234567"))
        #expect(lower.hex == "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(lower == CertReference("0123456789ABCDEF0123456789ABCDEF01234567"))
    }

    @Test func rejectsAnythingElse() {
        #expect(CertReference("") == nil)
        #expect(CertReference(String(repeating: "A", count: 39)) == nil)
        #expect(CertReference(String(repeating: "A", count: 41)) == nil)
        #expect(CertReference(String(repeating: "G", count: 40)) == nil)
        #expect(CertReference(String(repeating: "A", count: 39) + " ") == nil)
        #expect(CertReference(String(repeating: "\u{FF21}", count: 40)) == nil)  // full-width A
    }

    @Test func derHashMatchesTheCertificateReader() throws {
        let der = try #require(
            Data(base64Encoded: TestCerts.paid, options: .ignoreUnknownCharacters))
        let read = try #require(CertificateReader.read(der: der))
        #expect(CertReference(der: der).hex == read.reference)
    }
}

@Suite("keychain source hygiene")
struct KeychainSourceHygieneTests {
    private func sources(under sub: String = "") throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SideloadCore" + sub)
        let walker = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!files.isEmpty)
        return files
    }

    @Test("nothing updates or deletes a keychain item, or exports through the security tool")
    func noMutationAndNoToolExport() throws {
        let banned = [
            "SecItemUpdate", "SecItemDelete", "SecKeychainItemDelete", "SecKeychainDelete",
            "SecKeychainCreate",
        ]
        for (path, text) in try sources() {
            for word in banned { #expect(!text.contains(word), "\(path) mentions \(word)") }
        }
        for (path, text) in try sources(under: "/Keychain") {
            #expect(!text.contains("/usr/bin/security"), "\(path) shells out to security")
            #expect(!text.contains("Process("), "\(path) spawns a process")
        }
    }

    @Test("nothing exports or imports a private key")
    func noKeyExportOrImport() throws {
        for (path, text) in try sources() {
            #expect(
                !text.contains("SecItemExport") && !text.contains("SecPKCS12Import"), "\(path)")
        }
    }
}
