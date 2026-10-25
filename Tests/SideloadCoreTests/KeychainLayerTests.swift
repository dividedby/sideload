import Foundation
import Security
import Synchronization
import Testing

@testable import SideloadCore

// The private-key and password layer (PR B): pure parts and fakes only. Nothing here touches a keychain.

/// Deterministic generator so the password tests do not depend on the system RNG.
private struct CountingRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A valid reference made of one repeated hex digit.
private func ref(_ digit: Character) -> CertReference {
    CertReference(String(repeating: digit, count: 40))!
}

@Suite("password generator")
struct PasswordGeneratorTests {
    @Test func shapeAndAlphabet() {
        var rng = CountingRNG(state: 1)
        let password = PasswordGenerator.generate(using: &rng)
        #expect(password.count == 24)
        let groups = password.split(separator: "-", omittingEmptySubsequences: false)
        #expect(groups.count == 5)
        #expect(groups.allSatisfy { $0.count == 4 })
        let allowed = Set(PasswordGenerator.alphabet)
        #expect(password.filter { $0 != "-" }.allSatisfy { allowed.contains($0) })
        #expect(PasswordGenerator.alphabet.count == 32)
        #expect(Set(PasswordGenerator.alphabet).isDisjoint(with: Set("ILOU")))
    }

    @Test func injectedGeneratorIsDeterministic() {
        var a = CountingRNG(state: 7)
        var b = CountingRNG(state: 7)
        var c = CountingRNG(state: 8)
        #expect(PasswordGenerator.generate(using: &a) == PasswordGenerator.generate(using: &b))
        var a2 = CountingRNG(state: 7)
        #expect(PasswordGenerator.generate(using: &a2) != PasswordGenerator.generate(using: &c))
    }

    @Test func systemGeneratorDiffers() {
        #expect(PasswordGenerator.generate() != PasswordGenerator.generate())
    }

    @Test func usesEveryAlphabetSymbolEventually() {
        var rng = CountingRNG(state: 3)
        var seen = Set<Character>()
        for _ in 0..<200 { seen.formUnion(PasswordGenerator.generate(using: &rng)) }
        seen.remove("-")
        #expect(seen == Set(PasswordGenerator.alphabet))
    }
}

@Suite("PKCS#12 inspector")
struct Pkcs12InspectorTests {
    private func blob(_ oidTail: [UInt8]) -> Data {
        let body: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01] + oidTail
        return Data([0x30, 0x82, 0x01, 0x00, 0xA0, 0xFF] + [0x06, UInt8(body.count)] + body + [0x04, 0x01, 0x00])
    }

    @Test func recognisesEachScheme() {
        let pbes2 = Pkcs12Inspector.inspect(blob([0x05, 0x0D]))
        #expect(pbes2.algorithms == [.pbes2])
        #expect(!pbes2.isLegacy)
        #expect(pbes2.label == "pbes2")

        let threeDES = Pkcs12Inspector.inspect(blob([0x0C, 0x01, 0x03]))
        #expect(threeDES.algorithms == [.pkcs12ThreeDES])
        #expect(threeDES.isLegacy)
        #expect(threeDES.label == "pkcs12-3des")

        let rc2 = Pkcs12Inspector.inspect(blob([0x0C, 0x01, 0x06]))
        #expect(rc2.algorithms == [.pkcs12RC2_40])
        #expect(rc2.isLegacy)
    }

    @Test func mixedAndUnknown() {
        let mixed = Pkcs12Inspector.inspect(blob([0x0C, 0x01, 0x03]) + blob([0x0C, 0x01, 0x06]))
        #expect(mixed.label == "pkcs12-3des+pkcs12-rc2-40")
        #expect(mixed.isLegacy)

        let pbes2AndLegacy = Pkcs12Inspector.inspect(blob([0x05, 0x0D]) + blob([0x0C, 0x01, 0x06]))
        #expect(pbes2AndLegacy.isLegacy)

        let unknown = Pkcs12Inspector.inspect(blob([0x01, 0x01]))
        #expect(unknown.algorithms.isEmpty)
        #expect(unknown.label == "unknown")
        #expect(!unknown.isLegacy)
        #expect(Pkcs12Inspector.inspect(Data()).label == "unknown")
        #expect(Pkcs12Inspector.inspect(Data([0x06])).label == "unknown")
    }

    @Test func oidMustBeAWholeObjectIdentifier() {
        // The OID body without its tag and length is not a match.
        let bare = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D])
        #expect(Pkcs12Inspector.inspect(bare).algorithms.isEmpty)
    }
}

@Suite("prompt guard")
struct PromptGuardTests {
    @Test func returnsTheValue() async throws {
        let value = try await PromptGuard.run(timeout: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func propagatesTheError() async {
        await #expect(throws: KeychainFailure.denied) {
            try await PromptGuard.run(timeout: .seconds(5)) { throw KeychainFailure.denied }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func blockedCallTimesOut() async {
        let release = DispatchSemaphore(value: 0)
        // The upper bound is the time limit, not a wall-clock assert: under a loaded parallel run the timer and the
        // resume can stall for seconds. Returning at all means the guard gave up while the body was still blocked.
        await #expect(throws: KeychainFailure.promptTimeout) {
            try await PromptGuard.run(timeout: .milliseconds(150)) { () -> Int in
                release.wait()
                return 1
            }
        }
        release.signal()  // let the abandoned thread finish
    }

    @Test func lateResultAfterTimeoutIsIgnored() async throws {
        let release = DispatchSemaphore(value: 0)
        await #expect(throws: KeychainFailure.promptTimeout) {
            try await PromptGuard.run(timeout: .milliseconds(100)) { () -> Int in
                release.wait()
                return 1
            }
        }
        release.signal()
        try await Task.sleep(for: .milliseconds(100))  // a second resume would trap
    }
}

@Suite("keychain failure mapping")
struct KeychainFailureTests {
    @Test func ownerRefusalsAreDenied() {
        #expect(KeychainFailure.from(status: errSecUserCanceled) == .denied)
        #expect(KeychainFailure.from(status: errSecAuthFailed) == .denied)
        #expect(KeychainFailure.from(status: errSecInteractionNotAllowed) == .denied)
    }

    @Test func wrongPasswordIsNotADenial() {
        // SecPKCS12Import: a wrong password is its own failure, never a refused dialog.
        #expect(KeychainFailure.fromImport(status: errSecAuthFailed) == .wrongPassword)
        #expect(KeychainFailure.fromImport(status: errSecPkcs12VerifyFailure) == .wrongPassword)
        #expect(KeychainFailure.fromImport(status: errSecUserCanceled) == .denied)
        #expect(KeychainFailure.fromImport(status: errSecInteractionNotAllowed) == .denied)
        #expect(KeychainFailure.fromImport(status: errSecDecode) == .status(errSecDecode))
        // Everywhere else errSecAuthFailed stays a denial.
        #expect(KeychainFailure.from(status: errSecAuthFailed) == .denied)
    }

    @Test func eachFailureHasItsOwnCodeMessageAndFix() {
        let all: [KeychainFailure] = [
            .denied, .promptTimeout, .notFound, .notPaidTeam, .wrongPassword, .passwordStoreFailed(-1),
            .passwordUnreadable(-1), .unavailable, .status(-1),
        ]
        #expect(Set(all.map { $0.report.code }).count == all.count)
        #expect(all.allSatisfy { !$0.report.message.isEmpty && !$0.report.fix.isEmpty })
        let codes: [(KeychainFailure, String)] = [
            (.denied, "KEYCHAIN_DENIED"), (.promptTimeout, "KEYCHAIN_PROMPT_TIMEOUT"), (.notFound, "CERT_NOT_FOUND"),
            (.notPaidTeam, "IDENTITY_NOT_PAID_TEAM"), (.wrongPassword, "P12_VERIFY_FAILED"),
            (.passwordStoreFailed(-1), "PASSWORD_STORE_FAILED"), (.passwordUnreadable(-1), "PASSWORD_UNREADABLE"),
            (.unavailable, "KEYCHAIN_UNAVAILABLE"), (.status(-1), "KEYCHAIN_READ_FAILED"),
        ]
        for (failure, code) in codes {
            #expect(failure.report.code == code)
            #expect(failure.sideloadError.code == code)
            #expect(failure.sideloadError.fix == failure.report.fix)
        }
    }

    @Test func passwordItemFailuresHaveTheirOwnCodes() {
        // Owner refusals stay denials; everything else is the item's own code.
        #expect(KeychainFailure.fromPasswordAdd(status: errSecDuplicateItem) == .passwordStoreFailed(errSecDuplicateItem))
        #expect(KeychainFailure.fromPasswordAdd(status: errSecAuthFailed) == .denied)
        #expect(KeychainFailure.fromPasswordAdd(status: errSecUserCanceled) == .denied)
        #expect(KeychainFailure.fromPasswordRead(status: errSecDecode) == .passwordUnreadable(errSecDecode))
        #expect(KeychainFailure.fromPasswordRead(status: errSecInteractionNotAllowed) == .denied)
        #expect(KeychainFailure.fromPasswordAdd(status: errSecDuplicateItem).report.code == "PASSWORD_STORE_FAILED")
        #expect(KeychainFailure.fromPasswordRead(status: errSecDecode).report.code == "PASSWORD_UNREADABLE")
    }

    @Test func statusAppearsInTheMessageButNothingElse() {
        #expect(KeychainFailure.status(-25300).report.message.contains("-25300"))
    }

    @Test func otherStatuses() {
        #expect(KeychainFailure.from(status: errSecItemNotFound) == .notFound)
        #expect(KeychainFailure.from(status: errSecDuplicateItem) == .status(errSecDuplicateItem))
    }
}

@Suite("identity selection")
struct IdentitySelectionTests {
    private func candidate(_ digit: Character, ous: [String]) -> (certificate: KeychainCertificate, item: String) {
        let reference = ref(digit).hex
        return (
            KeychainCertificate(reference: reference, info: CertInfo(ous: ous), isValidForCodeSigning: true),
            "item-" + String(digit)
        )
    }

    @Test func picksThePaidIdentityByReference() throws {
        let pool = [candidate("A", ous: ["6ZU5Z6ZKK7"]), candidate("B", ous: ["7AGMPUPP64"])]
        #expect(try IdentitySelection.pick(pool, reference: ref("B")) == "item-B")
    }

    @Test func neverReturnsTheFreeTeamsKey() {
        let pool = [candidate("A", ous: ["6ZU5Z6ZKK7"]), candidate("B", ous: ["7AGMPUPP64", "6ZU5Z6ZKK7"])]
        #expect(throws: KeychainFailure.notPaidTeam) { try IdentitySelection.pick(pool, reference: ref("A")) }
        // The free OU anywhere in the subject disqualifies, even behind the paid OU.
        #expect(throws: KeychainFailure.notPaidTeam) { try IdentitySelection.pick(pool, reference: ref("B")) }
    }

    @Test func otherTeamsAndNoOUAreNotPaid() {
        let pool = [candidate("C", ous: ["TESTTEAM01"]), candidate("D", ous: [])]
        #expect(throws: KeychainFailure.notPaidTeam) { try IdentitySelection.pick(pool, reference: ref("C")) }
        #expect(throws: KeychainFailure.notPaidTeam) { try IdentitySelection.pick(pool, reference: ref("D")) }
    }

    @Test func unknownReferenceIsNotFound() {
        #expect(throws: KeychainFailure.notFound) {
            try IdentitySelection.pick([candidate("A", ous: ["7AGMPUPP64"])], reference: ref("F"))
        }
    }

    @Test func realCertificatesFromTheFixtures() throws {
        let paid = try keychainCert(TestCerts.paid)
        let free = try keychainCert(TestCerts.free)
        let pool = [(certificate: free, item: "free"), (certificate: paid, item: "paid")]
        let paidRef = try #require(CertReference(paid.reference))
        let freeRef = try #require(CertReference(free.reference))
        #expect(try IdentitySelection.pick(pool, reference: paidRef) == "paid")
        #expect(throws: KeychainFailure.notPaidTeam) { try IdentitySelection.pick(pool, reference: freeRef) }
    }
}

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
        let der = try #require(Data(base64Encoded: TestCerts.paid, options: .ignoreUnknownCharacters))
        let read = try #require(CertificateReader.read(der: der))
        #expect(CertReference(der: der).hex == read.reference)
    }
}

@Suite("keychain fakes and inert defaults")
struct KeychainFakeTests {
    @Test func inertDefaultsThrowKeychainUnavailable() throws {
        let services = Services(
            runner: FakeRunner(), fs: FakeFileSystem.free(gb: 1), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: Paths(home: "/nonexistent"))
        func code(_ body: () throws -> Void) -> String? {
            do { try body() } catch let error as KeychainFailure { return error.report.code } catch { return "other" }
            return nil
        }
        #expect(code { _ = try services.identityExporter.exportP12(reference: ref("A"), password: "x") } == "KEYCHAIN_UNAVAILABLE")
        #expect(code { _ = try services.secrets.readPassword() } == "KEYCHAIN_UNAVAILABLE")
        #expect(code { try services.secrets.addPassword("x") } == "KEYCHAIN_UNAVAILABLE")
        #expect(code { _ = try services.p12Verifier.identityReferences(p12: Data(), password: "x") } == "KEYCHAIN_UNAVAILABLE")
    }

    @Test func secretStoreFakeNeverOverwrites() throws {
        let store = FakeSecretStore()
        #expect(try store.readPassword() == nil)
        try store.addPassword("one")
        #expect(throws: KeychainFailure.passwordStoreFailed(errSecDuplicateItem)) { try store.addPassword("two") }
        #expect(try store.readPassword() == "one")
        #expect(store.events == [.read, .add("one"), .add("two"), .read])
    }

    @Test func exporterFakeRecordsCalls() throws {
        let exporter = FakeIdentityExporter()
        _ = try exporter.exportP12(reference: ref("A"), password: "pw")
        #expect(exporter.calls == [.init(reference: ref("A"), password: "pw")])
        let denied = FakeIdentityExporter(.failure(.denied))
        #expect(throws: KeychainFailure.denied) { _ = try denied.exportP12(reference: ref("A"), password: "pw") }
    }

    @Test func verifierFakeRejectsAWrongPassword() throws {
        let verifier = FakeP12Verifier(references: [ref("A")], expectedPassword: "right")
        #expect(try verifier.identityReferences(p12: Data(), password: "right") == [ref("A")])
        #expect(throws: KeychainFailure.wrongPassword) { _ = try verifier.identityReferences(p12: Data(), password: "wrong") }
    }

    @Test func passwordItemIdentity() {
        #expect(SecurityKeychainSecretStore.service == "io.github.dividedby.sideload")
        #expect(SecurityKeychainSecretStore.account == "p12")
    }
}

@Suite("keychain source hygiene")
struct KeychainSourceHygieneTests {
    private func sources(under sub: String = "") throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SideloadCore" + sub)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!files.isEmpty)
        return files
    }

    @Test("nothing updates or deletes a keychain item, or exports through the security tool")
    func noMutationAndNoToolExport() throws {
        let banned = ["SecItemUpdate", "SecItemDelete", "SecKeychainItemDelete", "SecKeychainDelete", "SecKeychainCreate"]
        for (path, text) in try sources() {
            for word in banned { #expect(!text.contains(word), "\(path) mentions \(word)") }
        }
        for (path, text) in try sources(under: "/Keychain") {
            #expect(!text.contains("/usr/bin/security"), "\(path) shells out to security")
            #expect(!text.contains("Process("), "\(path) spawns a process")
        }
    }

    @Test("the key export and import calls live in the Keychain folder only")
    func confined() throws {
        for (path, text) in try sources() where !path.contains("/Keychain/") {
            #expect(!text.contains("SecItemExport") && !text.contains("SecPKCS12Import"), "\(path)")
        }
    }
}
