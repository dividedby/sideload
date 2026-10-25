import Foundation
import Testing

@testable import SideloadCore

@Suite("Provisioning profiles")
struct ProfileTests {
    @Test("parses the facts a plan needs")
    func parses() throws {
        let der = try certDER(TestCerts.paid)
        let uuid = UUID().uuidString
        let xml = try profileXML(
            uuid: uuid.lowercased(), devices: [savedUdid("1").uppercased(), savedUdid("2")], certs: [der],
            created: daysFromNow(-10), expires: daysFromNow(355))
        let p = try #require(ProvisioningProfile.parse(xml, file: "/x/a.mobileprovision"))
        #expect(p.uuid == uuid.uppercased(), "normalised to upper case")
        #expect(p.team == Team.id)
        #expect(p.applicationIdentifier == Team.id + ".*")
        #expect(p.isWildcard && p.isDevelopment)
        #expect(p.platforms == ["iOS"])
        #expect(p.devices == [savedUdid("1").lowercased(), savedUdid("2").lowercased()])
        #expect(p.includes(device: savedUdid("1")) && !p.includes(device: savedUdid("3")))
        #expect(p.contains(certificate: CertificateReader.sha1Hex(der).lowercased()))
        #expect(!p.contains(certificate: String(repeating: "0", count: 40)))
        #expect(p.created == daysFromNow(-10) && p.expires == daysFromNow(355))
        #expect(p.file == "/x/a.mobileprovision")
    }

    @Test("an explicit bundle ID is not a wildcard; no devices or get-task-allow false is not development")
    func kinds() throws {
        let explicit = try #require(
            ProvisioningProfile.parse(try profileXML(applicationIdentifier: Team.id + ".io.example.app")))
        #expect(!explicit.isWildcard && explicit.isDevelopment)
        let distribution = try #require(ProvisioningProfile.parse(try profileXML(getTaskAllow: false)))
        #expect(distribution.getTaskAllow == false && !distribution.isDevelopment)
        let noDevices = try #require(ProvisioningProfile.parse(try profileXML(devices: [])))
        #expect(!noDevices.isDevelopment)
        // An integer is not a plist boolean: it must not count as get-task-allow.
        let spoofed = try #require(ProvisioningProfile.parse(try profileXML(getTaskAllow: 1)))
        #expect(spoofed.getTaskAllow == nil && !spoofed.isDevelopment)
    }

    @Test("only top-level keys count: nested UUID, TeamIdentifier and entitlements are ignored")
    func nestedKeysSpoof() throws {
        let nested: [String: Any] = [
            "Inner": [
                "UUID": UUID().uuidString, "TeamIdentifier": [Team.id], "get-task-allow": true,
                "application-identifier": Team.id + ".*",
            ]
        ]
        let noUUID: [String: Any] = nested.merging(["TeamIdentifier": ["OTHERTEAM1"]]) { a, _ in a }
        let data = try PropertyListSerialization.data(fromPropertyList: noUUID, format: .xml, options: 0)
        #expect(ProvisioningProfile.parse(String(decoding: data, as: UTF8.self)) == nil, "no top-level UUID")

        let p = try #require(
            ProvisioningProfile.parse(
                try profileXML(team: "OTHERTEAM1", getTaskAllow: false, extra: nested)))
        #expect(p.team == "OTHERTEAM1")
        #expect(p.getTaskAllow == false)
        #expect(p.applicationIdentifier == "OTHERTEAM1.*")
    }

    @Test("non-plist, non-dictionary and bad-UUID input is nil")
    func rejects() throws {
        #expect(ProvisioningProfile.parse("") == nil)
        #expect(ProvisioningProfile.parse("not a plist") == nil)
        let array = try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0)
        #expect(ProvisioningProfile.parse(String(decoding: array, as: UTF8.self)) == nil)
        #expect(ProvisioningProfile.parse(try profileXML(uuid: "not-a-uuid")) == nil)
    }
}

@Suite("Xcode-managed profile source")
struct XcodeManagedProfileSourceTests {
    private func write(_ name: String, in dir: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("decodes each .mobileprovision through security cms with an argument array and a timeout")
    func scans() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Profiles")
        let a = UUID().uuidString
        let b = UUID().uuidString
        try write(a + ".mobileprovision", in: dir)
        try write(b + ".mobileprovision", in: dir)
        try write("notes.txt", in: dir)
        let xml = [a: try profileXML(uuid: a), b: try profileXML(uuid: b)]
        let runner = FakeRunner { spec in
            let name = URL(fileURLWithPath: spec.args.last ?? "").deletingPathExtension().lastPathComponent
            return RunResult(stdout: xml[name] ?? "")
        }

        let scan = try await XcodeManagedProfileSource(runner: runner, directories: [dir.path]).candidates()
        #expect(Set(scan.profiles.map(\.uuid)) == [a, b])
        #expect(scan.skipped == 0)
        #expect(runner.calls.count == 2, "the .txt file is never decoded")
        for call in runner.calls {
            #expect(call.executable == "/usr/bin/security")
            #expect(Array(call.args.prefix(3)) == ["cms", "-D", "-i"] && call.args.count == 4)
            #expect(call.args[3].hasPrefix(dir.path + "/") && call.args[3].hasSuffix(".mobileprovision"))
            #expect(call.timeout == .seconds(30))
        }
        #expect(scan.profiles.allSatisfy { $0.file?.hasPrefix(dir.path) == true })
    }

    @Test("a profile in both folders is listed once, keeping the one that lives longer")
    func dedupes() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("UserData")
        let legacy = root.appendingPathComponent("MobileDevice")
        let id = UUID().uuidString
        try write(id + ".mobileprovision", in: user)
        try write(id + ".mobileprovision", in: legacy)
        let runner = FakeRunner { spec in
            let early = spec.args.last?.hasPrefix(user.path) == true
            return RunResult(stdout: (try? profileXML(uuid: id, expires: daysFromNow(early ? 10 : 200))) ?? "")
        }
        let scan = try await XcodeManagedProfileSource(runner: runner, directories: [user.path, legacy.path]).candidates()
        #expect(scan.profiles.count == 1)
        #expect(scan.profiles[0].expires == daysFromNow(200))
        #expect(scan.profiles[0].file?.hasPrefix(legacy.path) == true)
    }

    @Test("an undecodable file is counted, not fatal; a missing folder is skipped")
    func undecodable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Profiles")
        let good = UUID().uuidString
        try write(good + ".mobileprovision", in: dir)
        try write("bad-plist.mobileprovision", in: dir)
        try write("tool-fails.mobileprovision", in: dir)
        let xml = try profileXML(uuid: good)
        let runner = FakeRunner { spec in
            let path = spec.args.last ?? ""
            if path.hasSuffix("tool-fails.mobileprovision") { return RunResult(code: 1, stderr: "decode error") }
            if path.hasSuffix("bad-plist.mobileprovision") { return RunResult(stdout: "not a plist") }
            return RunResult(stdout: xml)
        }
        let source = XcodeManagedProfileSource(runner: runner, directories: [root.path + "/missing", dir.path])
        let scan = try await source.candidates()
        #expect(scan.profiles.map(\.uuid) == [good])
        #expect(scan.skipped == 2)
    }

    @Test("an unlistable folder is PROFILES_UNREADABLE")
    func unreadable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("file", in: root)
        let source = XcodeManagedProfileSource(runner: FakeRunner(), directories: [root.path + "/file"])
        do {
            _ = try await source.candidates()
            Issue.record("expected a throw")
        } catch {
            #expect(errorCode(of: error) == "PROFILES_UNREADABLE")
        }
    }

    @Test("the default directories are the two Xcode folders")
    func defaults() {
        #expect(
            XcodeManagedProfileSource.defaultDirectories(homeDirectory: "/h")
                == ["/h/Library/Developer/Xcode/UserData/Provisioning Profiles", "/h/Library/MobileDevice/Provisioning Profiles"])
    }

    @Test("the inert default source throws, so a forgotten fake cannot read real folders")
    func inert() async throws {
        let (services, _) = fakeServices(Paths(home: "/nonexistent"))
        do {
            _ = try await services.profiles.candidates()
            Issue.record("expected a throw")
        } catch {
            #expect(errorCode(of: error) == "PROFILES_UNAVAILABLE")
        }
    }
}
