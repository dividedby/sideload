import Foundation
import Testing

@testable import SideloadCore

// Free-team policy (docs/design.md section 18, build step 2): the team constants, `isFreeTeam`, free identity
// selection and the pinned check, the identity snapshot diff, the doctor row, and `Guard(.free)`. Nothing here
// is reachable from a command yet; the paid paths must be unchanged.

private let prefix = "io.github.dividedby"
private let freeApp = "io.github.dividedby.free.stremio"
private let now = utcDate(2026, 10, 23)

private func hand(_ reference: String, ous: [String], valid: Bool = true, notAfter: Date? = nil) -> KeychainCertificate {
    KeychainCertificate(
        reference: reference, info: CertInfo(ous: ous, notAfter: notAfter ?? utcDate(2027, 10, 16)),
        isValidForCodeSigning: valid)
}

private func sha1(_ n: Int) -> String { String(repeating: String(n, radix: 16, uppercase: true), count: 40) }

@Suite("free team: constants and config")
struct FreeTeamConfigTests {
    @Test("Team.paid and Team.free; id and denied keep their paid-path meaning")
    func constants() {
        #expect(Team.paid == "7AGMPUPP64" && Team.free == "6ZU5Z6ZKK7")
        #expect(Team.id == Team.paid)
        #expect(Team.denied == [Team.free])
    }

    @Test("config.teamId and the paid parse path still reject the free OU as FREE_TEAM_SELECTED")
    func paidConfigRejectsFree() {
        let data = Data(#"{"teamId": "6ZU5Z6ZKK7"}"#.utf8)
        #expect(throws: SideloadError.self) { try Config.parse(data) }
        do { _ = try Config.parse(data) } catch let error as SideloadError { #expect(error.code == "FREE_TEAM_SELECTED") } catch {
            Issue.record("unexpected \(error)")
        }
        var config = Config()
        config.teamId = Team.free
        #expect(throws: SideloadError.self) { try config.validate() }
    }

    @Test("apps.<a>.team: absent is paid, \"free\" is free, anything else is CONFIG_INVALID without echoing it")
    func appTeam() throws {
        let config = Config(apps: [
            "plain": .object([:]), "free": .object(["team": .string("free")]),
            "paid": .object(["team": .string("paid")]), "num": .object(["team": .number(1)]),
            "odd": .object(["team": .string("6ZU5Z6ZKK7")]), "scalar": .string("x"),
        ])
        #expect(try config.appTeam("missing") == .paid)
        #expect(try config.appTeam("plain") == .paid)
        #expect(try config.appTeam("scalar") == .paid)
        #expect(try config.appTeam("free") == .free)
        #expect(try config.appTeam("paid") == .paid)
        for alias in ["num", "odd"] {
            do {
                _ = try config.appTeam(alias)
                Issue.record("expected CONFIG_INVALID for \(alias)")
            } catch let error as SideloadError {
                #expect(error.code == "CONFIG_INVALID")
                #expect(!error.message.contains("6ZU5Z6ZKK7"))
            }
        }
    }

    @Test("a config carrying apps.<a>.team round-trips and parses (decoded, unused)")
    func roundTrip() throws {
        let data = Data(#"{"apps": {"stremio": {"team": "free"}}, "bundleIdPrefix": "io.github.dividedby"}"#.utf8)
        let config = try Config.parse(data)
        #expect(try config.appTeam("stremio") == .free)
        #expect(try Config.parse(config.encoded()) == config)
    }

    @Test("only <prefix>.free.<name> is allowlisted")
    func allowlist() {
        #expect(Config.isFreeBundleId(freeApp, prefix: prefix))
        #expect(Config.isFreeBundleId("io.github.dividedby.free.stremio.tv", prefix: prefix))
        let rejected = [
            "io.github.dividedby.free.", "io.github.dividedby.free", "io.github.dividedby.free.*",
            "io.github.dividedby.free..x", "io.github.dividedby.sideload.canary", "io.github.dividedby.freeX.app",
            "io.github.dividedby.Free.app", "io.github.dividedby.free.app/../x", "com.facebook.WebDriverAgentRunner",
            "io.github.dividedby", "x.io.github.dividedby.free.app", "",
        ]
        for id in rejected { #expect(!Config.isFreeBundleId(id, prefix: prefix), "\(id)") }
        #expect(!Config.isFreeBundleId(freeApp, prefix: nil))
        #expect(!Config.isFreeBundleId(freeApp, prefix: "bad prefix"))
        #expect(!Config.isFreeBundleId(freeApp, prefix: "io.github.dividedby."))
    }
}

@Suite("free team: identities")
struct FreeIdentityTests {
    @Test("isFreeTeam: first OU free and the paid OU absent; both OUs is neither paid nor free")
    func isFreeTeam() {
        func info(_ ous: [String]) -> CertInfo { CertInfo(ous: ous) }
        #expect(info(["6ZU5Z6ZKK7"]).isFreeTeam)
        #expect(!info(["6ZU5Z6ZKK7"]).isPaidTeam)
        #expect(info(["6ZU5Z6ZKK7", "OTHER"]).isFreeTeam)
        #expect(!info(["6ZU5Z6ZKK7", "7AGMPUPP64"]).isFreeTeam)
        #expect(!info(["7AGMPUPP64", "6ZU5Z6ZKK7"]).isFreeTeam)
        #expect(!info(["7AGMPUPP64", "6ZU5Z6ZKK7"]).isPaidTeam)
        #expect(!info(["OTHER", "6ZU5Z6ZKK7"]).isFreeTeam)
        #expect(!info(["7AGMPUPP64"]).isFreeTeam)
        #expect(!info([]).isFreeTeam)
        #expect(!info(["6zu5z6zkk7"]).isFreeTeam)
    }

    @Test("real certificates: free is free and not paid; paid is the reverse")
    func realCerts() throws {
        #expect(try keychainCert(TestCerts.free).info.isFreeTeam)
        #expect(try !keychainCert(TestCerts.paid).info.isFreeTeam)
        #expect(try !keychainCert(TestCerts.other).info.isFreeTeam)
    }

    @Test("selection returns valid free identities only, latest expiry first, with fp8, SHA-1 and expiry")
    func selection() {
        let later = utcDate(2027, 12, 1)
        let certs = [
            hand(sha1(1), ous: ["6ZU5Z6ZKK7"]),
            hand(sha1(2), ous: ["6ZU5Z6ZKK7"], notAfter: later),
            hand(sha1(3), ous: ["6ZU5Z6ZKK7"], valid: false),
            hand(sha1(4), ous: ["6ZU5Z6ZKK7"], notAfter: utcDate(2026, 1, 1)),
            hand(sha1(5), ous: ["7AGMPUPP64"]),
            hand(sha1(6), ous: ["6ZU5Z6ZKK7", "7AGMPUPP64"]),
            hand(sha1(1), ous: ["6ZU5Z6ZKK7"]),
        ]
        let found = CertCheck.freeIdentities(certs, now: now)
        #expect(found == [FreeIdentity(sha1: sha1(2), notAfter: later), FreeIdentity(sha1: sha1(1), notAfter: utcDate(2027, 10, 16))])
        #expect(found[0].fp8 == "22222222")
        #expect(CertCheck.freeIdentities([hand(sha1(5), ous: ["7AGMPUPP64"])], now: now).isEmpty)
    }

    @Test("the pinned check requires exactly that valid identity")
    func pinned() {
        let certs = [hand("AABBCCDD" + String(repeating: "0", count: 32), ous: ["6ZU5Z6ZKK7"]), hand(sha1(2), ous: ["6ZU5Z6ZKK7"])]
        guard case .found(let id) = CertCheck.pinnedFree(certs, fp8: "aabbccdd", now: now) else {
            Issue.record("expected found")
            return
        }
        #expect(id.sha1.hasPrefix("AABBCCDD"))
        if case .found = CertCheck.pinnedFree(certs, fp8: "AABBCCDD", now: now) {} else { Issue.record("case-insensitive") }
        #expect(CertCheck.pinnedFree(certs, fp8: "11111111", now: now) == .notFound)
        #expect(CertCheck.pinnedFree(certs, fp8: "aabbcc", now: now) == .notFound)
        #expect(CertCheck.pinnedFree(certs, fp8: "aabbccddee", now: now) == .notFound)
        #expect(CertCheck.pinnedFree(certs, fp8: "zzzzzzzz", now: now) == .notFound)
        #expect(CertCheck.pinnedFree([], fp8: "aabbccdd", now: now) == .notFound)
        // The pinned identity expired or untrusted: another free certificate does not stand in for it.
        let expired = [hand("AABBCCDD" + String(repeating: "0", count: 32), ous: ["6ZU5Z6ZKK7"], notAfter: utcDate(2026, 1, 1)), certs[1]]
        #expect(CertCheck.pinnedFree(expired, fp8: "aabbccdd", now: now) == .notFound)
        let untrusted = [hand("AABBCCDD" + String(repeating: "0", count: 32), ous: ["6ZU5Z6ZKK7"], valid: false)]
        #expect(CertCheck.pinnedFree(untrusted, fp8: "aabbccdd", now: now) == .notFound)
        // A paid-team certificate with the same prefix is not a free identity.
        let paid = [hand("AABBCCDD" + String(repeating: "0", count: 32), ous: ["7AGMPUPP64"])]
        #expect(CertCheck.pinnedFree(paid, fp8: "aabbccdd", now: now) == .notFound)
        let twins = [
            hand("AABBCCDD" + String(repeating: "0", count: 32), ous: ["6ZU5Z6ZKK7"]),
            hand("AABBCCDD" + String(repeating: "1", count: 32), ous: ["6ZU5Z6ZKK7"]),
        ]
        #expect(CertCheck.pinnedFree(twins, fp8: "aabbccdd", now: now) == .ambiguous)
    }

    @Test("snapshot diff: added, removed and unchanged; only free-team identities count; validity is ignored")
    func snapshotDiff() throws {
        let before = FreeIdentitySnapshot([
            hand(sha1(1), ous: ["6ZU5Z6ZKK7"]), hand(sha1(2), ous: ["6ZU5Z6ZKK7"]), hand(sha1(9), ous: ["7AGMPUPP64"]),
        ])
        let after = FreeIdentitySnapshot([
            hand(sha1(2), ous: ["6ZU5Z6ZKK7"], valid: false), hand(sha1(3), ous: ["6ZU5Z6ZKK7"]),
            hand(sha1(8), ous: ["7AGMPUPP64"]), hand(sha1(7), ous: ["OTHER"]),
        ])
        let diff = before.diff(to: after)
        #expect(diff.added == [sha1(3)])
        #expect(diff.removed == [sha1(1)])
        #expect(diff.unchanged == [sha1(2)])
        #expect(diff.changed)
        #expect(diff.addedFp8 == ["33333333"] && diff.removedFp8 == ["11111111"])

        let same = before.diff(to: before)
        #expect(!same.changed && same.added.isEmpty && same.removed.isEmpty && same.unchanged.count == 2)
        #expect(!FreeIdentitySnapshot([]).diff(to: FreeIdentitySnapshot([])).changed)
        #expect(FreeIdentitySnapshot([]).diff(to: before).added.count == 2)
        #expect(before.diff(to: FreeIdentitySnapshot([])).removed.count == 2)
    }

    @Test("a snapshot reads the injected keychain once and propagates its failure")
    func snapshotTake() throws {
        let keychain = FakeKeychain([try keychainCert(TestCerts.free), try keychainCert(TestCerts.paid)])
        #expect(try FreeIdentitySnapshot.take(keychain).sha1s.count == 1)
        #expect(keychain.readCount == 1)
        #expect(throws: KeychainError.self) { try FreeIdentitySnapshot.take(FakeKeychain(failure: KeychainError("boom"))) }
    }
}

@Suite("free team: doctor row")
struct FreeDoctorRowTests {
    @Test("a valid free identity adds one info row with fp8 and expiry and no name or full hash")
    func row() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let free = try keychainCert(TestCerts.free)
            let (services, _) = fakeServices(paths, keychain: FakeKeychain([free]), now: now)
            let out = try await FreeCertificateCheck().run(services)
            #expect(out.count == 1)
            let row = out[0]
            #expect(row.id == "cert-free" && row.severity == .info && row.fix == nil)
            #expect(row.message.contains(LedgerSync.fp8(free.reference)))
            #expect(row.message.contains("2027-10-16"))
            let text = "\(row.json)"
            #expect(!text.contains(free.reference) && !text.contains("TEST000002") && !text.contains("Apple Development:"))
            #expect(!text.contains("Test"))
        }
    }

    @Test("no free identity (or an unreadable keychain) adds no row")
    func absent() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            for keychain in [
                FakeKeychain(), FakeKeychain([try keychainCert(TestCerts.paid)]), FakeKeychain(failure: KeychainError("boom")),
            ] {
                let (services, _) = fakeServices(paths, keychain: keychain, now: now)
                #expect(try await FreeCertificateCheck().run(services).isEmpty)
            }
        }
    }

    @Test("the existing cert rows are unchanged and in order; the new row follows them")
    func orderPreserved() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let keychain = FakeKeychain([try keychainCert(TestCerts.paid), try keychainCert(TestCerts.free)])
            let (services, _) = fakeServices(paths, keychain: keychain, now: now)
            let existing = try await CertificateCheck().run(services)
            #expect(existing.map(\.id) == ["cert", "cert-other-team"])
            #expect(Doctor.checks.map(\.id).prefix(4) == ["xcode", "clt", "cert", "cert-free"])
            #expect(Doctor.checks.map(\.id).suffix(3) == ["device", "appletv", "disk"])
        }
    }
}

// MARK: - Guard(.free)

private let pinned = Data("pinned free certificate".utf8)
private let pinnedRef = CertReference(CertificateReader.sha1Hex(pinned))!

private func freeContext(
    bundleId: String = freeApp, prefix: String? = prefix, now: Date = testNow,
    scratchRoot: String = FileManager.default.temporaryDirectory.path
) -> SigningContext {
    .free(
        FreeSigning(
            bundleId: bundleId, bundleIdPrefix: prefix, pinnedCertificate: pinnedRef, now: now, scratchRoot: scratchRoot))
}

private func codesign(team: String?, identifier: String? = freeApp) -> RunResult {
    RunResult(
        stderr: "Executable=x\n" + (identifier.map { "Identifier=\($0)\n" } ?? "")
            + (team.map { "TeamIdentifier=\($0)\n" } ?? ""))
}

/// `codesign -d --entitlements - --xml` output.
private func entitlements(appId: String?) -> RunResult {
    let body = appId.map { "<key>application-identifier</key><string>\($0)</string>" } ?? ""
    return RunResult(stdout: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>\(body)<key>get-task-allow</key><true/></dict></plist>")
}

/// Answers the four tool calls the free guard makes. `--extract-certificates=<prefix>` writes `leaf` (when
/// not nil) to `<prefix>0`, as codesign does, and answers `extract`.
private func freeRunner(
    cs: RunResult = codesign(team: Team.free), cms: RunResult, ent: RunResult = entitlements(appId: Team.free + "." + freeApp),
    leaf: Data? = pinned, extract: RunResult = RunResult()
) -> FakeRunner {
    FakeRunner { spec in
        if spec.executable == "/usr/bin/security" { return cms }
        if let flag = spec.args.first(where: { $0.hasPrefix("--extract-certificates=") }) {
            if let leaf {
                let prefix = String(flag.dropFirst("--extract-certificates=".count))
                FileManager.default.createFile(atPath: prefix + "0", contents: leaf)
            }
            return extract
        }
        return spec.args.contains("--entitlements") ? ent : cs
    }
}

/// `profileXML` with `ExpirationDate` removed.
private func profileWithoutExpiry() throws -> RunResult {
    let xml = try profileXML(team: Team.free, applicationIdentifier: Team.free + "." + freeApp, certs: [pinned])
    var plist = try #require(
        try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil) as? [String: Any])
    plist["ExpirationDate"] = nil
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return RunResult(stdout: String(decoding: data, as: UTF8.self))
}

private func freeProfile(
    team: String = Team.free, appId: String? = Team.free + "." + freeApp, devices: [String] = [savedUdid("1")],
    certs: [Data] = [pinned]
) throws -> RunResult {
    RunResult(stdout: try profileXML(team: team, applicationIdentifier: appId, devices: devices, certs: certs))
}

/// A throwaway `.app` directory with an `Info.plist` (unless `infoBundleId` is nil); `extra` paths are created
/// inside it, and `setup(root, app)` can add more.
private func withApp<T>(
    extra: [String] = [], infoBundleId: String? = freeApp, setup: (URL, URL) throws -> Void = { _, _ in },
    _ body: (String) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sideload-free-guard-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Stremio.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in extra {
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    if let infoBundleId {
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": infoBundleId], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
    }
    try setup(root, app)
    return try await body(app.path)
}

/// Runs the free guard over a throwaway app. With no explicit `context` it uses a private scratch root and
/// asserts that the guard left nothing in it, on whatever path it took.
private func freeVerdict(
    _ context: SigningContext? = nil, now: Date = testNow, cs: RunResult = codesign(team: Team.free),
    cms: RunResult? = nil, ent: RunResult = entitlements(appId: Team.free + "." + freeApp),
    leaf: Data? = pinned, extract: RunResult = RunResult(), extra: [String] = [], infoBundleId: String? = freeApp,
    setup: (URL, URL) throws -> Void = { _, _ in }, udid: String = savedUdid("1")
) async throws -> (Guard, FakeRunner) {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sideload-free-scratch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let runner = freeRunner(cs: cs, cms: try cms ?? freeProfile(), ent: ent, leaf: leaf, extract: extract)
    let context = context ?? freeContext(now: now, scratchRoot: scratch.path)
    let result = try await withApp(extra: extra, infoBundleId: infoBundleId, setup: setup) { app in
        (await Guard.run(context: context, runner: runner, app: app, udid: udid), runner)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "scratch directory left behind")
    return result
}

@Suite("guard: free context")
struct FreeGuardTests {
    @Test("a fully valid free app passes and records its facts")
    func passes() async throws {
        let (g, runner) = try await freeVerdict()
        #expect(g.passed && g.code == nil && g == .pass)
        #expect(g.facts?.signedTeam == Team.free && g.facts?.profileTeam == Team.free)
        #expect(g.facts?.deviceIncluded == true && g.facts?.signingCertInProfile == true)
        #expect(runner.calls.map(\.executable) == ["/usr/bin/codesign", "/usr/bin/security", "/usr/bin/codesign", "/usr/bin/codesign"])
        #expect(runner.calls[2].args.first == "-d" && runner.calls[2].args[1].hasPrefix("--extract-certificates="))
        #expect(runner.calls[3].args.prefix(4) == ["-d", "--entitlements", "-", "--xml"])
        #expect(runner.calls.allSatisfy { $0.timeout == .seconds(30) })
    }

    @Test("a Frameworks directory and nested non-extension content still pass")
    func otherContentPasses() async throws {
        let (g, _) = try await freeVerdict(extra: ["Frameworks/Foo.framework", "PlugIns", "Assets.xcassets"])
        #expect(g.passed)
    }

    @Test("the paid team on the app -> WRONG_TEAM; the profile is never read")
    func paidApp() async throws {
        let (g, runner) = try await freeVerdict(cs: codesign(team: Team.paid))
        #expect(g.code == "WRONG_TEAM")
        #expect(runner.calls.count == 1)
    }

    @Test("the paid team in the profile -> WRONG_TEAM")
    func paidProfile() async throws {
        let (g, _) = try await freeVerdict(cms: freeProfile(team: Team.paid, appId: Team.paid + "." + freeApp))
        #expect(g.code == "WRONG_TEAM")
        #expect(try await freeVerdict(cms: freeProfile(team: "ZZZZZZZZZZ")).0.code == "WRONG_TEAM")
    }

    @Test("an unsigned app or an undecodable profile -> GUARD_FAILED")
    func unreadable() async throws {
        #expect(try await freeVerdict(cs: codesign(team: nil)).0.code == "GUARD_FAILED")
        #expect(try await freeVerdict(cs: RunResult(code: 1)).0.code == "GUARD_FAILED")
        #expect(try await freeVerdict(cms: RunResult(stdout: "not a plist")).0.code == "GUARD_FAILED")
    }

    @Test("a wrong, wildcard, prefixed or missing application-identifier -> PROFILE_INVALID")
    func wrongAppId() async throws {
        let bad: [String?] = [
            Team.free + ".io.github.dividedby.free.other", Team.free + ".*", Team.free + "." + freeApp + ".x",
            freeApp, Team.paid + "." + freeApp, " " + Team.free + "." + freeApp, Team.free.lowercased() + "." + freeApp, nil,
        ]
        for appId in bad {
            let cms = RunResult(stdout: try profileXML(team: Team.free, applicationIdentifier: appId, certs: [pinned]))
            let (g, _) = try await freeVerdict(cms: appId == nil ? noAppIdProfile() : cms)
            #expect(g.code == "PROFILE_INVALID", "\(appId ?? "nil")")
        }
    }

    @Test("a non-allowlisted bundle ID -> BUNDLE_ID_NOT_ALLOWED before any subprocess")
    func notAllowlisted() async throws {
        for id in ["io.github.dividedby.sideload.canary", "com.facebook.WebDriverAgentRunner", "io.github.dividedby.free.", "x"] {
            let (g, runner) = try await freeVerdict(
                freeContext(bundleId: id), cms: freeProfile(appId: Team.free + "." + id))
            #expect(g.code == "BUNDLE_ID_NOT_ALLOWED", "\(id)")
            #expect(runner.calls.isEmpty)
        }
        let (noPrefix, runner) = try await freeVerdict(freeContext(prefix: nil))
        #expect(noPrefix.code == "BUNDLE_ID_NOT_ALLOWED" && runner.calls.isEmpty)
    }

    @Test("the pinned certificate missing from DeveloperCertificates -> PROFILE_CERT_MISMATCH")
    func missingCert() async throws {
        let other = Data("some other certificate".utf8)
        for certs in [[], [other]] {
            let (g, _) = try await freeVerdict(cms: freeProfile(certs: certs))
            #expect(g.code == "PROFILE_CERT_MISMATCH")
            #expect(g.facts?.signingCertInProfile == false)
        }
    }

    @Test("the app must be signed with the pinned certificate, not merely have it in the profile")
    func signedWithPinned() async throws {
        // A different leaf, an empty one, no cert file at all, and a failing codesign: all GUARD_FAILED.
        for (leaf, extract) in [
            (Data("some other certificate".utf8) as Data?, RunResult()), (Data(), RunResult()), (nil, RunResult()),
            (pinned, RunResult(code: 1, stderr: "codesign failed")), (pinned, RunResult(code: nil, spawnError: "ENOENT")),
        ] {
            let (g, _) = try await freeVerdict(leaf: leaf, extract: extract)
            #expect(g.code == "GUARD_FAILED", "leaf \(leaf?.count ?? -1), exit \(extract.code ?? -1)")
            #expect(g.facts?.signingCertInProfile == true)
        }
        // A match passes, and the message of a failure never carries a certificate subject.
        #expect(try await freeVerdict(leaf: pinned).0.passed)
        let (bad, _) = try await freeVerdict(leaf: Data("x".utf8))
        #expect(bad.reason?.contains("Apple Development") == false)
    }

    @Test("the extraction runs argv-only into a 0700 scratch directory that is removed afterwards")
    func extractionScratch() async throws {
        let (_, runner) = try await freeVerdict()
        let call = try #require(runner.calls.first { $0.args.contains { $0.hasPrefix("--extract-certificates=") } })
        let flag = try #require(call.args.first { $0.hasPrefix("--extract-certificates=") })
        #expect(call.timeout == .seconds(30) && call.args.count == 3 && call.args.last?.hasSuffix(".app") == true)
        let dir = URL(fileURLWithPath: String(flag.dropFirst("--extract-certificates=".count))).deletingLastPathComponent().path
        #expect(!FileManager.default.fileExists(atPath: dir))
        // An unusable scratch root fails closed.
        let (g, _) = try await freeVerdict(freeContext(scratchRoot: "/dev/null/nope"))
        #expect(g.code == "GUARD_FAILED")
    }

    @Test("an expired profile, one expiring exactly now, or one with no expiry -> PROFILE_INVALID")
    func profileExpiry() async throws {
        let at = Date(timeIntervalSince1970: 2_000_000_000)
        func expiring(_ date: Date) throws -> RunResult {
            RunResult(stdout: try profileXML(
                team: Team.free, applicationIdentifier: Team.free + "." + freeApp, certs: [pinned], expires: date))
        }
        #expect(try await freeVerdict(now: at, cms: expiring(at.addingTimeInterval(1))).0.passed)
        #expect(try await freeVerdict(now: at, cms: expiring(at)).0.code == "PROFILE_INVALID")
        #expect(try await freeVerdict(now: at, cms: expiring(at.addingTimeInterval(-86_400))).0.code == "PROFILE_INVALID")
        let (missing, _) = try await freeVerdict(cms: profileWithoutExpiry())
        #expect(missing.code == "PROFILE_INVALID")
        #expect(missing.facts?.profileExpires == nil)
    }

    @Test("FreeSigning.applicationIdentifier is the free team and the bundle ID")
    func applicationIdentifier() {
        let signing = FreeSigning(
            bundleId: freeApp, bundleIdPrefix: prefix, pinnedCertificate: pinnedRef, now: testNow, scratchRoot: "/x")
        #expect(signing.applicationIdentifier == "6ZU5Z6ZKK7.io.github.dividedby.free.stremio")
    }

    @Test("a device not in ProvisionedDevices -> DEVICE_NOT_IN_PROFILE; matching ignores case")
    func deviceNotProvisioned() async throws {
        #expect(try await freeVerdict(cms: freeProfile(devices: [savedUdid("9")])).0.code == "DEVICE_NOT_IN_PROFILE")
        #expect(try await freeVerdict(cms: freeProfile(devices: [])).0.code == "DEVICE_NOT_IN_PROFILE")
        #expect(try await freeVerdict(udid: savedUdid("1").lowercased()).0.passed)
    }

    @Test("an .appex anywhere in the bundle -> EXTENSION_REMAINS, case-insensitively")
    func appexPresent() async throws {
        for path in ["PlugIns/Share.appex", "PlugIns/Share.APPEX", "Deep/Er/Widget.appex/Nested", "PlugIns/.appex"] {
            let (g, _) = try await freeVerdict(extra: [path])
            #expect(g.code == "EXTENSION_REMAINS", "\(path)")
        }
    }

    @Test("the app's own signed identity must match the caller's bundle ID, else GUARD_FAILED")
    func signedIdentityMismatch() async throws {
        let other = "io.github.dividedby.free.other"
        // codesign Identifier= differs, or is missing.
        for identifier in [other, nil] {
            let (g, _) = try await freeVerdict(cs: codesign(team: Team.free, identifier: identifier))
            #expect(g.code == "GUARD_FAILED", "identifier \(identifier ?? "nil")")
        }
        // Info.plist CFBundleIdentifier differs, or the plist is absent.
        for info in [other, nil] {
            let (g, _) = try await freeVerdict(infoBundleId: info)
            #expect(g.code == "GUARD_FAILED", "info \(info ?? "nil")")
        }
        // Readable signed entitlements name another app id, or none.
        for appId in [Team.free + "." + other, Team.paid + "." + freeApp, nil] {
            let (g, _) = try await freeVerdict(ent: entitlements(appId: appId))
            #expect(g.code == "GUARD_FAILED", "entitlements \(appId ?? "nil")")
        }
        // Unreadable entitlements are skipped: the profile check has already pinned the app id.
        for unreadable in [RunResult(code: 1), RunResult(), RunResult(stdout: "not a plist")] {
            #expect(try await freeVerdict(ent: unreadable).0.passed)
        }
    }

    @Test("a symlink named *.appex is rejected, whatever it points at")
    func appexSymlink() async throws {
        for target in ["/usr", "/nonexistent", "PlugIns"] {
            let (g, _) = try await freeVerdict(extra: ["PlugIns"]) { _, app in
                try FileManager.default.createSymbolicLink(
                    atPath: app.appendingPathComponent("Share.appex").path, withDestinationPath: target)
            }
            #expect(g.code == "EXTENSION_REMAINS", "\(target)")
        }
    }

    @Test("a symlink that leaves the bundle is GUARD_FAILED naming the relative path only")
    func escapingSymlinks() async throws {
        func link(_ name: String, to target: (URL, URL) -> String) async throws -> Guard {
            let (g, _) = try await freeVerdict { root, app in
                let outside = root.appendingPathComponent("Outside")
                try FileManager.default.createDirectory(
                    at: outside.appendingPathComponent("Share.appex"), withIntermediateDirectories: true)
                let parent = app.appendingPathComponent((name as NSString).deletingLastPathComponent)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    atPath: app.appendingPathComponent(name).path, withDestinationPath: target(root, app))
            }
            return g
        }
        // A symlinked PlugIns/ (and Extensions/, Watch/) pointing outside; its .appex is not followed.
        for name in ["PlugIns", "Extensions", "Watch"] {
            let g = try await link(name, to: { root, _ in root.appendingPathComponent("Outside").path })
            #expect(g.code == "GUARD_FAILED", Comment(rawValue: name))
            #expect(g.reason?.hasSuffix(": \(name).") == true, Comment(rawValue: name))
        }
        // An absolute target, and a `..` escape from a nested directory.
        let absolute = try await link("Frameworks/Lib", to: { _, _ in "/usr/lib" })
        #expect(absolute.code == "GUARD_FAILED" && absolute.reason?.hasSuffix(": Frameworks/Lib.") == true)
        let dotdot = try await link("Frameworks/Lib", to: { _, _ in "../../Outside" })
        #expect(dotdot.code == "GUARD_FAILED" && dotdot.reason?.hasSuffix(": Frameworks/Lib.") == true)
        // The message carries the relative path only, never the temporary directory.
        #expect(try await link("PlugIns", to: { root, _ in root.path }).reason?.contains("sideload-free-guard") == false)
    }

    @Test("a symlink resolving inside the bundle is allowed; a dangling or looping one is GUARD_FAILED")
    func insideAndDanglingSymlinks() async throws {
        // Framework `Versions/Current` style: a relative link to a sibling directory.
        let (inside, _) = try await freeVerdict(extra: ["Frameworks/Foo.framework/Versions/A"]) { _, app in
            try FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("Frameworks/Foo.framework/Versions/Current").path,
                withDestinationPath: "A")
        }
        #expect(inside.passed)
        let (dangling, _) = try await freeVerdict { _, app in
            try FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("Missing").path, withDestinationPath: "Nowhere")
        }
        #expect(dangling.code == "GUARD_FAILED" && dangling.reason?.hasSuffix(": Missing.") == true)
        let (loop, _) = try await freeVerdict { _, app in
            try FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("Loop").path, withDestinationPath: "Loop")
        }
        #expect(loop.code == "GUARD_FAILED")
        // An .appex still outranks a bad link.
        let (both, _) = try await freeVerdict(extra: ["PlugIns/Share.appex"]) { _, app in
            try FileManager.default.createSymbolicLink(
                atPath: app.appendingPathComponent("A").path, withDestinationPath: "/usr")
        }
        #expect(both.code == "EXTENSION_REMAINS")
    }

    @Test("an app path that does not exist -> GUARD_FAILED")
    func missingApp() async throws {
        let runner = freeRunner(cms: try freeProfile())
        let g = await Guard.run(context: freeContext(), runner: runner, app: "/nonexistent/Stremio.app", udid: savedUdid("1"))
        #expect(g.code == "GUARD_FAILED")
    }
}

@Suite("guard: paid context is unchanged")
struct PaidGuardUnchangedTests {
    private func paid(cs: RunResult, cms: RunResult = RunResult(), explicit: Bool) async -> Guard {
        let runner = FakeRunner { $0.executable == "/usr/bin/codesign" ? cs : cms }
        if explicit { return await Guard.run(context: .paid, runner: runner, app: "/fake/Canary.app", udid: savedUdid("1")) }
        return await Guard.run(runner: runner, app: "/fake/Canary.app", udid: savedUdid("1"))
    }

    @Test("the free OU on the app or in the profile is still FREE_TEAM_SELECTED, through both entry points")
    func freeOUStillRejected() async {
        for explicit in [false, true] {
            let app = await paid(cs: codesign(team: Team.free), explicit: explicit)
            #expect(app.code == "FREE_TEAM_SELECTED")
            let prof = await paid(
                cs: codesign(team: Team.paid),
                cms: RunResult(stdout: profileXML(team: Team.free, devices: [savedUdid("1")])), explicit: explicit)
            #expect(prof.code == "FREE_TEAM_SELECTED")
            let ok = await paid(
                cs: codesign(team: Team.paid),
                cms: RunResult(stdout: profileXML(team: Team.paid, devices: [savedUdid("1")])), explicit: explicit)
            #expect(ok.passed)
        }
    }

    @Test("the paid context does not look inside the bundle")
    func paidIgnoresExtensions() async throws {
        let runner = FakeRunner { $0.executable == "/usr/bin/codesign" ? codesign(team: Team.paid) : RunResult(stdout: profileXML(team: Team.paid, devices: [savedUdid("1")])) }
        let g = try await withApp(extra: ["PlugIns/Share.appex"]) { app in
            await Guard.run(context: .paid, runner: runner, app: app, udid: savedUdid("1"))
        }
        #expect(g.passed)
    }
}

/// A profile whose Entitlements has no `application-identifier`.
private func noAppIdProfile() -> RunResult {
    let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>TeamIdentifier</key><array><string>6ZU5Z6ZKK7</string></array>
        <key>ProvisionedDevices</key><array><string>\(savedUdid("1"))</string></array>
        <key>DeveloperCertificates</key><array><data>\(pinned.base64EncodedString())</data></array>
        <key>Entitlements</key><dict><key>get-task-allow</key><true/></dict>
        </dict></plist>
        """
    return RunResult(stdout: xml)
}
