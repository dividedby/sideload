import Foundation
import Security
import Testing

@testable import SideloadCore

// Opt-in: SIDELOAD_REAL_KEYCHAIN=1 swift test --filter RealKeychain
//
// Drives the Security.framework implementations against a THROWAWAY keychain file in a fresh temp directory,
// holding a throwaway self-signed identity (made with /usr/bin/openssl at run time; nothing is committed).
// It never reads, exports, modifies or adds to the login keychain or any other keychain, and never changes the
// default keychain. The user keychain search list is recorded first and verified (restored if needed) at the end.
//
// It MAY SHOW A KEYCHAIN DIALOG (design section 6, spike): during the spike, changing the new keychain's
// settings (`SecKeychainSetSettings`) asked for its password, which nobody has; this test therefore never calls
// it. Export and import ran without a dialog. Answering Deny or Cancel is accepted: the test then ends cleanly
// (the result is `.denied`). Each risky step runs under a timeout so an unanswered dialog cannot hang the run.
// Default test runs skip all of this and touch no real keychain.

private let realKeychainEnabled = ProcessInfo.processInfo.environment["SIDELOAD_REAL_KEYCHAIN"] == "1"

private func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The throwaway keychain. Uses the deprecated `SecKeychain` file API, which is the only way to create a keychain
/// file; the attribute keeps the deprecation warnings out of the build.
@available(macOS, deprecated: 10.10, message: "SecKeychain is deprecated; this is a test helper for a throwaway keychain")
private final class ThrowawayKeychain {
    static let passphrase = "throwaway-keychain-password"
    static let bundleSecret = "throwaway-p12-password"

    let directory: String
    let keychain: SecKeychain
    let searchListBefore: String
    private(set) var cleanedUp = false

    init() throws {
        searchListBefore = runTool("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        let base = NSTemporaryDirectory() + "sideload-real-keychain-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        directory = base
        var created: SecKeychain?
        let status = SecKeychainCreate(
            base + "/throwaway.keychain", UInt32(Self.passphrase.utf8.count), Self.passphrase, false, nil, &created)
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(atPath: base)
            throw KeychainFailure.status(status)
        }
        keychain = created
        // Created unlocked (spike); unlock again in process with the throwaway password, never interactively.
        _ = SecKeychainUnlock(created, UInt32(Self.passphrase.utf8.count), Self.passphrase, true)
    }

    var target: KeychainTarget { KeychainTarget(keychain: keychain) }

    /// Generates a self-signed cert and key with openssl and imports them into the throwaway keychain only.
    /// Returns false when openssl is missing.
    func addIdentity(ou: String) throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return false }
        let key = directory + "/k.pem", cert = directory + "/c.pem", bundle = directory + "/in.p12"
        let req = runTool("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
            "-subj", "/CN=Apple Development: Throwaway/OU=\(ou)", "-days", "2",
        ])
        let pack = runTool("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", bundle, "-passout", "pass:" + Self.bundleSecret,
        ])
        guard req.status == 0, pack.status == 0 else { throw KeychainFailure.status(errSecInternalError) }
        let data = try Data(contentsOf: URL(fileURLWithPath: bundle))
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [
            kSecImportExportPassphrase as String: Self.bundleSecret,
            kSecImportExportKeychain as String: keychain,
        ] as CFDictionary, &items)
        guard status == errSecSuccess else { throw KeychainFailure.status(status) }
        return true
    }

    func count(_ itemClass: CFString) -> Int {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: itemClass, kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true,
        ] as CFDictionary, &result)
        return status == errSecSuccess ? ((result as? [Any])?.count ?? 0) : 0
    }

    /// Deletes the keychain and its directory, then makes sure the user search list is exactly as it was.
    /// Returns whether the list is identical.
    @discardableResult
    func cleanUp() -> Bool {
        guard !cleanedUp else { return true }
        cleanedUp = true
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(atPath: directory)
        var now = runTool("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        if now != searchListBefore {
            let paths = searchListBefore.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            _ = runTool("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + paths)
            now = runTool("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        }
        return now == searchListBefore
    }
}

@Suite("real keychain (throwaway keychain only)", .enabled(if: realKeychainEnabled))
struct RealKeychainTests {
    @Test("export, verify and store against a throwaway keychain")
    @available(macOS, deprecated: 10.10)
    func roundTrip() async throws {
        let keychain = try ThrowawayKeychain()
        defer { #expect(keychain.cleanUp(), "the user keychain search list must be identical afterwards") }

        // The cert carries the paid OU: it is a fake in a keychain nothing else searches.
        guard try keychain.addIdentity(ou: Team.id) else { return }
        #expect(keychain.count(kSecClassIdentity) == 1)

        let exporter = SecurityIdentityExporter(target: keychain.target)
        let verifier = SecurityP12Verifier(target: keychain.target)
        let store = SecurityKeychainSecretStore(target: keychain.target)

        // The password item: add once, read back, never overwritten.
        let password = PasswordGenerator.generate()
        let initial = try store.readPassword()
        let empty = initial == nil
        #expect(empty)
        try store.addPassword(password)
        // Booleans only: a failing expectation prints its operands, and the password must never be one.
        let readBack = try store.readPassword()
        let matches = readBack == password
        #expect(matches)
        #expect(throws: KeychainFailure.passwordStoreFailed(errSecDuplicateItem)) { try store.addPassword("other") }
        let readAgain = try store.readPassword()
        let stillMatches = readAgain == password
        #expect(stillMatches)

        // The reference of the one identity in the throwaway keychain.
        var found: CFTypeRef?
        let lookup = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity, kSecMatchSearchList as String: [keychain.keychain],
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &found)
        #expect(lookup == errSecSuccess)
        let identity = try #require(found) as! SecIdentity
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        let reference = CertReference(der: SecCertificateCopyData(try #require(certificate)) as Data)

        // Export under the prompt guard. Deny or Cancel is an accepted outcome.
        let p12: Data
        do {
            p12 = try await PromptGuard.run(timeout: .seconds(60)) {
                try exporter.exportP12(reference: reference, password: password)
            }
        } catch KeychainFailure.denied {
            return
        } catch KeychainFailure.promptTimeout {
            return
        }
        #expect(!p12.isEmpty)
        #expect(Pkcs12Inspector.inspect(p12).label != "unknown")

        // A reference that is not there is not found.
        #expect(throws: KeychainFailure.notFound) {
            _ = try exporter.exportP12(reference: try #require(CertReference(String(repeating: "0", count: 40))), password: password)
        }

        // Verify in memory: the right identity, nothing left behind, and a wrong password refused.
        let before = (keychain.count(kSecClassIdentity), keychain.count(kSecClassKey), keychain.count(kSecClassCertificate))
        #expect(try verifier.identityReferences(p12: p12, password: password) == [reference])
        #expect(throws: KeychainFailure.wrongPassword) {
            _ = try verifier.identityReferences(p12: p12, password: "not-the-password")
        }
        let after = (keychain.count(kSecClassIdentity), keychain.count(kSecClassKey), keychain.count(kSecClassCertificate))
        #expect(before == after, "the in-memory import must leave nothing in the keychain")
    }
}
