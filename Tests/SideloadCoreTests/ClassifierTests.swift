import Foundation
import Testing

@testable import SideloadCore

private let bundle = "com.example.sideload.canary"

private func fixtureJSON(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: fixture(name))))
}

struct InstallCase: CustomTestStringConvertible, Sendable {
    let file: String
    let exitCode: Int32
    let guardPassed: Bool
    let status: Classification.Status
    let code: String

    init(_ file: String, guardPassed: Bool = false, _ status: Classification.Status, _ code: String) {
        self.file = file
        self.exitCode = file == "install-success.json" ? 0 : 1
        self.guardPassed = guardPassed
        self.status = status
        self.code = code
    }

    var testDescription: String { "\(file) guardPassed=\(guardPassed) -> \(status.rawValue) \(code)" }
}

private let installCases: [InstallCase] = [
    InstallCase("install-success.json", .working, "INSTALLED"),
    InstallCase("install-blocked-8018-hex.json", .blocked, "0xe8008018"),
    InstallCase("install-blocked-8018-signed.json", .blocked, "0xe8008018"),
    InstallCase("install-blocked-8018-text.json", .blocked, "0xe8008018"),
    InstallCase("install-provisional-8015.json", guardPassed: true, .blocked, "0xe8008015"),
    InstallCase("install-provisional-8016.json", guardPassed: true, .blocked, "0xe8008016"),
    InstallCase("install-provisional-801c.json", guardPassed: true, .blocked, "0xe800801c"),
    InstallCase("install-provisional-8015.json", guardPassed: false, .error, "0xe8008015"),
    InstallCase("install-provisional-801c.json", guardPassed: false, .error, "0xe800801c"),
    InstallCase("install-locked.json", guardPassed: true, .error, "DEVICE_LOCKED"),
    InstallCase("install-not-connected.json", guardPassed: true, .error, "DEVICE_NOT_CONNECTED"),
    InstallCase("install-disk-full.json", guardPassed: true, .error, "DISK_FULL"),
    InstallCase("install-unknown.json", guardPassed: true, .error, "1234567"),
]

@Suite("classifier")
struct ClassifierTests {
    @Test("0xe8008018 is -402620392 signed and 3892346904 unsigned")
    func codeForms() {
        let forms = InstallClassifier.CodeForms(hex: "0xe8008018")
        #expect(forms == InstallClassifier.CodeForms(hex: "0xE8008018"))
        #expect(forms.hex == "0xe8008018")
        #expect(forms.unsigned == "3892346904")
        #expect(forms.signed == "-402620392")
        #expect(UInt32(0xe800_8018) == 3_892_346_904)
        #expect(Int64(3_892_346_904) - Int64(1) << 32 == -402_620_392)
    }

    @Test("install fixtures classify", arguments: installCases)
    func installTable(_ c: InstallCase) throws {
        let r = InstallClassifier.classify(
            .init(exitCode: c.exitCode, json: try fixtureJSON(c.file), guardPassed: c.guardPassed, bundleId: bundle))
        #expect(r.status == c.status)
        #expect(r.code == c.code)
        #expect(!r.reason.isEmpty)
    }

    @Test("reason strings match the Node classifier")
    func reasons() throws {
        let blocked = InstallClassifier.classify(
            .init(exitCode: 1, json: try fixtureJSON("install-blocked-8018-hex.json")))
        #expect(
            blocked.reason
                == "Device rejected the signing identity (known account-side defect; Apple support case open).")
        let working = InstallClassifier.classify(
            .init(exitCode: 0, json: try fixtureJSON("install-success.json"), bundleId: bundle))
        #expect(working.reason == "Install succeeded; Apple has fixed the install block.")
        let unguarded = InstallClassifier.classify(
            .init(exitCode: 1, json: try fixtureJSON("install-provisional-8015.json")))
        #expect(
            unguarded.reason
                == "Device did not recognise the provisioning profile. The pre-install guard did not pass, so this is not attributed to the account."
        )
        let overflow = InstallClassifier.classify(.init(overflow: true))
        #expect(overflow == Classification(
            status: .error, code: "OUTPUT_LIMIT",
            reason: "devicectl produced more output than the safety limit; the install outcome is unknown."))
    }

    @Test("0xe8008018 wins even when guardPassed is false (known account defect)")
    func blockedWithoutGuard() throws {
        let json = try fixtureJSON("install-blocked-8018-hex.json")
        #expect(InstallClassifier.classify(.init(exitCode: 1, json: json, guardPassed: false)).status == .blocked)
    }

    @Test("is case-insensitive on the hex form and finds it in stderr")
    func stderrHex() {
        let r = InstallClassifier.classify(.init(exitCode: 1, stderr: "ERROR: install failed (0xE8008018)"))
        #expect(r.status == .blocked)
    }

    @Test("matches the signed and unsigned decimal forms in text, but not inside a longer number")
    func decimalBoundaries() {
        func classify(_ text: String) -> Classification {
            InstallClassifier.classify(
                .init(exitCode: 1, json: ["error": ["userInfo": ["NSLocalizedDescription": .string(text)]]]))
        }
        #expect(classify("id 138923469041 failed").status == .error)
        #expect(classify("id 13892346904 failed").status == .error)
        #expect(classify("id 03892346904 failed").status == .error)
        #expect(classify("status 3892346904.").status == .blocked)
        #expect(classify("status -402620392").status == .blocked)
        #expect(classify("status 1-402620392").status == .error)
        #expect(classify("status 1402620392").status == .error)
    }

    @Test("bare numbers count only under a code-like key")
    func bareNumbers() {
        func classify(_ key: String, _ n: Double) -> Classification.Status {
            InstallClassifier.classify(.init(exitCode: 1, json: .object(["error": .object([key: .number(n)])]))).status
        }
        #expect(classify("code", 3_892_346_904) == .blocked)
        #expect(classify("errorCode", -402_620_392) == .blocked)
        #expect(classify("count", 3_892_346_904) == .error)
        #expect(classify("code", 3_892_346_905) == .error)
    }

    @Test("exit 0 without the bundle id listed is not \"working\"")
    func unconfirmed() throws {
        let r = InstallClassifier.classify(
            .init(exitCode: 0, json: try fixtureJSON("install-success.json"), bundleId: "com.other.app"))
        #expect(r.status == .error)
        #expect(r.code == "INSTALL_UNCONFIRMED")
        let noBundle = InstallClassifier.classify(.init(exitCode: 0, json: try fixtureJSON("install-success.json")))
        #expect(noBundle.code == "INSTALL_UNCONFIRMED")
    }

    @Test("exit 0 with outcome failed is not \"working\"")
    func outcomeFailed() {
        let json: JSONValue = [
            "info": ["outcome": "failed"], "result": ["installedApplications": [["bundleID": .string(bundle)]]],
        ]
        #expect(InstallClassifier.classify(.init(exitCode: 0, json: json, bundleId: bundle)).status != .working)
    }

    @Test("a timeout, even with exit 0, is not \"working\"")
    func timedOutNotWorking() throws {
        let r = InstallClassifier.classify(
            .init(exitCode: 0, json: try fixtureJSON("install-success.json"), timedOut: true, bundleId: bundle))
        #expect(r.status == .error)
        #expect(r.code == "TIMEOUT")
    }

    @Test("timeouts and missing JSON are errors, never blocked")
    func timeoutsAndMissingJSON() {
        let timeout = InstallClassifier.classify(.init(exitCode: nil, json: nil, timedOut: true))
        #expect(timeout.status == .error)
        #expect(timeout.code == "TIMEOUT")
        #expect(InstallClassifier.classify(.init(exitCode: 1, json: nil)).code == "UNKNOWN")
        #expect(InstallClassifier.classify(.init(exitCode: 1, stderr: "operation timed out")).code == "TIMEOUT")
    }

    @Test("the paid canary's classifier ignores the free-team texts: they stay as they were, and only the free path reads them")
    func paidClassifierIgnoresFreeTeamPatterns() throws {
        let limit = try loadFixtureJSON("install-free-app-limit.json")
        // `paid` is what the classifier answered before the free patterns existed: the fixture carries a raw error code (3002),
        // which is returned for an unrecognised failure; the plain texts are UNKNOWN.
        let inputs: [(stderr: String, json: JSONValue?, paid: String, free: String)] = [
            ("This device has reached the maximum number of installed apps using a free developer profile: {()}", nil, "UNKNOWN", "FREE_APP_LIMIT"),
            ("", limit, "3002", "FREE_APP_LIMIT"),
            ("Untrusted Developer", nil, "UNKNOWN", "UNTRUSTED_DEVELOPER"),
            ("Pairing is required to continue", nil, "UNKNOWN", "DEVICE_NOT_PAIRED"),
        ]
        for input in inputs {
            let paid = InstallClassifier.classify(.init(exitCode: 1, json: input.json, stderr: input.stderr, guardPassed: true))
            #expect(paid.code == input.paid && paid.status == .error, "paid: \(input.stderr.prefix(30)) -> \(paid.code)")
            let free = InstallClassifier.classify(.init(exitCode: 1, json: input.json, stderr: input.stderr, guardPassed: true, freeTeam: true))
            #expect(free.code == input.free, "free: \(free.code)")
        }
        // The account block is read the same by both.
        let blocked = InstallClassifier.Input(exitCode: 1, stderr: "ERROR: install failed (0xE8008018)", guardPassed: true)
        var free = blocked
        free.freeTeam = true
        #expect(InstallClassifier.classify(blocked) == InstallClassifier.classify(free))
    }

    @Test("a raw hex code in the JSON is returned for an unrecognised failure; stderr is not searched for it")
    func rawHexCode() {
        let json: JSONValue = ["error": ["userInfo": ["NSLocalizedDescription": "failed with 0xE8001234 somewhere"]]]
        let r = InstallClassifier.classify(.init(exitCode: 1, json: json))
        #expect(r.status == .error)
        #expect(r.code == "0xe8001234")
        #expect(InstallClassifier.classify(.init(exitCode: 1, stderr: "failed with 0xE8001234")).code == "UNKNOWN")
    }

    // MARK: - classifyBuild

    @Test("returns nil on success")
    func buildSuccess() {
        #expect(BuildClassifier.classify(.init(exitCode: 0)) == nil)
    }

    @Test("extracts error lines on failure")
    func buildErrorLines() throws {
        let r = try #require(BuildClassifier.classify(.init(exitCode: 65, stderr: "x\n/p/Canary.swift:1:1: error: boom\n")))
        #expect(r.code == "BUILD_FAILED")
        #expect(r.status == .error)
        #expect(r.reason == "xcodebuild failed: boom")
    }

    @Test("keeps three unique error lines, trimmed to 300 characters")
    func buildErrorLimits() throws {
        let long = String(repeating: "z", count: 400)
        let stderr = "a.swift:1: error: one\nb.swift:2: error: one\nc.swift:3: error: two\n"
        let stdout = "d.swift:4: error: \(long)\ne.swift:5: error: four\n"
        let r = try #require(BuildClassifier.classify(.init(exitCode: 65, stderr: stderr, stdout: stdout)))
        #expect(r.reason == "xcodebuild failed: one | two | \(String(repeating: "z", count: 300))")
    }

    @Test("falls back to the exit code when no error line is present")
    func buildNoErrorLines() throws {
        let r = try #require(BuildClassifier.classify(.init(exitCode: 65, stderr: "warning: nothing")))
        #expect(r.reason == "xcodebuild failed with exit code 65.")
    }

    @Test("reports output-limit overflow explicitly")
    func buildOverflow() throws {
        let r = try #require(BuildClassifier.classify(.init(exitCode: nil, overflow: true)))
        #expect(r.code == "OUTPUT_LIMIT")
        #expect(r.status == .error)
    }

    @Test("maps timeouts and spawn errors")
    func buildTimeoutAndSpawn() throws {
        #expect(try #require(BuildClassifier.classify(.init(exitCode: nil, timedOut: true))).code == "BUILD_TIMEOUT")
        let spawn = try #require(BuildClassifier.classify(.init(exitCode: nil, spawnError: "ENOENT")))
        #expect(spawn.code == "BUILD_FAILED")
        #expect(spawn.reason == "xcodebuild could not be started.")
    }
}
