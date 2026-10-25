import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `canary --evidence` (docs/design.md sections 7, 8 and 10): the opt-in bundle (an allowlist built from structure),
// its independent verifier, and the new canary.jsonl fields. A scripted fake world only: no device, portal, keychain write or real home.

private let stampDir = "canary-2026-10-19T12-00-00-000Z"
private let evidenceOptions = CanaryOptions(device: "iphone", yes: true, evidence: true)

private func blocked() throws -> CanaryScenario {
    CanaryScenario(install: try .failure("install-blocked-8018-hex.json"))
}

private func warningCodes(_ out: Envelope) -> [String] {
    out.data["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
}

private func readText(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

private func readJSON(_ path: String) throws -> JSONValue { try decodeJSON(try readText(path)) }

private func bundlePath(_ w: CanaryWorld, _ file: String = "") -> String {
    w.paths.evidence + "/" + stampDir + (file.isEmpty ? "" : "/" + file)
}

private func fingerprint(_ base64: String) throws -> String {
    try keychainCert(base64).reference
}

@Suite("canary evidence: the bundle")
struct CanaryEvidenceBundleTests {
    @Test("blocked + --evidence: one 0700 folder with two 0600 files, and the envelope says where")
    func blockedBundle() async throws {
        try await withCanaryWorld(try blocked()) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.ok && out.exitCode == 0)
            #expect(out.data["status"] == "blocked")
            #expect(listing(w.paths.evidence) == [stampDir])
            #expect(listing(bundlePath(w)).sorted() == ["evidence.json", "evidence.txt"])
            #expect(modeOf(w.paths.evidence) == 0o700 && modeOf(bundlePath(w)) == 0o700)
            #expect(modeOf(bundlePath(w, "evidence.json")) == 0o600)
            #expect(modeOf(bundlePath(w, "evidence.txt")) == 0o600)
            #expect(
                out.data["evidence"] == [
                    "written": true, "dir": .string("evidence/" + stampDir),
                    "files": ["evidence.json", "evidence.txt"],
                ])
            #expect(out.data["warnings"] == [])
            let printed = try out.printed().text
            #expect(!printed.contains(w.paths.home), "the envelope names the folder relative to the home")
        }
    }

    @Test("evidence.json reports the run, environment, keychain certificate, profile, codesign and install")
    func content() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            let fp = String(try fingerprint(TestCerts.paid).prefix(8)).lowercased()
            #expect(e["schema"] == 2)
            #expect(e["appleCase"] == .null, "no appleSupportCase in the config")
            #expect(e["team"] == "7AGMPUPP64")
            #expect(e["bundleId"] == .string(canaryBundle))
            #expect(e["generatedAt"] == "2026-10-19T12:00:00Z")
            #expect(e["run"]?["status"] == "blocked")
            #expect(e["run"]?["code"] == "0xe8008018")
            #expect(e["run"]?["guard"] == "passed")
            #expect(e["run"]?["durationMs"] == 0)
            #expect(e["environment"]?["macos"] == ["version": "27.0.1", "build": "27A100"])
            #expect(e["environment"]?["xcode"] == "27.0 (27A266a)")
            #expect(e["environment"]?["ios"] == ["version": "27.0.1", "build": "24A446"])
            #expect(
                e["keychainCertificate"] == [
                    "ou": "7AGMPUPP64", "notBefore": "2026-01-01T00:00:00Z", "notAfter": "2027-10-16T22:39:42Z",
                    "certFp": .string(fp),
                ])
            #expect(fp.count == 8)
            #expect(
                e["profile"] == [
                    "team": "7AGMPUPP64", "createdAt": "2026-10-01T08:00:00Z", "expiresAt": "2027-10-01T08:00:00Z",
                    "deviceCount": 1, "deviceIncluded": true, "deviceTail4": .string("…" + savedUdid("1").suffix(4)),
                    "signingCertInProfile": true,
                ])
            #expect(e["codesign"] == ["teamIdentifier": "7AGMPUPP64"])
            #expect(e["install"]?["classification"] == "0xe8008018")
            #expect(e["install"]?["exitCode"] == 1)
            #expect(e["install"]?["timedOut"] == false)
            #expect(e["install"]?["outcome"] == "failed")
            #expect(e["install"]?["omitted"] == ["nodes": 0, "messages": 0, "stderrLines": 0])
            #expect(e["install"]?["stderr"] == [])
            let chain = try #require(e["install"]?["errorChain"]?.array)
            #expect(chain.count == 2)
            #expect(chain[0]["depth"] == 0 && chain[0]["domain"] == "com.apple.dt.CoreDeviceError")
            #expect(chain[0]["code"] == 3002 && chain[0]["codeHex"] == "0x00000bba")
            #expect(chain[0]["description"] == "Failed to install the app on the device.")
            #expect(chain[1]["depth"] == 1 && chain[1]["domain"] == "com.apple.dt.MobileDeviceErrorDomain")
            #expect(chain[1]["code"] == 3_892_346_904 && chain[1]["codeHex"] == "0xe8008018")
            #expect(chain[1]["description"] == "Could not install app (0xe8008018).")
            #expect(chain[1]["codeSignature"] == .null && chain[1]["legacyErrorString"] == .null)
            #expect(e["run"]?["reason"]?.string?.contains("Device rejected the signing identity") == true)
        }
    }

    @Test("appleCase is the config's appleSupportCase when set, null when not")
    func appleCaseFromConfig() async throws {
        try await withCanaryWorld(try blocked(), config: canaryConfig { $0.appleSupportCase = "555000111222" }) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["appleCase"] == "555000111222")
            #expect(try readText(bundlePath(w, "evidence.txt")).contains("appleCase: 555000111222\n"))
        }
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["appleCase"] == .null)
            #expect(try readText(bundlePath(w, "evidence.txt")).contains("appleCase: unavailable\n"))
        }
    }

    @Test("a configured appleSupportCase that is not a bare number is left out, and a number or null verifies")
    func appleCaseShape() {
        func tree(_ value: String?) -> JSONValue {
            EvidenceBuilder.build(
                EvidenceInput(
                    generatedAt: testNow, status: "blocked", code: "0xe8008018", reason: nil, guardRecord: "passed",
                    durationMs: 0, bundleId: canaryBundle, macosVersion: nil, macosBuild: nil, xcode: nil, iosVersion: nil,
                    iosBuild: nil, certificate: nil, certFp: nil, guardFacts: nil, deviceTail4: "…AAA1", install: nil,
                    appleCase: value))
        }
        #expect(tree("555000111222")["appleCase"] == "555000111222")
        #expect(tree("Robin Quinlan")["appleCase"] == .null)
        #expect(tree(nil)["appleCase"] == .null)
        for t in [tree("555000111222"), tree(nil)] {
            #expect(EvidenceVerifier.hits(tree: t, bodies: [], tokens: [], ids: [], bundleId: canaryBundle) == [])
        }
    }

    @Test("evidence.txt carries the same facts as sectioned key: value lines under a header for the Apple case")
    func textBody() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            let text = try readText(bundlePath(w, "evidence.txt"))
            let fp = String(try fingerprint(TestCerts.paid).prefix(8)).lowercased()
            #expect(text.hasPrefix("sideload canary evidence (schema 2)\n"))
            #expect(text.contains("Developer Support case.") && text.contains("sends nothing"))
            for line in [
                "[run]", "status: blocked", "code: 0xe8008018", "[environment]", "macos.version: 27.0.1",
                "ios.build: 24A446", "xcode: 27.0 (27A266a)", "[keychainCertificate]", "certFp: \(fp)",
                "notAfter: 2027-10-16T22:39:42Z", "[profile]", "deviceIncluded: yes", "signingCertInProfile: yes",
                "[codesign]", "teamIdentifier: 7AGMPUPP64", "[install]", "classification: 0xe8008018", "exitCode: 1",
                "outcome: failed", "errorChain[0].domain: com.apple.dt.CoreDeviceError", "errorChain[1].codeHex: 0xe8008018",
                "errorChain[1].description: Could not install app (0xe8008018).", "errorChain[1].codeSignature: unavailable",
                "stderr: none", "omitted.messages: 0",
            ] {
                #expect(text.contains(line), "\(line)")
            }
        }
    }

    @Test("the certificate is identified by 8 hex digits only: no full fingerprint, no 40-hex run anywhere")
    func certFpOnly() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            let full = try fingerprint(TestCerts.paid)
            let sha1Shape = /[0-9A-Fa-f]{40}/
            for body in [
                try readText(bundlePath(w, "evidence.json")), try readText(bundlePath(w, "evidence.txt")),
                try readText(w.paths.canaryLog),
            ] {
                #expect(!body.uppercased().contains(full))
                #expect(body.firstMatch(of: sha1Shape) == nil)
            }
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["keychainCertificate"]?["certFp"]?.string?.count == 8)
        }
    }

    @Test("without --evidence nothing is written and the envelope has no evidence key")
    func optIn() async throws {
        try await withCanaryWorld(try blocked()) { w in
            let out = await w.run()
            #expect(out.data["status"] == "blocked")
            #expect(out.data["evidence"] == nil)
            #expect(!FileManager.default.fileExists(atPath: w.paths.evidence))
        }
    }

    @Test("working + --evidence writes no bundle")
    func workingNoBundle() async throws {
        try await withCanaryWorld { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["status"] == "working")
            #expect(out.data["evidence"] == ["written": false, "dir": .null, "files": []])
            #expect(!FileManager.default.fileExists(atPath: w.paths.evidence))
        }
    }

    @Test("an error result gets a bundle too: timeout, with the exit code unknown")
    func errorBundle() async throws {
        try await withCanaryWorld(CanaryScenario(install: .timeout)) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["status"] == "error" && !out.ok)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["run"]?["status"] == "error" && e["run"]?["code"] == "TIMEOUT")
            #expect(e["install"]?["timedOut"] == true)
            #expect(e["install"]?["exitCode"] == .null)
            #expect(e["install"]?["errorChain"] == [] && e["install"]?["outcome"] == .null)
        }
    }

    @Test("a guard failure bundle has the codesign and profile facts, no install, and no extra device call")
    func guardFailureBundle() async throws {
        try await withCanaryWorld(CanaryScenario(profileDevices: [savedUdid("9")])) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["code"] == "DEVICE_NOT_IN_PROFILE")
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["install"] == .null)
            #expect(e["codesign"]?["teamIdentifier"] == "7AGMPUPP64")
            #expect(e["profile"]?["deviceIncluded"] == false)
            #expect(e["profile"]?["deviceCount"] == 1)
            #expect(e["environment"]?["ios"] == ["version": .null, "build": .null])
            let devicectl = w.calls.filter { $0.executable == "xcrun" }
            #expect(devicectl.count == 2, "evidence must not add a device call after a failed guard")
            #expect(w.state.lists == 1)
        }
        try await withCanaryWorld(CanaryScenario(signedTeam: "ZZZZZZZZZZ")) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["codesign"]?["teamIdentifier"] == "ZZZZZZZZZZ")
            #expect(e["profile"]?["team"] == .null)
        }
    }

    @Test("a precheck failure still gets a bundle, with every unknown field null")
    func precheckBundle() async throws {
        try await withCanaryWorld(CanaryScenario(free: true)) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["code"] == "PRECHECK_FAILED")
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["keychainCertificate"]?["certFp"] == .null)
            #expect(e["environment"]?["xcode"] == .null)
            #expect(e["codesign"]?["teamIdentifier"] == .null)
            let text = try readText(bundlePath(w, "evidence.txt"))
            #expect(text.contains("certFp: unavailable"))
        }
    }

    @Test("a value the run could not learn is null in the JSON and `unavailable` in the text")
    func unavailable() async throws {
        var scenario = try blocked()
        scenario.iosVersion = nil
        scenario.iosBuild = nil
        scenario.macosVersion = ""
        scenario.macosBuild = ""
        try await withCanaryWorld(scenario) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["environment"]?["ios"] == ["version": .null, "build": .null])
            #expect(e["environment"]?["macos"] == ["version": .null, "build": .null])
            let text = try readText(bundlePath(w, "evidence.txt"))
            #expect(text.contains("ios.version: unavailable") && text.contains("macos.version: unavailable"))
        }
    }

    @Test("signingCertInProfile is false when the profile lists other certificates, null for none known")
    func certInProfile() async throws {
        var scenario = try blocked()
        scenario.profileCerts = [TestCerts.other]
        try await withCanaryWorld(scenario) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["profile"]?["signingCertInProfile"] == false)
        }
        var none = try blocked()
        none.profileCerts = []
        try await withCanaryWorld(none) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["profile"]?["signingCertInProfile"] == false)
        }
    }

    @Test("a failed write is a warning only: status, ok and the log line are untouched")
    func writeFails() async throws {
        try await withCanaryWorld(try blocked()) { w in
            FileManager.default.createFile(atPath: w.paths.evidence, contents: Data())  // a file where the folder goes
            let out = await w.run(evidenceOptions)
            #expect(out.ok && out.exitCode == 0 && out.data["status"] == "blocked")
            #expect(warningCodes(out) == ["EVIDENCE_WRITE_FAILED"])
            #expect(out.data["evidence"] == ["written": false, "dir": .null, "files": []])
            let logged = try w.jsonlLines
            #expect(logged.count == 1)
        }
    }

    @Test("a bundle that already exists is never overwritten: warning, existing files untouched")
    func collision() async throws {
        try await withCanaryWorld(try blocked()) { w in
            try FileManager.default.createDirectory(atPath: bundlePath(w), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: URL(fileURLWithPath: bundlePath(w, "evidence.json")))
            let out = await w.run(evidenceOptions)
            #expect(warningCodes(out) == ["EVIDENCE_WRITE_FAILED"])
            #expect(out.data["status"] == "blocked")
            #expect(listing(bundlePath(w)) == ["evidence.json"])
            let kept = try readText(bundlePath(w, "evidence.json"))
            #expect(kept == "keep")
        }
    }

    @Test("a half-written bundle is removed, not left behind")
    func noPartialBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        // evidence.json lands in the temporary folder, then evidence.txt cannot: a directory sits where it goes.
        let outcome = EvidenceWriter.write(
            ["schema": 2], stamp: "t", home: paths, tokens: SubjectTokens(), bundleId: canaryBundle,
            afterFirstFile: { tmp in
                try? FileManager.default.createDirectory(
                    atPath: tmp + "/evidence.txt", withIntermediateDirectories: true)
            })
        #expect(outcome == .writeFailed)
        #expect(listing(paths.evidence).isEmpty, "neither a bundle nor its temporary folder is left")
    }

    @Test("the bundle appears under its real name only once both files are written")
    func atomicBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        var midway: [String] = []
        let outcome = EvidenceWriter.write(
            ["schema": 2], stamp: "t", home: paths, tokens: SubjectTokens(), bundleId: canaryBundle,
            afterFirstFile: { _ in midway = listing(paths.evidence) })  // what a kill here would leave
        #expect(outcome == .written(dir: "evidence/canary-t", files: ["evidence.json", "evidence.txt"]))
        #expect(midway.count == 1 && midway[0].hasPrefix(".canary-t.") && midway[0].hasSuffix(".tmp"))
        #expect(!midway.contains("canary-t"))
        #expect(listing(paths.evidence) == ["canary-t"])
        #expect(listing(paths.evidence + "/canary-t").sorted() == ["evidence.json", "evidence.txt"])
        #expect(modeOf(paths.evidence + "/canary-t") == 0o700)
    }

    @Test("a canary run with --evidence leaves exactly one extra file set and the same envelope otherwise")
    func sameEnvelope() async throws {
        var withoutFlag: Envelope?
        try await withCanaryWorld(try blocked()) { w in withoutFlag = await w.run() }
        try await withCanaryWorld(try blocked()) { w in
            let withFlag = await w.run(evidenceOptions)
            var a = try #require(withoutFlag).data
            var b = withFlag.data
            a["evidence"] = nil
            b["evidence"] = nil
            #expect(a == b)
            #expect(withFlag.exitCode == withoutFlag?.exitCode)
        }
    }

    @Test("device listing: once per run, only after the guard passed")
    func listCounts() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            #expect(w.state.lists == 2, "preflight + one memoized listing for scrubbing, iOS and evidence")
        }
        try await withCanaryWorld { w in
            _ = await w.run()
            #expect(w.state.lists == 2, "a working run lists once more, for the iOS version in the log")
        }
        try await withCanaryWorld(CanaryScenario(signedTeam: "ZZZZZZZZZZ")) { w in
            _ = await w.run(evidenceOptions)
            #expect(w.state.lists == 1)
        }
    }
}

// MARK: - reduction: structure first, nothing rewritten

private func reduce(
    _ json: JSONValue?, stderr: String = "", tokens: SubjectTokens = SubjectTokens(), bundleId: String? = canaryBundle
) -> ErrorChain.Reduction {
    ErrorChain.reduce(json: json, stderr: stderr, tokens: tokens, bundleId: bundleId)
}

/// A straight chain of `n` nodes, `d0` at depth 0.
private func straightChain(_ n: Int) -> JSONValue {
    var node: JSONValue = ["domain": .string("d\(n - 1)"), "code": .number(Double(n - 1)), "userInfo": [:]]
    for i in stride(from: n - 2, through: 0, by: -1) {
        node = [
            "domain": .string("d\(i)"), "code": .number(Double(i)),
            "userInfo": ["NSUnderlyingError": ["error": node]],
        ]
    }
    return ["error": node]
}

private func msg(_ s: String) -> JSONValue { ["string": .string(s)] }

@Suite("canary evidence: reduction")
struct CanaryEvidenceReductionTests {
    @Test("the real capture's shape: three nodes, descriptions admitted, the code-signature template taken apart, no path")
    func realShape() async throws {
        let payload = try installFixture("install-blocked-8018-chain.json")
        try await withCanaryWorld(CanaryScenario(install: InstallScript(code: 1, payload: payload))) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["status"] == "blocked" && out.data["code"] == "0xe8008018")
            #expect(out.data["evidence"]?["written"] == true)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            let chain = try #require(e["install"]?["errorChain"]?.array)
            #expect(chain.count == 3)
            #expect(chain[0]["domain"] == "com.apple.dt.CoreDeviceError" && chain[0]["code"] == 3002)
            #expect(chain[0]["description"] == "Failed to install the app on the device.")
            #expect(chain[1]["domain"] == "IXUserPresentableErrorDomain" && chain[1]["code"] == 14)
            #expect(chain[1]["description"] == "Unable to Install “Canary”")
            #expect(chain[1]["failureReason"] == "This app cannot be installed because its integrity could not be verified.")
            #expect(chain[1]["recoverySuggestion"] == .null, "it carries the path: left out and counted")
            #expect(chain[2]["domain"] == "MIInstallerErrorDomain" && chain[2]["code"] == 13)
            #expect(chain[2]["codeHex"] == "0x0000000d" && chain[2]["description"] == .null)
            #expect(
                chain[2]["codeSignature"] == [
                    "code": "0xe8008018", "message": "The identity used to sign the executable is no longer valid.",
                    "appBundle": "Canary.app",
                ])
            #expect(chain[2]["legacyErrorString"] == "ApplicationVerificationFailed")
            #expect(chain[2]["libMISErrorNumber"] == .null, "a value above 2^53 cannot be recovered exactly")
            #expect(
                e["install"]?["omitted"] == ["nodes": 0, "messages": 2, "stderrLines": 0],
                "the depth 1 recovery suggestion and the LibMISErrorNumber")
            for file in ["evidence.json", "evidence.txt"] {
                let body = try readText(bundlePath(w, file))
                for gone in ["installd", "staging", "/var", "temp.XXXXXX", "fake_function", "NSURL", "/fake", "SourceFileLine"] {
                    #expect(!body.contains(gone), "\(gone)")
                }
            }
            let text = try readText(bundlePath(w, "evidence.txt"))
            #expect(text.contains("errorChain[2].codeSignature.appBundle: Canary.app"))
            #expect(text.contains("errorChain[2].codeSignature.code: 0xe8008018"))
        }
    }

    @Test("a signature template for another app is taken apart without naming the app")
    func otherApp() {
        let json: JSONValue = [
            "error": [
                "domain": "MIInstallerErrorDomain", "code": 13,
                "userInfo": [
                    "NSLocalizedDescription": msg(
                        "Failed to verify code signature of /var/x/Other.app : 0xE8008018 (The identity used to sign the executable is no longer valid.)"
                    )
                ],
            ]
        ]
        let r = reduce(json)
        #expect(r.nodes.first?.codeSignature?.appBundle == nil)
        #expect(r.nodes.first?.codeSignature?.code == "0xe8008018")
        #expect(r.nodes.first?.description == nil)
        let fake: JSONValue = [
            "error": [
                "domain": "d", "code": 1,
                "userInfo": ["NSLocalizedDescription": msg("Failed to verify code signature of /a/Canary.app/x : 0xe8008018 (Robin’s phone)")],
            ]
        ]
        let tokens = SubjectTokens.make(EvidenceSubjects(login: "robin"))
        let r2 = reduce(fake, tokens: tokens)
        #expect(r2.nodes.first?.codeSignature == ErrorChain.CodeSignature(code: "0xe8008018", message: nil, appBundle: nil))
        #expect(r2.omittedMessages == 1)
    }

    @Test("codeHex only for codes that fit 32 bits; code itself only below 2^53")
    func codeHexRange() {
        func node(_ code: Double) -> ErrorChain.Node? {
            reduce(["error": ["domain": "d", "code": .number(code)]]).nodes.first
        }
        #expect(node(-402_620_392)?.codeHex == "0xe8008018")
        #expect(node(4_294_967_295)?.codeHex == "0xffffffff")
        #expect(node(1_099_511_627_776)?.code == 1_099_511_627_776 && node(1_099_511_627_776)?.codeHex == nil, "2^40 would truncate")
        #expect(node(9_007_199_254_740_992) == nil, "2^53 is not an exact code: no node")
    }

    @Test("recorded fixtures: the 8018 hex code in 32-bit two's complement; descriptions admitted whole")
    func recordedFixtures() throws {
        let hex = reduce(try installFixture("install-blocked-8018-hex.json"))
        #expect(hex.nodes.map(\.codeHex) == ["0x00000bba", "0xe8008018"])
        #expect(hex.nodes.map(\.depth) == [0, 1])
        let text = reduce(try installFixture("install-blocked-8018-text.json"))
        #expect(
            text.nodes.first?.description
                == "The identity used to sign the executable is no longer valid. Please verify that your device's clock is properly set.")
        #expect(text.omittedMessages == 0)
        let signed = reduce(try installFixture("install-blocked-8018-signed.json"))
        #expect(signed.nodes.map(\.codeHex) == ["0x00000bba", "0x00000fa0", "0xe8008018"])
        #expect(signed.nodes.map(\.domain) == ["com.apple.dt.CoreDeviceError", "wrapper", "com.apple.dt.MobileDevice"])
    }

    @Test("depth is capped at 8 and nodes at 16; what is dropped is counted")
    func caps() {
        let deep = reduce(straightChain(10))
        #expect(deep.nodes.count == 9 && deep.nodes.last?.depth == 8)
        #expect(deep.omittedNodes == 1)
        let exact = reduce(straightChain(9))
        #expect(exact.nodes.count == 9 && exact.omittedNodes == 0)

        let children: [JSONValue] = (1...16).map {
            ["error": ["domain": .string("c\($0)"), "code": .number(Double($0)), "userInfo": [:]]]
        }
        let wide: JSONValue = [
            "error": ["domain": "top", "code": 1, "userInfo": ["NSMultipleUnderlyingErrorsKey": .array(children)]]
        ]
        let r = reduce(wide)
        #expect(r.nodes.count == 16 && r.omittedNodes == 1)
        #expect(r.nodes.map(\.domain).prefix(3) == ["top", "c1", "c2"], "pre-order")
        let some = reduce([
            "error": ["domain": "top", "code": 1, "userInfo": ["NSMultipleUnderlyingErrorsKey": .array(Array(children.prefix(2)))]]
        ])
        #expect(some.nodes.count == 3 && some.omittedNodes == 0)
    }

    @Test("a node needs a domain string and an integer code; anything else is not a node")
    func notNodes() {
        for bad: JSONValue in [
            ["domain": "d"], ["code": 1], ["domain": 5, "code": 1], ["domain": "d", "code": 1.5],
            ["domain": "d", "code": "1"], "text", [], ["domain": "d", "code": 1e300],
        ] {
            let r = reduce(["error": bad])
            #expect(r.nodes.isEmpty && r.omittedNodes == 1)
        }
        #expect(reduce(["info": ["outcome": "failed"]]).nodes.isEmpty)
        #expect(reduce(nil).nodes.isEmpty && reduce(nil).omittedNodes == 0)
    }

    @Test("only the named keys are read: NSURL, FunctionName, SourceFileLine and any other key never reach the bundle")
    func closedKeys() {
        let json: JSONValue = [
            "error": [
                "domain": "d", "code": 1,
                "userInfo": [
                    "NSURL": msg("file:///fake/x"), "FunctionName": msg("f"), "SourceFileLine": ["uint": 5],
                    "SomethingNew": msg("Failed to install the app on the device."),
                    "NSLocalizedDescription": msg("Failed to install the app on the device."),
                ],
            ]
        ]
        let node = reduce(json).nodes[0]
        #expect(node.description == "Failed to install the app on the device.")
        #expect(node.failureReason == nil && node.recoverySuggestion == nil && node.legacyErrorString == nil)
        #expect(reduce(json).omittedMessages == 0)
    }

    @Test("domain, LegacyErrorString and outcome are kept only in their shapes")
    func shapes() {
        func node(domain: String, legacy: JSONValue? = nil) -> ErrorChain.Node? {
            var info: [String: JSONValue] = [:]
            if let legacy { info["LegacyErrorString"] = legacy }
            return reduce(["error": ["domain": .string(domain), "code": 1, "userInfo": .object(info)]]).nodes.first
        }
        #expect(node(domain: "com.apple.dt.CoreDeviceError")?.domain == "com.apple.dt.CoreDeviceError")
        for bad in ["has space", "a-b", "a_b", "a%20b", "1abc", "a..b", "a.", String(repeating: "a", count: 97), "é", ""] {
            #expect(node(domain: bad)?.domain == nil, "\(bad.prefix(8))")
        }
        #expect(node(domain: "d", legacy: msg("ApplicationVerificationFailed"))?.legacyErrorString == "ApplicationVerificationFailed")
        #expect(node(domain: "d", legacy: "Short")?.legacyErrorString == "Short")
        for bad in ["two words", "a-b", "9start", String(repeating: "a", count: 65)] as [String] {
            #expect(node(domain: "d", legacy: msg(bad))?.legacyErrorString == nil)
        }
        #expect(node(domain: "d", legacy: ["uint": 5])?.legacyErrorString == nil)
        for good in ["failed", "success", "succeeded"] {
            #expect(reduce(["info": ["outcome": .string(good)]]).outcome == good)
        }
        for bad in ["Failed", "two words", "toolongtoolongtoolong", "a-b", "", "unknown", "jane"] {
            let r = reduce(["info": ["outcome": .string(bad)]])
            #expect(r.outcome == nil && r.omittedMessages == 1)
        }
        #expect(reduce(["info": [:]]).omittedMessages == 0)
    }

    @Test("a short subject token inside a kept identifier nulls and counts it (no vocabulary gates domain, legacy, outcome)")
    func shortTokensInIdentifiers() {
        let den = SubjectTokens.make(EvidenceSubjects(names: ["Den’s iPhone"], login: "Den"))
        let json: JSONValue = [
            "info": ["outcome": "deniphone"],
            "error": [
                "domain": "deniphone", "code": 1,
                "userInfo": ["LegacyErrorString": msg("DenIPhone"), "NSUnderlyingError": ["error": ["domain": "Xdeny", "code": 2, "userInfo": [:]]]],
            ],
        ]
        let r = reduce(json, tokens: den)
        #expect(r.outcome == nil && r.nodes.map(\.domain) == [nil, nil] && r.nodes[0].legacyErrorString == nil)
        #expect(r.omittedMessages == 4)
        #expect(reduce(json).nodes.map(\.domain) == ["deniphone", "Xdeny"], "no subject, no change")
    }

    @Test("LibMISErrorNumber is kept as a decimal string only when a double holds it exactly (below 2^53), bare or wrapped")
    func libMIS() {
        func number(_ v: JSONValue) -> String? {
            reduce(["error": ["domain": "d", "code": 1, "userInfo": ["LibMISErrorNumber": v]]]).nodes.first?.libMISErrorNumber
        }
        #expect(number(["uint": 1.8446744073306931e19]) == nil, "above 2^53 a double cannot hold it: no invented digits")
        #expect(number(["int": -402620392]) == "-402620392")
        #expect(number(["uint": 9_007_199_254_740_991]) == "9007199254740991")
        #expect(number(["uint": 9_007_199_254_740_992]) == nil, "2^53 may be a rounded 2^53+1")
        #expect(number(["uint": 9_007_199_254_740_994]) == nil)
        #expect(number(13) == "13")
        #expect(number(1.5) == nil && number("13") == nil && number(["string": "13"]) == nil)
        #expect(number(["uint": 1e30]) == nil)
        let dropped = reduce(["error": ["domain": "d", "code": 1, "userInfo": ["LibMISErrorNumber": ["uint": 1.8446744073306931e19]]]])
        #expect(dropped.omittedMessages == 1, "counted")
    }

    @Test("stderr: admitted lines only, unique, at most 20; the rest is counted")
    func stderrLines() {
        let lines = (1...25).map { "Failed attempt \($0) to install." }
        let r = reduce(nil, stderr: (["Could not install app (0xe8008018).", "Could not install app (0xe8008018).", "see /var/x", "", "  "] + lines).joined(separator: "\n"))
        #expect(r.stderr.count == 20)
        #expect(r.stderr[0] == "Could not install app (0xe8008018).")
        #expect(r.omittedStderrLines == 1 + 6, "one rejected line and the six admitted ones past the limit; the duplicate and blanks are free")
        #expect(reduce(nil, stderr: "").stderr.isEmpty)
    }

    @Test("an enormous stderr is counted, not read line by line")
    func hugeStderr() {
        let r = reduce(nil, stderr: String(repeating: "see /var/x\n", count: 5000))
        #expect(r.stderr.isEmpty && r.omittedStderrLines == 5000)
        #expect(reduce(nil, stderr: String(repeating: "a", count: 100_000)).omittedStderrLines == 1)
    }
}

@Suite("canary evidence: the message filter")
struct CanaryEvidenceFilterTests {
    private let tokens = SubjectTokens.make(
        EvidenceSubjects(names: ["Jane’s iPhone"], login: "robin", fullName: "Robin Quinlan"))

    private func admit(_ s: String, _ t: SubjectTokens? = nil, bundleId: String? = canaryBundle) -> String? {
        MessageFilter.admit(s, tokens: t ?? tokens, bundleId: bundleId)
    }

    @Test("Apple's template words pass, normalised: curly apostrophes straight, whitespace collapsed")
    func admits() {
        #expect(admit("Failed to install the app on the device.") == "Failed to install the app on the device.")
        #expect(admit("  Failed   to install\tthe app\n on the device.  ") == "Failed to install the app on the device.")
        #expect(
            admit("Please verify that your device’s clock is properly set.")
                == "Please verify that your device's clock is properly set.")
        #expect(admit("Could not install app (0xE8008018).") == "Could not install app (0xE8008018).")
        #expect(admit("Unable to Install “Canary”") == "Unable to Install “Canary”")
        #expect(admit("Unable to Install \"Canary\"") == "Unable to Install \"Canary\"")
        #expect(admit("Failed to install \u{FF21}pp") == "Failed to install App", "NFKC first")
        #expect(admit("Install of \(canaryBundle) failed: code 3002.") != nil, "the bundle ID counts as one token")
        #expect(admit("Install of “\(canaryBundle)” failed.") != nil)
        #expect(admit("The build succeeded but Canary.app was not found.") != nil)
        #expect(admit("An ordinary 1234567890 and 0x1 and 0xabcdef12.") == nil, "ordinary is not a listed word")
        #expect(admit("Exit code 1234567890 and 0x1 and 0xabcdef12.") != nil)
    }

    @Test("anything off the lists rejects the whole message", arguments: [
        "Failed to install “Jane”", "Failed to install “Canary” and “Other”", "Unable to Install ‘Canary’",
        "see /var/x", "mail me@example.com", "a_b", "50% done", "a+b", "a=b", "a&b", "a#b", "a?b", "a\\b", "<user>",
        "café", "Failed to install the app on the device.\u{0301}", "Failed to install ❌",
        "Exit code 12345678901.", "Exit code 0x123456789.", "Exit code iOS27.", "Exit code 27A266a.", "'", "''", "devices'",
        "Failed to install the zzyzx.", "", "   ",
    ])
    func rejects(text: String) {
        #expect(admit(text) == nil, "\(text.prefix(12))")
    }

    @Test("512 characters at most")
    func length() {
        let ok = Array(repeating: "install", count: 64).joined(separator: " ")  // 64 * 7 + 63 = 511
        #expect(ok.count == 511 && admit(ok) == ok)
        #expect(admit(ok + " app") == nil)
        #expect(admit(String(repeating: "install ", count: 10_000)) == nil)
    }

    @Test("a subject word rejects the message; the longer ones anywhere in the letters, the shorter ones as whole words")
    func subjectWords() {
        let world = SubjectTokens.make(EvidenceSubjects(names: ["Den", "Wait"], login: "ann", fullName: "Will"))
        #expect(world.tokens.contains("den") && world.tokens.contains("wait") && world.tokens.contains("ann"))
        #expect(admit("The identity used to sign the executable is no longer valid.", world) != nil, "identity contains den")
        #expect(admit("Please wait and retry.", world) == nil)
        #expect(admit("Please waiting retry.", world) == nil, "four or more characters count inside a longer word")
        #expect(admit("It will retry later.", world) == nil)
        #expect(admit("The profile is valid.", world) != nil)
        #expect(admit("Install the app.", SubjectTokens.make(EvidenceSubjects(names: ["The"]))) == nil)
        #expect(admit("Install then retry.", SubjectTokens.make(EvidenceSubjects(names: ["The"]))) != nil)
        let sideload = SubjectTokens.make(EvidenceSubjects(names: ["sideload"]))
        #expect(admit("Install of \(canaryBundle) failed.", sideload) != nil, "the bundle ID is set aside before the check")
        #expect(admit("Install of sideload failed.", sideload) == nil)
    }

    @Test("every static reason sideload writes passes the filter")
    func ownReasons() async throws {
        var reasons: [String] = []
        // Installs: every recorded fixture, with the guard passed and not, and the cases without a document.
        let names = [
            "install-success", "install-blocked-8018-hex", "install-blocked-8018-signed", "install-blocked-8018-text",
            "install-provisional-8015", "install-provisional-8016", "install-provisional-801c", "install-locked",
            "install-not-connected", "install-disk-full", "install-unknown",
        ]
        for name in names {
            let json = try installFixture(name + ".json")
            for passed in [true, false] {
                for exit: Int32? in [0, 1, nil] {
                    reasons.append(
                        InstallClassifier.classify(
                            .init(exitCode: exit, json: json, guardPassed: passed, bundleId: canaryBundle)).reason)
                }
            }
        }
        for input in [
            InstallClassifier.Input(overflow: true), .init(exitCode: 0), .init(exitCode: nil, timedOut: true),
            .init(exitCode: 1, stderr: "timed out"), .init(exitCode: 1),
        ] { reasons.append(InstallClassifier.classify(input).reason) }
        for input in [
            BuildClassifier.Input(overflow: true), .init(timedOut: true), .init(spawnError: "x"), .init(exitCode: 65),
            .init(exitCode: nil),
        ] { reasons.append(BuildClassifier.classify(input)?.reason ?? "") }
        // The guard.
        for scenario in [
            CanaryScenario(signedTeam: "ZZZZZZZZZZ"), CanaryScenario(signedTeam: "6ZU5Z6ZKK7"),
            CanaryScenario(profileTeam: "ZZZZZZZZZZ"), CanaryScenario(profileDevices: [savedUdid("9")]),
            CanaryScenario(buildSkipsApp: true), CanaryScenario(snapshotFails: true),
        ] {
            try await withCanaryWorld(scenario) { w in reasons.append(await w.run().data["reason"]?.string ?? "") }
        }
        let runner = FakeRunner { _ in RunResult(code: 1) }
        reasons.append(await Guard.run(runner: runner, app: "/fake/Canary.app", udid: savedUdid("1")).reason ?? "")
        let badProfile = FakeRunner {
            $0.executable == "/usr/bin/codesign" ? RunResult(stderr: "TeamIdentifier=7AGMPUPP64\n") : RunResult(stdout: "not a plist")
        }
        reasons.append(await Guard.run(runner: badProfile, app: "/fake/Canary.app", udid: savedUdid("1")).reason ?? "")

        #expect(Set(reasons).count >= 15)
        for reason in Set(reasons) {
            #expect(!reason.isEmpty)
            #expect(MessageFilter.admit(reason, tokens: SubjectTokens(), bundleId: canaryBundle) != nil, "\(reason)")
        }
    }

    @Test("the fixed list is lowercase single words")
    func vocabularyShape() {
        for word in EvidenceVocabulary.words {
            #expect(word == word.lowercased() && word.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") }, "\(word)")
        }
    }
}

@Suite("canary evidence: subject tokens")
struct CanaryEvidenceTokenTests {
    @Test("names, hostnames, login, full name, identity person, computer names and home folder, folded and de-pluralised")
    func derived() {
        let t = SubjectTokens.make(
            EvidenceSubjects(
                ids: [savedUdid("1")], names: ["Jane’s iPhone", "jane-phone.coredevice.local"], login: "Robin",
                fullName: "Robin Q. Quinlan", identityNames: ["Apple Development: Dana Reyes (7AGMPUPP64)"],
                computerName: "Robin’s MacBook Pro", localHostName: "Robins-MacBook-Pro", homeName: "robin"))
        for expected in ["jane", "phone", "coredevice", "robin", "robins", "quinlan", "dana", "reyes"] {
            #expect(t.tokens.contains(expected), "\(expected)")
        }
        for generic in ["iphone", "macbook", "pro", "local", "apple", "development", "q", "s", "7agmpupp64"] {
            #expect(!t.tokens.contains(generic), "\(generic)")
        }
        #expect(t.ids == [savedUdid("1")])
        #expect(t.tokens == t.tokens.sorted() && Set(t.tokens).count == t.tokens.count)
    }

    @Test("accents are folded away: a decomposed Zoë is zoe; a one-letter initial is no token")
    func folding() {
        #expect(SubjectTokens.make(EvidenceSubjects(names: ["Zoe\u{0308}"])).tokens == ["zoe"])
        #expect(SubjectTokens.make(EvidenceSubjects(names: ["Zoë"])).tokens == ["zoe"])
        #expect(SubjectTokens.fold("Zoë’s-iPhone_1") == "zoesiphone1")
        #expect(SubjectTokens.make(EvidenceSubjects(fullName: "A B Cee")).tokens == ["cee"])
    }

    @Test("a common name that is not the usual shape contributes its words, not its 10-character ID")
    func odd() {
        let t = SubjectTokens.make(EvidenceSubjects(identityNames: ["Dana Reyes ABCDE12345"]))
        #expect(t.tokens.contains("dana") && t.tokens.contains("reyes") && !t.tokens.contains("abcde12345"))
    }

    @Test("a device ID counts as a subject, with or without hyphens, in any case")
    func idsAreSubjects() {
        let t = SubjectTokens.make(EvidenceSubjects(ids: [savedUdid("1"), savedCoreId("1")]))
        for id in [savedUdid("1"), savedUdid("1").lowercased(), udidBare, coreBare.lowercased(), "x " + savedCoreId("1")] {
            #expect(t.appears(in: id), "\(id.prefix(6))")
        }
        #expect(!t.appears(in: "…AAA1"))
    }

    @Test("appears(in:) is the same rule the filter uses")
    func appears() {
        let t = SubjectTokens.make(EvidenceSubjects(names: ["Den", "Jane"]))
        #expect(t.appears(in: "Jane%27s%20iPhone") && t.appears(in: "janes-iphone") && t.appears(in: "J-A-N-E"))
        #expect(t.appears(in: "the den") && t.appears(in: "dens") && !t.appears(in: "identity") && !t.appears(in: "hidden"))
    }
}

// MARK: - leaks: every round-1 and round-2 string, in every place Apple's text can reach

enum Place: String, CaseIterable, Sendable {
    case description, failureReason, deepError, stderr, domain, legacy, outcome
}

struct LeakWorld: Sendable {
    var deviceName: String
    var hostnames: [String]
    var user: LocalUser
    /// What must not appear in a bundle, folded.
    var words: [String]
    var strings: [String]
}

private let udidBare = savedUdid("1").replacingOccurrences(of: "-", with: "")
private let coreBare = savedCoreId("1").replacingOccurrences(of: "-", with: "")

let leakWorlds: [LeakWorld] = [
    // A three-letter name: its text inside a kept identifier (domain, LegacyErrorString, outcome) is caught too.
    LeakWorld(
        deviceName: "Den’s iPhone", hostnames: [], user: LocalUser(login: "Den"), words: ["deniphone"],
        strings: ["deniphone", "Deniphone", "DENIPHONE", "denIPhone", "Den’s iPhone", "xDeniPhonex"]),
    // Round 1 (case and apostrophe variants, capitalised login, hostname variants, hyphen-free IDs) and round 2.
    LeakWorld(
        deviceName: "Jane’s iPhone", hostnames: ["jane-phone.local"],
        user: LocalUser(
            login: "robin", fullName: "Robin Quinlan", homeDirectory: "/Users/robin",
            computerName: "Robin’s MacBook Pro", localHostName: "Robins-MacBook-Pro"),
        words: ["jane", "robin", "quinlan"],
        strings: [
            "Jane's iPhone", "jane’s iphone", "JANE'S IPHONE", "Janes-iPhone.local", "Jane-Phone.local", "jane-phone",
            "JANE-PHONE", "jane-phone.coredevice.local", "ROBIN", "Robin’s iPhone", "robin", "Quinlan",
            "Robins-MacBook-Pro.local", "Robins iPhone", "robins-mbp", "Quinlans-Mac", "Jane%27s%20iPhone",
            "Jane%E2%80%99s%20iPhone", "Jane's+iPhone", "Janes iPhone", "/users/robin/x", "jane%40example.com",
            udidBare, udidBare.lowercased(), coreBare, coreBare.lowercased(), savedUdid("1").lowercased(),
            savedCoreId("1").lowercased(), "Failed for \(savedUdid("1")) on Jane’s iPhone",
        ]),
    LeakWorld(
        deviceName: "Zoe\u{0308}", hostnames: [], user: LocalUser(login: "pat", fullName: "Pat Q. Tester"), words: ["zoe"],
        strings: ["Zoe\u{0308}", "Zoë", "Zoe", "ZOE", "zoes-phone", "Zoe’s phone"]),
    LeakWorld(
        deviceName: "Test iPhone", hostnames: [],
        user: LocalUser(
            login: "pat", fullName: "Pat Q. Tester", computerName: "Kestrel’s Mac Studio", localHostName: "kestrel-studio"),
        words: ["kestrel"],
        strings: ["Kestrel's Mac Studio", "kestrel-studio", "Kestrels-Mac-Studio.local", "kestrel", "KESTREL"]),
]

/// Lowercase, accents and everything but ASCII letters and digits removed.
private func squash(_ s: String) -> String {
    String(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
}

private func leakPayload(_ x: String, at place: Place) -> JSONValue {
    let plain = "Could not install app (0xe8008018)."
    let deep: JSONValue = [
        "error": [
            "domain": place == .domain ? .string(x) : "MIInstallerErrorDomain", "code": 13,
            "userInfo": [
                "NSLocalizedDescription": msg(place == .deepError ? x : plain),
                "LegacyErrorString": msg(place == .legacy ? x : "ApplicationVerificationFailed"),
            ],
        ]
    ]
    return [
        "info": ["outcome": place == .outcome ? .string(x) : "failed"],
        "error": [
            "domain": "com.apple.dt.CoreDeviceError", "code": 3002,
            "userInfo": [
                "NSLocalizedDescription": msg(place == .description ? x : "Failed to install the app on the device."),
                "NSUnderlyingError": [
                    "error": [
                        "domain": "IXUserPresentableErrorDomain", "code": 14,
                        "userInfo": [
                            "NSLocalizedFailureReason": msg(place == .failureReason ? x : "Unable to Install “Canary”"),
                            "NSUnderlyingError": [
                                "error": [
                                    "domain": "wrapper", "code": 4000,
                                    "userInfo": ["NSUnderlyingError": deep],
                                ]
                            ],
                        ],
                    ]
                ],
            ],
        ],
    ]
}

@Suite("canary evidence: leaks")
struct CanaryEvidenceLeakTests {
    @Test("every string that ever leaked is left out and counted, whichever field it arrives in", arguments: Place.allCases)
    func table(place: Place) async throws {
        for world in leakWorlds {
            for x in world.strings {
                var scenario = CanaryScenario(
                    install: InstallScript(
                        code: 1, payload: leakPayload(x, at: place), stderr: place == .stderr ? x : ""),
                    hostnames: world.hostnames)
                scenario.deviceName = world.deviceName
                scenario.localUser = world.user
                let config = canaryConfig {
                    $0.devices["iphone"]?.name = world.deviceName
                    $0.devices["iphone"]?.hostnames = world.hostnames
                }
                try await withCanaryWorld(scenario, config: config) { w in
                    let out = await w.run(evidenceOptions)
                    #expect(out.data["evidence"]?["written"] == true, "\(place) \(x.prefix(8)): bundle must be written")
                    #expect(warningCodes(out) == [], "\(place) \(x.prefix(8))")
                    let e = try readJSON(bundlePath(w, "evidence.json"))
                    let o = e["install"]?["omitted"]
                    let omitted = ["nodes", "messages", "stderrLines"].reduce(0.0) {
                        if case .number(let n)? = o?[$1] { return $0 + n } else { return $0 }
                    }
                    #expect(omitted > 0, "\(place) \(x.prefix(8)): nothing was counted as left out")
                    let squashedX = squash(x)
                    for file in ["evidence.json", "evidence.txt"] {
                        let body = squash(try readText(bundlePath(w, file)))
                        #expect(!body.contains(squashedX), "\(place) \(x.prefix(8)) in \(file)")
                        for word in world.words { #expect(!body.contains(word), "\(place) \(word) in \(file)") }
                    }
                }
            }
        }
    }

    @Test("a hyphen-free ID is not echoed in any file of the run")
    func ids() async throws {
        var scenario = CanaryScenario(
            install: InstallScript(code: 1, payload: leakPayload(udidBare, at: .description), stderr: coreBare))
        scenario.localUser = LocalUser(login: "pat")
        try await withCanaryWorld(scenario) { w in
            let out = await w.run(evidenceOptions)
            var all = try readText(bundlePath(w, "evidence.json")) + (try readText(bundlePath(w, "evidence.txt")))
            all += try out.printed().text + (try readText(w.paths.canaryLog))
            for id in [udidBare, udidBare.lowercased(), coreBare, coreBare.lowercased(), savedUdid("1"), savedCoreId("1")] {
                #expect(!all.contains(id), "\(id.prefix(6))")
            }
        }
    }

    @Test("a device named Den leaves a vocabulary word containing `den` intact")
    func overMaskDevice() async throws {
        let payload = try installFixture("install-blocked-8018-text.json")
        var scenario = CanaryScenario(install: InstallScript(code: 1, payload: payload))
        scenario.deviceName = "Den"
        let config = canaryConfig { $0.devices["iphone"]?.name = "Den" }
        try await withCanaryWorld(scenario, config: config) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["evidence"]?["written"] == true && warningCodes(out) == [])
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(
                e["install"]?["errorChain"]?.array?.first?["description"]
                    == "The identity used to sign the executable is no longer valid. Please verify that your device's clock is properly set.")
            #expect(e["run"]?["reason"]?.string?.contains("signing identity") == true)
            #expect(e["install"]?["omitted"]?["messages"] == 0)
        }
    }

    @Test("a full name of Will omits the one message that says `will`, alters nothing, and leaves the team alone")
    func overMaskName() async throws {
        let payload: JSONValue = [
            "info": ["outcome": "failed"],
            "error": [
                "domain": "com.apple.dt.CoreDeviceError", "code": 3002,
                "userInfo": [
                    "NSLocalizedDescription": msg("It will retry later."),
                    "NSLocalizedFailureReason": msg("Failed to install the app on the device."),
                ],
            ],
        ]
        var scenario = CanaryScenario(install: InstallScript(code: 1, payload: payload))
        scenario.localUser = LocalUser(login: "pat", fullName: "Will")
        try await withCanaryWorld(scenario) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["evidence"]?["written"] == true && warningCodes(out) == [])
            let e = try readJSON(bundlePath(w, "evidence.json"))
            let first = try #require(e["install"]?["errorChain"]?.array?.first)
            #expect(first["description"] == .null)
            #expect(first["failureReason"] == "Failed to install the app on the device.")
            #expect(e["install"]?["omitted"]?["messages"] == 1)
            #expect(e["team"] == "7AGMPUPP64" && e["codesign"]?["teamIdentifier"] == "7AGMPUPP64")
            #expect(!squash(try readText(bundlePath(w, "evidence.json"))).contains("willretry"))
        }
    }

    @Test("a common name ending in the team ID does not make the team ID a subject")
    func overMaskTeam() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            let tree = try readJSON(bundlePath(w, "evidence.json"))
            let text = try readText(bundlePath(w, "evidence.txt"))
            let subjects = SubjectTokens.make(
                EvidenceSubjects(
                    ids: [savedUdid("1")], login: "pat", fullName: "Pat Q. Tester",
                    identityNames: ["Apple Development: Pat Tester (7AGMPUPP64)"]))
            #expect(!subjects.tokens.contains("7agmpupp64"))
            #expect(
                EvidenceVerifier.hits(
                    tree: tree, bodies: [text], tokens: subjects.tokens, ids: subjects.ids, bundleId: canaryBundle) == [])
            #expect(tree["team"] == "7AGMPUPP64" && tree["keychainCertificate"]?["ou"] == "7AGMPUPP64")
        }
    }

    @Test("the run reason is left out when it is not all Apple-template or sideload words; the code survives")
    func reasonFiltered() async throws {
        var scenario = CanaryScenario(buildFails: true)
        scenario.buildStderr = "error: no profile for Apple Development: Jane Doe (ABCDE12345) in /Users/alice/p (\(savedUdid("1"))) jane.doe@example.invalid"
        try await withCanaryWorld(scenario) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["code"] == "BUILD_FAILED" && out.data["evidence"]?["written"] == true)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["run"]?["reason"] == .null && e["run"]?["code"] == "BUILD_FAILED")
            let body = try readText(bundlePath(w, "evidence.json")) + (try readText(bundlePath(w, "evidence.txt")))
            for secret in [savedUdid("1"), "Jane Doe", "ABCDE12345", "alice", "example.invalid"] {
                #expect(!body.contains(secret), "\(secret.prefix(6))")
            }
            #expect(try readText(bundlePath(w, "evidence.txt")).contains("reason: unavailable"))
        }
        var plain = CanaryScenario(buildFails: true)
        plain.buildStderr = ""
        try await withCanaryWorld(plain) { w in
            _ = await w.run(evidenceOptions)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["run"]?["reason"] == "xcodebuild failed with exit code 65.")
        }
    }
}

// MARK: - the local install log keeps the old denylist masker

@Suite("canary evidence: the local install log")
struct CanaryInstallLogTests {
    private static let name = "Jane's iPhone"
    private static let host = "jane-phone.local"
    private static let identity = "Apple Development: Jane Doe (ABCDE12345)"
    private static let email = "jane.doe@example.invalid"

    @Test("canary-install-*.json is still masked, and nothing from the run leaks anywhere (log, jsonl, envelope, bundle)")
    func poisoned() async throws {
        let udid = savedUdid("1"), core = savedCoreId("1")
        let user = "pat"  // the fake world's login name
        let poison =
            "Failed for \(udid) / \(core) / \(udid.lowercased()) on \(Self.name) (\(Self.host)) as \(Self.identity) at /Users/alice/x and /Users/\(user)/Library by \(Self.email)"
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(["error", "userInfo", "NSLocalizedDescription", "string"], to: .string(poison + " 0xe8008018"))
            .setting(["error", "userInfo", "extra"], to: .string(poison))
            .setting(["info", "environment"], to: ["HOME": "/Users/alice"])
        var scenario = CanaryScenario(
            install: InstallScript(code: 1, payload: payload, stderr: poison), hostnames: [Self.host])
        scenario.deviceName = Self.name
        let config = canaryConfig {
            $0.devices["iphone"]?.name = Self.name
            $0.devices["iphone"]?.hostnames = [Self.host]
        }
        try await withCanaryWorld(scenario, config: config) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.data["evidence"]?["written"] == true, "the poison is left out of the bundle, which is still written")
            var everything = try out.printed().text
            everything += try readText(bundlePath(w, "evidence.json"))
            everything += try readText(bundlePath(w, "evidence.txt"))
            everything += try readText(w.paths.canaryLog)
            for f in w.savedInstalls { everything += try w.savedInstall(f) }
            everything += w.logged.joined()
            #expect(w.savedInstalls.count == 1)
            let secrets = [
                udid, udid.lowercased(), core, Self.name, Self.host, "Jane Doe", "ABCDE12345", "/Users/alice",
                "/Users/\(user)", Self.email, "jane.doe",
            ]
            for secret in secrets { #expect(!everything.contains(secret), "\(secret.prefix(6))...") }
            #expect(!everything.contains("Apple Development: "))
            #expect(!everything.contains(w.paths.home))
        }
    }

    @Test("name, hostname, ID, person and identity variants are masked in the saved install log")
    func variants() async throws {
        let udid = savedUdid("1"), core = savedCoreId("1")
        let bareUdid = udid.replacingOccurrences(of: "-", with: "")
        let bareCore = core.replacingOccurrences(of: "-", with: "")
        let texts = [
            "Jane's iPhone", "jane’s iphone", "JANE'S IPHONE", "Janes-iPhone.local", "Jane-Phone.local", "jane-phone",
            "JANE-PHONE", "jane-phone.coredevice.local", bareUdid, bareUdid.lowercased(), bareCore, bareCore.lowercased(),
            udid.lowercased(), "ROBIN", "Robin’s iPhone", "robin", "Quinlan", "/users/robin/x", "/Users/Robin/y",
            "Apple Development: Test (TEST000001)", "TEST000001", "test000001", "jane%40example.com",
            "Kestrel’s Mac Studio", "kestrel-studio", "Kestrels-Mac-Studio.local",
        ]
        let poison = texts.joined(separator: " | ")
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(["error", "userInfo", "NSLocalizedDescription", "string"], to: .string(poison + " 0xe8008018"))
            .setting(["error", "userInfo", "extra"], to: .string(poison))
            .setting(["error", "userInfo", "Jane’s iPhone"], to: .string("key variant"))
            .setting(["error", "userInfo", "ROBIN"], to: .string("login as a key"))
        var scenario = CanaryScenario(
            install: InstallScript(code: 1, payload: payload, stderr: poison), hostnames: ["jane-phone.local"])
        scenario.deviceName = "Jane’s iPhone"
        scenario.localUser = LocalUser(
            login: "robin", fullName: "Robin Quinlan", homeDirectory: "/Users/robin",
            computerName: "Kestrel’s Mac Studio", localHostName: "kestrel-studio")
        let config = canaryConfig {
            $0.devices["iphone"]?.name = "Jane’s iPhone"
            $0.devices["iphone"]?.hostnames = ["jane-phone.local"]
        }
        try await withCanaryWorld(scenario, config: config) { w in
            _ = await w.run(evidenceOptions)
            let saved = try w.savedInstalls.map { try w.savedInstall($0) }.joined().lowercased()
                .replacingOccurrences(of: "\u{2019}", with: "'")
            #expect(!saved.isEmpty)
            for secret in ["jane's iphone", "janes-iphone", "jane-phone", bareUdid, bareCore, udid, core, "robin", "quinlan", "/users/robin", "test000001", "%40", "kestrel"] {
                #expect(!saved.contains(secret.lowercased()), "\(secret.prefix(8))...")
            }
        }
    }

    @Test("the bundle never reads the saved log: a bundle is the same with or without one")
    func independent() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            #expect(w.savedInstalls.count == 1)
            let e = try readJSON(bundlePath(w, "evidence.json"))
            #expect(e["install"]?["errorChain"]?.array?.count == 2)
            for file in ["evidence.json", "evidence.txt"] {
                #expect(!(try readText(bundlePath(w, file))).contains("<device>"))
            }
        }
    }
}

// MARK: - the verifier does not trust the reducer

@Suite("canary evidence: the verifier")
struct CanaryEvidenceVerifierTests {
    private static let subjects = EvidenceSubjects(
        ids: [savedUdid("1"), savedCoreId("1")], names: ["Jane’s iPhone", "jane-phone.local", "Zoë"], login: "robin",
        fullName: "Robin Quinlan")
    private static let tokens = SubjectTokens.make(subjects)

    private func hits(_ tree: JSONValue, bodies: [String] = []) -> [String] {
        EvidenceVerifier.hits(
            tree: tree, bodies: bodies, tokens: Self.tokens.tokens, ids: Self.tokens.ids, bundleId: canaryBundle)
    }

    /// The tree and both bodies of a real blocked run.
    private func baseline() async throws -> (tree: JSONValue, bodies: [String]) {
        var result: (JSONValue, [String])?
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run(evidenceOptions)
            result = (
                try readJSON(bundlePath(w, "evidence.json")),
                [try readText(bundlePath(w, "evidence.json")), try readText(bundlePath(w, "evidence.txt"))]
            )
        }
        return try #require(result)
    }

    private func node(_ fields: [String: JSONValue]) -> JSONValue {
        var n: [String: JSONValue] = ["depth": 0, "domain": "d", "code": 1, "codeHex": "0x00000001"]
        n.merge(fields) { _, new in new }
        return .object(n)
    }

    private func tree(install: [String: JSONValue] = [:], run: [String: JSONValue] = [:]) -> JSONValue {
        var i: [String: JSONValue] = ["errorChain": [], "stderr": []]
        i.merge(install) { _, new in new }
        var r: [String: JSONValue] = ["status": "blocked", "code": "0xe8008018"]
        r.merge(run) { _, new in new }
        return ["schema": 2, "run": .object(r), "install": .object(i)]
    }

    @Test("a real bundle passes; so does one with every field null")
    func clean() async throws {
        let (t, bodies) = try await baseline()
        #expect(hits(t, bodies: bodies) == [])
        #expect(hits(["schema": 2, "install": .null, "run": .null]) == [])
    }

    @Test("a leak put straight into the tree, bypassing the reducer, is caught in every free-text path", arguments: [
        "Jane's iPhone", "JANE’S IPHONE", "Janes-iPhone.local", "jane-phone", "Robins-MacBook-Pro.local", "robins-mbp",
        "Quinlans-Mac", "Jane%27s%20iPhone", "Jane's+iPhone", "Janes iPhone", "J A N E", "Zoe", "Zoë", "ZOE\u{0308}",
        "a/b", "x@y", "a_b", "50% done", "<user>", "a=b", "a&b", "a#b", "a?b", "a\\b", "café", "tab\there", "line\nbreak",
    ])
    func freeText(leak: String) {
        let paths: [JSONValue] = [
            tree(run: ["reason": .string(leak)]),
            tree(install: ["errorChain": [self.node(["description": .string(leak)])]]),
            tree(install: ["errorChain": [self.node(["failureReason": .string(leak)])]]),
            tree(install: ["errorChain": [self.node(["recoverySuggestion": .string(leak)])]]),
            tree(install: ["errorChain": [self.node(["codeSignature": ["code": "0xe8008018", "message": .string(leak)]])]]),
            tree(install: ["stderr": [.string(leak)]]),
        ]
        for (i, t) in paths.enumerated() {
            #expect(hits(t).contains("free-text"), "path \(i) \(leak.prefix(8))")
        }
    }

    @Test("a leak in a field that has a shape is caught by the shape and by the subject check")
    func shapedFields() {
        #expect(hits(tree(install: ["errorChain": [node(["domain": "Robin"])]])).contains("free-text"))
        #expect(hits(tree(install: ["errorChain": [node(["domain": "has space"])]])).contains("wrong-shape"))
        #expect(hits(tree(install: ["errorChain": [node(["legacyErrorString": "Janes"])]])).contains("free-text"))
        #expect(hits(tree(install: ["outcome": "jane"])).contains("wrong-shape"))
        #expect(hits(tree(install: ["outcome": "Failed"])).contains("wrong-shape"))
        #expect(hits(["team": "Jane"]).contains("wrong-shape"))
        #expect(hits(["keychainCertificate": ["certFp": "janejane"]]).contains("wrong-shape"))
        #expect(hits(["profile": ["deviceTail4": "Jane's"]]).contains("wrong-shape"))
        #expect(hits(["environment": ["xcode": "Jane"]]).contains("wrong-shape"))
        #expect(hits(["bundleId": "Jane's iPhone"]).contains("wrong-shape"))
        #expect(hits(tree(run: ["code": "Jane's iPhone"])).contains("wrong-shape"))
        #expect(hits(tree(install: ["errorChain": [node(["libMISErrorNumber": "1e19"])]])).contains("wrong-shape"))
        #expect(hits(tree(install: ["errorChain": [node(["codeHex": "0xE8008018"])]])).contains("wrong-shape"))
    }

    @Test("domain, LegacyErrorString and outcome are checked against every subject token, of any length")
    func shortTokens() {
        let den = SubjectTokens.make(EvidenceSubjects(names: ["Den’s iPhone"], login: "Den"))
        func check(_ t: JSONValue) -> [String] {
            EvidenceVerifier.hits(tree: t, bodies: [], tokens: den.tokens, ids: [], bundleId: canaryBundle)
        }
        #expect(check(tree(install: ["errorChain": [node(["domain": "deniphone"])]])).contains("free-text"))
        #expect(check(tree(install: ["errorChain": [node(["legacyErrorString": "DenIPhone"])]])).contains("free-text"))
        #expect(check(tree(install: ["outcome": "failed"])) == [])
        let ok = SubjectTokens.make(EvidenceSubjects(names: ["fai"]))
        #expect(
            EvidenceVerifier.hits(tree: tree(install: ["outcome": "failed"]), bodies: [], tokens: ok.tokens, ids: [], bundleId: canaryBundle)
                .contains("free-text"))
        #expect(check(tree(install: ["errorChain": [node(["description": "The identity is valid."])]])) == [], "messages keep the four-or-more rule")
    }

    @Test("an unknown key fails closed, wherever it is")
    func unknownKeys() {
        #expect(hits(["schema": 2, "extra": "x"]).contains("unknown-key"))
        #expect(hits(tree(install: ["devicectlJson": ["error": "x"]])).contains("unknown-key"))
        #expect(hits(tree(install: ["errorChain": [node(["NSURL": "x"])]])).contains("unknown-key"))
        #expect(hits(tree(install: ["omitted": ["nodes": 0, "other": 1]])).contains("unknown-key"))
        #expect(hits(tree(run: ["errorText": "x"])).contains("unknown-key"))
        #expect(hits(tree(install: ["errorChain": [node(["codeSignature": ["path": "x"]])]])).contains("unknown-key"))
        #expect(hits(["install": ["errorChain": [["domain": "d", "extra": [1]]]]]).contains("unknown-key"))
        #expect(hits(.array([])) == ["wrong-type"])
    }

    @Test("wrong types fail: an object where a string goes, a string where an array goes")
    func wrongTypes() {
        #expect(hits(tree(run: ["reason": ["a": "b"]])).contains("wrong-type"))
        #expect(hits(tree(install: ["errorChain": "x"])).contains("wrong-type"))
        #expect(hits(tree(install: ["stderr": [5]])).contains("wrong-type"))
        #expect(hits(tree(install: ["timedOut": "no"])).contains("wrong-type"))
        #expect(hits(tree(install: ["exitCode": 1.5])).contains("wrong-type"))
        #expect(hits(["schema": 3]).contains("wrong-value"))
        #expect(hits(["appleCase": "1"]).contains("wrong-shape"))
        #expect(hits(["appleCase": 555000111222]).contains("wrong-type"))
    }

    @Test("the bundle ID and quoted Canary are not subjects, even when a subject is named like them")
    func allowed() {
        let canaryNamed = SubjectTokens.make(EvidenceSubjects(names: ["Canary"]))
        let t = tree(install: ["errorChain": [node(["description": "Unable to Install “Canary”"])]])
        #expect(EvidenceVerifier.hits(tree: t, bodies: [], tokens: canaryNamed.tokens, ids: [], bundleId: canaryBundle) == [])
        let b = tree(run: ["reason": .string("Install of \(canaryBundle) failed.")])
        let sideload = SubjectTokens.make(EvidenceSubjects(names: ["sideload"]))
        #expect(EvidenceVerifier.hits(tree: b, bodies: [], tokens: sideload.tokens, ids: [], bundleId: canaryBundle) == [])
    }

    @Test("both rendered files are checked: @, /users in any case, long mixed hex, and the IDs without hyphens")
    func bodies() {
        let ok: JSONValue = ["schema": 2]
        #expect(hits(ok, bodies: ["fine: 2026-10-19T12:00:00Z 0xe8008018 …AAA1 abcdef12 123456789012 7AGMPUPP64"]) == [])
        #expect(hits(ok, bodies: ["a@b"]) == ["at-sign"])
        #expect(hits(ok, bodies: ["icon@2x"]) == ["at-sign"])
        for path in ["/users/x", "/Users/X", "/USERS/<user>", "C:/uSeRs/"] {
            #expect(hits(ok, bodies: [path]) == ["users-path"], "\(path)")
        }
        #expect(hits(ok, bodies: ["ab12cd34e"]) == ["hex-run"])
        #expect(hits(ok, bodies: ["x 1A2B3C4D5E6F x"]) == ["hex-run"])
        #expect(hits(ok, bodies: ["abcdefabcdef 123456789012"]) == [], "all letters or all digits is not an ID")
        let udid = savedUdid("1"), core = savedCoreId("1")
        for id in [udid, udid.lowercased(), udid.replacingOccurrences(of: "-", with: ""), core,
            core.lowercased(), core.replacingOccurrences(of: "-", with: "").lowercased()]
        {
            #expect(hits(ok, bodies: ["x \(id) y"]).contains("device-id"), "\(id.prefix(6))")
        }
        #expect(hits(ok, bodies: ["…AAA1"]) == [])
    }

    @Test("a bundle that fails the verifier is never written: the writer returns redactionFailed and leaves nothing")
    func writerFailsClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        let leak = tree(run: ["reason": "Jane’s iPhone"])
        let out = EvidenceWriter.write(leak, stamp: "t", home: paths, tokens: Self.tokens, bundleId: canaryBundle)
        #expect(out == .redactionFailed)
        #expect(!FileManager.default.fileExists(atPath: paths.evidence))
        let unknown = EvidenceWriter.write(["extra": "x"], stamp: "t", home: paths, tokens: Self.tokens, bundleId: canaryBundle)
        #expect(unknown == .redactionFailed)
        #expect(
            EvidenceWriter.write(["schema": 2], stamp: "t", home: paths, tokens: Self.tokens, bundleId: canaryBundle)
                == .written(dir: "evidence/canary-t", files: ["evidence.json", "evidence.txt"]))
    }

    @Test("a verifier trip in a real run: no bundle, EVIDENCE_REDACTION_FAILED, the result untouched, no text repeated")
    func endToEnd() async throws {
        // The one way an ID reaches the bundle past the reducer: the owner's bundle ID prefix (a generated field,
        // allowed by decision) embeds it. Only the verifier's whole-body check sees that.
        let config = canaryConfig { $0.bundleIdPrefix = "com." + udidBare.lowercased() }
        try await withCanaryWorld(try blocked(), config: config) { w in
            let out = await w.run(evidenceOptions)
            #expect(out.ok && out.exitCode == 0 && out.data["status"] == "blocked")
            #expect(warningCodes(out) == ["EVIDENCE_REDACTION_FAILED"])
            #expect(out.data["evidence"] == ["written": false, "dir": .null, "files": []])
            #expect(!FileManager.default.fileExists(atPath: w.paths.evidence))
            let logged = try w.jsonlLines
            #expect(logged.count == 1)
            let message = out.data["warnings"]?.array?.first?["message"]?.string ?? ""
            #expect(!message.lowercased().contains(udidBare.lowercased()), "the warning never repeats the match")
        }
    }

    @Test("every canary.jsonl line passes check A (all its fields are ours)")
    func logLines() async throws {
        let scenarios = [
            try blocked(), CanaryScenario(), CanaryScenario(install: .timeout), CanaryScenario(profileTeam: "ZZZZZZZZZZ"),
            CanaryScenario(signedTeam: "ZZZZZZZZZZ"), CanaryScenario(free: true), CanaryScenario(buildFails: true),
        ]
        for scenario in scenarios {
            try await withCanaryWorld(scenario) { w in
                _ = await w.run()
                let lines = try w.jsonlLines
                #expect(lines.count == 1)
                for line in lines { #expect(EvidenceVerifier.logLineHits(line) == [], "\(line)") }
            }
        }
        #expect(EvidenceVerifier.logLineHits(["ts": "2026-10-19T12:00:00.000Z", "name": "Jane"]) == ["unknown-key"])
        #expect(EvidenceVerifier.logLineHits(["certFp": "ABCDEF12"]) == ["wrong-shape"])
    }
}

@Suite("canary evidence: rendering")
struct CanaryEvidenceRenderTests {
    @Test("the fingerprint is the first 8 hex digits, lowercase")
    func fingerprintShape() {
        #expect(EvidenceBuilder.certFp("ABCDEF0123456789ABCDEF0123456789ABCDEF01") == "abcdef01")
    }

    @Test("the builder leaves out a value that is not the shape we expect instead of writing it")
    func builderShapes() {
        let input = EvidenceInput(
            generatedAt: testNow, status: "blocked", code: "Jane's iPhone", reason: nil, guardRecord: "passed",
            durationMs: 0, bundleId: canaryBundle, macosVersion: "27.0; x", macosBuild: "27A100", xcode: "see /Users/x",
            iosVersion: nil, iosBuild: nil, certificate: nil, certFp: "ABC", guardFacts: .init(signedTeam: "Jane", profileTeam: "7AGMPUPP64"),
            deviceTail4: "…AAA1", install: nil)
        let t = EvidenceBuilder.build(input)
        #expect(t["run"]?["code"] == .null && t["environment"]?["macos"]?["version"] == .null)
        #expect(t["environment"]?["macos"]?["build"] == "27A100" && t["environment"]?["xcode"] == .null)
        #expect(t["keychainCertificate"]?["certFp"] == .null && t["codesign"]?["teamIdentifier"] == .null)
        #expect(t["profile"]?["team"] == "7AGMPUPP64" && t["install"] == .null)
        #expect(EvidenceVerifier.hits(tree: t, bodies: [], tokens: [], ids: [], bundleId: canaryBundle) == [])
    }

    @Test("evidence.txt lists arrays by index and says `none` for an empty one")
    func textArrays() {
        let tree: JSONValue = [
            "schema": 2,
            "install": ["errorChain": [], "stderr": ["one", "two"], "omitted": ["nodes": 0]],
        ]
        let text = EvidenceText.render(tree)
        #expect(text.contains("errorChain: none\n") && text.contains("stderr[0]: one\n") && text.contains("stderr[1]: two\n"))
        #expect(text.contains("\n[install]\n") && text.contains("omitted.nodes: 0\n"))
    }
}

@Suite("canary evidence: log fields and parsers")
struct CanaryEvidenceLogTests {
    @Test("the log line gains macosVersion, iosVersion, certFp and certNotAfter; the originals are intact")
    func newLogFields() async throws {
        try await withCanaryWorld(try blocked()) { w in
            _ = await w.run()
            let line = try #require(try w.jsonlLines.first)
            #expect(line["macosVersion"] == "27.0.1")
            #expect(line["iosVersion"] == "27.0.1")
            #expect(line["certFp"]?.string?.count == 8)
            #expect(line["certNotAfter"] == "2027-10-16")
            #expect(line["status"] == "blocked" && line["code"] == "0xe8008018")
            #expect(line["xcodeVersion"] == "27.0 (27A266a)" && line["guard"] == "passed")
            #expect(line["device"] == .string("…" + savedUdid("1").suffix(4)))
        }
    }

    @Test("a run that stops early logs the new fields as null where it never learned them")
    func earlyFields() async throws {
        try await withCanaryWorld(CanaryScenario(signedTeam: "ZZZZZZZZZZ")) { w in
            _ = await w.run()
            let line = try #require(try w.jsonlLines.first)
            #expect(line["iosVersion"] == .null, "no device listing after a failed guard")
            #expect(line["certFp"]?.string?.count == 8)
        }
    }

    @Test("every line stays under PIPE_BUF (512 bytes) so the append is atomic")
    func lineSize() async throws {
        let scenarios = [try blocked(), CanaryScenario(), CanaryScenario(install: .timeout), CanaryScenario(profileTeam: "ZZZZZZZZZZ")]
        for scenario in scenarios {
            try await withCanaryWorld(scenario) { w in
                _ = await w.run(evidenceOptions)
                for line in try readText(w.paths.canaryLog).split(separator: "\n") {
                    #expect(line.utf8.count + 1 <= 512, "\(line.utf8.count)")
                }
            }
        }
    }

    @Test("an overlong code or Xcode label is clipped so the line cannot outgrow the atomic size")
    func clipped() async throws {
        var scenario = try blocked()
        scenario.xcodeVersion = String(repeating: "9", count: 600)
        try await withCanaryWorld(scenario) { w in
            _ = await w.run()
            for line in try readText(w.paths.canaryLog).split(separator: "\n") {
                #expect(line.utf8.count + 1 <= 512)
            }
        }
    }

    @Test("the profile parser reads CreationDate, ExpirationDate and the SHA-1 of each DeveloperCertificates entry")
    func profileParser() throws {
        let xml = profileXML(
            team: "7AGMPUPP64", devices: [], created: "2026-10-01T08:00:00Z", expires: "2027-10-01T08:00:00Z",
            certs: [TestCerts.paid, TestCerts.other])
        let p = try #require(Guard.parseProfile(xml))
        #expect(p.creation == Date(timeIntervalSince1970: 1_790_841_600))
        #expect(p.expiration == Date(timeIntervalSince1970: 1_822_377_600))
        #expect(p.certFingerprints == [try fingerprint(TestCerts.paid), try fingerprint(TestCerts.other)])
        let bare = try #require(Guard.parseProfile(profileXML(team: "7AGMPUPP64", devices: [])))
        #expect(bare.creation == nil && bare.expiration == nil && bare.certFingerprints.isEmpty)
    }

    @Test("a decoy DeveloperCertificates or date nested in Entitlements is ignored")
    func profileDecoy() throws {
        let xml = """
            <plist version="1.0"><dict>
              <key>Entitlements</key><dict>
                <key>ExpirationDate</key><date>2020-01-01T00:00:00Z</date>
                <key>DeveloperCertificates</key><array><data>AAAA</data></array>
              </dict>
            </dict></plist>
            """
        let p = try #require(Guard.parseProfile(xml))
        #expect(p.expiration == nil && p.certFingerprints.isEmpty)
    }

    @Test("Guard.run records the facts and checks the signing certificate against the profile")
    func guardFacts() async throws {
        let app = "/fake/Canary.app"
        let xml = profileXML(
            team: "7AGMPUPP64", devices: [savedUdid("1"), savedUdid("2")], created: "2026-10-01T08:00:00Z",
            expires: "2027-10-01T08:00:00Z", certs: [TestCerts.paid])
        let runner = FakeRunner {
            $0.executable == "/usr/bin/codesign" ? RunResult(stderr: "TeamIdentifier=7AGMPUPP64\n") : RunResult(stdout: xml)
        }
        let paid = try fingerprint(TestCerts.paid)
        let g = await Guard.run(runner: runner, app: app, udid: savedUdid("1"), signingCert: paid)
        #expect(g == .pass)
        #expect(g.facts?.signedTeam == "7AGMPUPP64" && g.facts?.profileTeam == "7AGMPUPP64")
        #expect(g.facts?.deviceCount == 2 && g.facts?.deviceIncluded == true)
        #expect(g.facts?.signingCertInProfile == true)
        #expect(g.facts?.profileExpires == Date(timeIntervalSince1970: 1_822_377_600))
        let other = await Guard.run(runner: runner, app: app, udid: savedUdid("1"), signingCert: try fingerprint(TestCerts.other))
        #expect(other.facts?.signingCertInProfile == false)
        let unchecked = await Guard.run(runner: runner, app: app, udid: savedUdid("1"))
        #expect(unchecked.facts?.signingCertInProfile == nil)
        let missing = await Guard.run(runner: runner, app: app, udid: savedUdid("7"), signingCert: paid)
        #expect(missing.code == "DEVICE_NOT_IN_PROFILE" && missing.facts?.deviceIncluded == false)
    }

    @Test("the device list reads osVersionNumber and osBuildUpdate from deviceProperties")
    func osVersionParsing() {
        let entry = deviceEntryJSON(
            name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), osVersion: "27.0.1", osBuild: "24A446")
        let d = DeviceList.parse(deviceListJSON(entry)).first
        #expect(d?.osVersion == "27.0.1" && d?.osBuild == "24A446")
        let modern = DeviceList.parse(
            deviceListJSON(
                ["identifier": "x", "properties": ["state": ["osVersionNumber": "26.4", "osBuildUpdate": "23E1"]]])
        ).first
        #expect(modern?.osVersion == "26.4" && modern?.osBuild == "23E1")
        #expect(DeviceList.parse(deviceListJSON(deviceEntryJSON(name: "n", udid: "u", coreId: "c"))).first?.osVersion == nil)
    }

    @Test("a malformed version or build is dropped", arguments: ["", "27.", "27.0.1.2", "v27", "27.0; x", "a@b.c", "27 0"])
    func osVersionValidation(bad: String) {
        let entry = deviceEntryJSON(
            name: "n", udid: savedUdid("1"), coreId: savedCoreId("1"), osVersion: bad, osBuild: bad + "/" + bad)
        let d = DeviceList.parse(deviceListJSON(entry)).first
        #expect(d?.osVersion == nil && d?.osBuild == nil)
    }

    @Test("the certificate reader reports notBefore next to notAfter")
    func notBefore() throws {
        let cert = try keychainCert(TestCerts.paid)
        #expect(cert.info.notBefore == utcDate(2026, 1, 1))
        #expect(cert.info.notAfter == Date(timeIntervalSince1970: 1_823_726_382))
        let multi = try keychainCert(TestCerts.multi)
        #expect(multi.info.notBefore == utcDate(2026, 1, 1))
    }

    @Test("selectedPaid: the valid paid certificate with the latest notAfter, shared with `evaluate`")
    func selectedPaid() {
        func cert(_ ref: String, _ ous: [String], _ year: Int, valid: Bool = true) -> KeychainCertificate {
            KeychainCertificate(
                reference: ref, info: CertInfo(ous: ous, notAfter: utcDate(year, 6, 1)), isValidForCodeSigning: valid)
        }
        let now = utcDate(2026, 10, 19)
        let early = cert("EARLY", ["7AGMPUPP64"], 2027), late = cert("LATE", ["7AGMPUPP64"], 2029)
        #expect(CertCheck.selectedPaid([early, late], now: now)?.reference == "LATE")
        #expect(CertCheck.selectedPaid([late, early], now: now)?.reference == "LATE")
        let ignored = [
            cert("UNTRUSTED", ["7AGMPUPP64"], 2035, valid: false), cert("FREE", ["6ZU5Z6ZKK7"], 2035),
            cert("OTHER", ["TESTTEAM01"], 2035), cert("MIXED", ["7AGMPUPP64", "6ZU5Z6ZKK7"], 2035),
            cert("EXPIRED", ["7AGMPUPP64"], 2025),
        ]
        #expect(CertCheck.selectedPaid(ignored + [early], now: now)?.reference == "EARLY")
        #expect(CertCheck.selectedPaid(ignored, now: now) == nil)
        #expect(CertCheck.selectedPaid([], now: now) == nil)
        #expect(
            CertCheck.evaluate([early, late], now: now).first?.message.contains("2029-06-01") == true,
            "evaluate reports the same certificate")
    }

    @Test("the evidence folder is lazy: ensureHome does not create it and the pinned subdirectories are unchanged")
    func lazyFolder() async throws {
        #expect(Paths.subdirectories == ["secrets", "downloads", "builds", "logs", "tmp"])
        try await withTestHome { paths, _ in
            #expect(paths.evidence == paths.home + "/evidence")
            #expect(!FileManager.default.fileExists(atPath: paths.evidence))
        }
    }
}

@Suite("canary history")
struct CanaryHistoryTests {
    private func line(
        _ ts: String, _ status: String, code: String = "c", xcode: String? = nil, macos: String? = nil,
        ios: String? = nil, fp: String? = nil, notAfter: String? = nil
    ) -> String {
        var f: [String: JSONValue] = [
            "ts": .string(ts), "status": .string(status), "code": .string(code), "device": "…ab12",
            "guard": "passed", "durationMs": 0,
        ]
        if let xcode { f["xcodeVersion"] = .string(xcode) }
        if let macos { f["macosVersion"] = .string(macos) }
        if let ios { f["iosVersion"] = .string(ios) }
        if let fp { f["certFp"] = .string(fp) }
        if let notAfter { f["certNotAfter"] = .string(notAfter) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(JSONValue.object(f)), as: UTF8.self)
    }

    private func history(_ lines: [String]?) async throws -> (Envelope, FakeRunner) {
        var result: (Envelope, FakeRunner)?
        try await withTestHome { paths, _ in
            if let lines {
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: paths.canaryLog))
            }
            let (services, runner) = fakeServices(paths)
            result = (CanaryHistory.run(services), runner)
        }
        return try #require(result)
    }

    @Test("no log: ok, zero runs, nothing to compare")
    func empty() async throws {
        let (out, runner) = try await history(nil)
        #expect(out.ok && out.command == "canary history")
        #expect(out.data["runs"] == 0 && out.data["skipped"] == 0)
        #expect(out.data["statusCounts"] == [:])
        #expect(out.data["first"] == .null && out.data["last"] == .null && out.data["lastWorking"] == .null)
        #expect(out.data["changes"] == .null && out.data["recent"] == [])
        #expect(runner.calls.isEmpty, "history runs nothing")
    }

    @Test("old-format lines (no new keys) parse; fields missing on a side are incomparable")
    func oldOnly() async throws {
        let (out, _) = try await history([
            line("2026-10-01T00:00:00.000Z", "working", xcode: "26.4 (26E1)"),
            line("2026-10-02T00:00:00.000Z", "blocked", code: "0xe8008018", xcode: "27.0 (27A1)"),
        ])
        #expect(out.data["runs"] == 2)
        #expect(out.data["lastWorking"]?["ts"] == "2026-10-01T00:00:00.000Z")
        #expect(out.data["firstBlockedAfterWorking"]?["ts"] == "2026-10-02T00:00:00.000Z")
        #expect(
            out.data["changes"] == [["field": "xcodeVersion", "from": "26.4 (26E1)", "to": "27.0 (27A1)"]])
        #expect(out.data["incomparable"] == ["macosVersion", "iosVersion", "certFp", "certNotAfter"])
    }

    @Test("working, error, blocked: the first blocked after the last working, error skipped, changes listed")
    func workingErrorBlocked() async throws {
        let (out, _) = try await history([
            line("2026-10-01T00:00:00.000Z", "blocked", xcode: "26.0"),
            line("2026-10-02T00:00:00.000Z", "working", xcode: "26.4", macos: "26.4", ios: "26.4", fp: "aaaaaaaa", notAfter: "2027-01-01"),
            line("2026-10-03T00:00:00.000Z", "error", code: "TIMEOUT", xcode: "27.0"),
            line("2026-10-04T00:00:00.000Z", "blocked", code: "0xe8008018", xcode: "27.0", macos: "27.0", ios: "26.4", fp: "aaaaaaaa", notAfter: "2027-01-01"),
            line("2026-10-05T00:00:00.000Z", "blocked", xcode: "27.0", macos: "27.0", ios: "26.4", fp: "bbbbbbbb", notAfter: "2027-06-01"),
        ])
        #expect(out.data["statusCounts"] == ["working": 1, "blocked": 3, "error": 1])
        #expect(out.data["lastWorking"]?["ts"] == "2026-10-02T00:00:00.000Z")
        #expect(out.data["firstBlockedAfterWorking"]?["ts"] == "2026-10-04T00:00:00.000Z")
        #expect(out.data["firstBlocked"]?["ts"] == "2026-10-01T00:00:00.000Z")
        #expect(
            out.data["changes"] == [
                ["field": "xcodeVersion", "from": "26.4", "to": "27.0"],
                ["field": "macosVersion", "from": "26.4", "to": "27.0"],
            ])
        #expect(out.data["incomparable"] == [])
        #expect(out.data["first"]?["ts"] == "2026-10-01T00:00:00.000Z")
        #expect(out.data["last"]?["ts"] == "2026-10-05T00:00:00.000Z")
    }

    @Test("a changed certificate and iOS version show up as changes")
    func certAndIOS() async throws {
        let (out, _) = try await history([
            line("2026-10-01T00:00:00.000Z", "working", xcode: "27.0", macos: "27.0", ios: "27.0", fp: "aaaaaaaa", notAfter: "2027-01-01"),
            line("2026-10-02T00:00:00.000Z", "blocked", xcode: "27.0", macos: "27.0", ios: "27.0.1", fp: "bbbbbbbb", notAfter: "2027-06-01"),
        ])
        let fields = out.data["changes"]?.array?.compactMap { $0["field"]?.string }
        #expect(fields == ["iosVersion", "certFp", "certNotAfter"])
    }

    @Test("never worked: lastWorking and changes are null, firstBlocked is set")
    func neverWorked() async throws {
        let (out, _) = try await history([
            line("2026-10-01T00:00:00.000Z", "error", code: "TIMEOUT"),
            line("2026-10-02T00:00:00.000Z", "blocked", code: "0xe8008018"),
        ])
        #expect(out.data["lastWorking"] == .null && out.data["changes"] == .null)
        #expect(out.data["firstBlockedAfterWorking"] == .null)
        #expect(out.data["firstBlocked"]?["ts"] == "2026-10-02T00:00:00.000Z")
    }

    @Test("works and never blocked since: nothing to compare")
    func stillWorking() async throws {
        let (out, _) = try await history([line("2026-10-01T00:00:00.000Z", "working"), line("2026-10-02T00:00:00.000Z", "error")])
        #expect(out.data["lastWorking"]?["ts"] == "2026-10-01T00:00:00.000Z")
        #expect(out.data["firstBlockedAfterWorking"] == .null && out.data["changes"] == .null)
    }

    @Test("blank and malformed lines are skipped; malformed ones are counted, blank ones are not")
    func malformed() async throws {
        let (out, _) = try await history([
            "", "not json", "{\"truncated\":", "[1,2]", "{\"x\":1}", "   ",
            line("2026-10-01T00:00:00.000Z", "blocked"), "{\"status\":5}",
        ])
        #expect(out.data["runs"] == 1)
        #expect(out.data["skipped"] == 5)
        #expect(out.data["last"]?["status"] == "blocked")
    }

    @Test("recent is the last ten runs in file order")
    func recent() async throws {
        let lines = (1...12).map { line(String(format: "2026-10-%02dT00:00:00.000Z", $0), "blocked") }
        let (out, _) = try await history(lines)
        let stamps = out.data["recent"]?.array?.compactMap { $0["ts"]?.string }
        #expect(stamps?.count == 10)
        #expect(stamps?.first == "2026-10-03T00:00:00.000Z" && stamps?.last == "2026-10-12T00:00:00.000Z")
        #expect(out.data["runs"] == 12)
    }

    @Test("history never prints the device tail or any identifier")
    func noIdentifiers() async throws {
        let (out, _) = try await history([line("2026-10-01T00:00:00.000Z", "blocked", xcode: "27.0")])
        let text = try out.printed().text
        #expect(!text.contains("…ab12") && !text.contains("\"device\""))
    }
}

@Suite("canary evidence: CLI")
struct CanaryEvidenceCLITests {
    private func code(_ out: Envelope) -> String? { out.errors.first?.code }

    @Test("--evidence is a canary flag and reaches the command")
    func flag() async throws {
        try await withCanaryWorld(try blocked()) { w in
            let out = await run(argv: ["canary", "--device", "iphone", "--yes", "--evidence"], services: w.services)
            #expect(out.data["status"] == "blocked")
            #expect(out.data["evidence"]?["written"] == true)
        }
        try await withCanaryWorld(try blocked()) { w in
            let out = await run(argv: ["canary", "--device", "iphone", "--yes"], services: w.services)
            #expect(out.data["evidence"] == nil)
        }
    }

    @Test("canary history runs without a config, a device or --yes, and reads the log")
    func history() async throws {
        try await withTestHome { paths, _ in
            try Data("{\"ts\":\"2026-10-01T00:00:00.000Z\",\"status\":\"blocked\",\"code\":\"c\"}\n".utf8)
                .write(to: URL(fileURLWithPath: paths.canaryLog))
            let (services, runner) = fakeServices(paths)
            let out = await run(argv: ["canary", "history"], services: services)
            #expect(out.ok && out.command == "canary history" && out.data["runs"] == 1)
            #expect(runner.calls.isEmpty)
            let held = try OperationLock.acquire(paths: paths)
            defer { held.release() }
            let again = await run(argv: ["canary", "history"], services: services)
            #expect(again.ok, "no operation lock")
        }
    }

    @Test("history takes no options; canary takes only the `history` positional", arguments: [
        ["canary", "history", "--yes"], ["canary", "history", "--device", "iphone"], ["canary", "history", "--keep"],
        ["canary", "history", "--evidence"], ["canary", "history", "extra"], ["canary", "history", "history"],
        ["canary", "other"], ["canary", "other", "--device", "iphone", "--yes"],
    ])
    func usage(argv: [String]) async throws {
        try await withCanaryWorld { w in
            #expect(code(await run(argv: argv, services: w.services)) == "USAGE")
            #expect(w.calls.isEmpty)
        }
    }

    @Test("help lists the history subcommand and --evidence; canary stays the only built canary entry")
    func help() async throws {
        try await withCanaryWorld { w in
            let out = await run(argv: ["help"], services: w.services)
            let usage = out.json["usage"]?.array?.compactMap(\.string) ?? []
            #expect(usage.contains { $0.contains("canary history") })
            #expect(usage.contains { $0.contains("--evidence") })
            #expect(out.json["built"] == ["doctor", "device", "canary", "ledger", "portal", "export-cert", "status", "inspect", "fetch", "provision", "sign", "install", "refresh", "app", "slot"])
        }
    }
}

// MARK: - fixes from the first real run (2026-10-20)

@Suite("canary evidence: first real run fixes")
struct CanaryEvidenceRealRunTests {
    /// A subject token of two or three letters sits inside Apple's domain (`ice` in `device`); synthetic values, the real chain's shape.
    private static let ice = SubjectTokens.make(EvidenceSubjects(names: ["Ice"]))

    private static func chain(_ domain: String) -> JSONValue {
        [
            "error": [
                "domain": .string(domain), "code": 3002,
                "userInfo": [
                    "NSLocalizedDescription": msg("Failed to install the app on the device."),
                    "NSUnderlyingError": ["error": ["domain": "MIInstallerErrorDomain", "code": 13, "userInfo": [:]]],
                ],
            ]
        ]
    }

    @Test("a known Apple domain is kept even when a short subject token sits inside it; an unknown one is still checked")
    func knownDomainKept() {
        #expect(Self.ice.tokens == ["ice"])
        let kept = reduce(Self.chain("com.apple.dt.CoreDeviceError"), tokens: Self.ice)
        #expect(kept.nodes.map(\.domain) == ["com.apple.dt.CoreDeviceError", "MIInstallerErrorDomain"])
        #expect(kept.omittedMessages == 0)
        let other = reduce(Self.chain("com.apple.dt.DeviceServiceError"), tokens: Self.ice)
        #expect(other.nodes.first?.domain == nil && other.omittedMessages == 1)
        #expect(reduce(Self.chain("xicex"), tokens: Self.ice).nodes.first?.domain == nil)
    }

    @Test("the verifier accepts the known domains whole with that token, and still rejects another domain that carries it")
    func verifierKnownDomain() {
        func hits(_ domain: String) -> [String] {
            let tree: JSONValue = ["install": ["errorChain": [["depth": 0, "domain": .string(domain), "code": 3002]]]]
            return EvidenceVerifier.hits(tree: tree, bodies: [], tokens: Self.ice.tokens, ids: [], bundleId: canaryBundle)
        }
        // Literal, so dropping an entry from both copies at once still fails here.
        let expected: Set<String> = [
            "com.apple.dt.CoreDeviceError", "IXUserPresentableErrorDomain", "MIInstallerErrorDomain",
            "com.apple.dt.MobileDeviceErrorDomain",
        ]
        for domain in expected { #expect(hits(domain) == [], "\(domain)") }
        #expect(hits("com.apple.dt.DeviceServiceError").contains("free-text"))
        #expect(hits("com.apple.dt.CoreDeviceError.x").contains("free-text"), "a near miss is not the known domain")
        #expect(ErrorChain.knownDomains == expected && EvidenceSchema.knownDomains == expected)
    }

    @Test("stderr separator rules are dropped silently: not emitted, not counted")
    func separatorLines() {
        let r = reduce(
            nil, stderr: ["----------------------------------------", "Could not install app (0xe8008018).", "=====", " * - * ", "see /var/x"].joined(separator: "\n"))
        #expect(r.stderr == ["Could not install app (0xe8008018)."])
        #expect(r.omittedStderrLines == 1, "only the line with words that was refused")
    }

    @Test("evidence.txt has a blank line between the header paragraph and the first key: value line")
    func headerBlankLine() {
        let text = EvidenceText.render(["schema": 2, "appleCase": "555000111222", "run": ["status": "blocked"]])
        #expect(text.contains("could not learn that value.\n\nappleCase: 555000111222\n"))
        #expect(!text.contains("\n\n\n"))
    }
}
