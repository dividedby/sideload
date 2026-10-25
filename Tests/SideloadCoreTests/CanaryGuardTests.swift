import Foundation
import Testing

@testable import SideloadCore

// The pre-install guard (docs/design.md section 10): codesign team, then the embedded profile's team and
// ProvisionedDevices. Each failure code, and the plist parsing that replaces Node's regex.

private let app = "/fake/Build/Products/Debug-iphoneos/Canary.app"

private func codesign(team: String?, code: Int32 = 0) -> RunResult {
    RunResult(code: code, stderr: "Executable=x\nIdentifier=y\n" + (team.map { "TeamIdentifier=\($0)\n" } ?? ""))
}

private func runner(_ cs: RunResult, _ cms: RunResult = RunResult()) -> FakeRunner {
    FakeRunner { $0.executable == "/usr/bin/codesign" ? cs : cms }
}

private func verdict(_ cs: RunResult, _ cms: RunResult = RunResult(), udid: String = savedUdid("1")) async -> Guard {
    await Guard.run(runner: runner(cs, cms), app: app, udid: udid)
}

private func profile(team: String? = "7AGMPUPP64", devices: [String] = [savedUdid("1")]) -> RunResult {
    RunResult(stdout: profileXML(team: team, devices: devices))
}

@Suite("guard: codesign and profile checks")
struct GuardTests {
    @Test("paid team on the app and in the profile, device listed -> passed")
    func passes() async {
        let g = await verdict(codesign(team: "7AGMPUPP64"), profile())
        #expect(g == .pass)
        #expect(g.passed && g.code == nil)
    }

    @Test("runs codesign -dvv on the app, then security cms on the embedded profile, 30 s each")
    func commands() async {
        let r = runner(codesign(team: "7AGMPUPP64"), profile())
        _ = await Guard.run(runner: r, app: app, udid: savedUdid("1"))
        #expect(r.calls.map(\.executable) == ["/usr/bin/codesign", "/usr/bin/security"])
        #expect(r.calls[0].args == ["-dvv", app])
        #expect(r.calls[1].args == ["cms", "-D", "-i", app + "/embedded.mobileprovision"])
        #expect(r.calls.allSatisfy { $0.timeout == .seconds(30) })
    }

    @Test("codesign failing, printing no team, or printing `not set` -> GUARD_FAILED, profile never read")
    func unsigned() async {
        for cs in [
            codesign(team: "7AGMPUPP64", code: 1), codesign(team: nil), codesign(team: "not set"),
            RunResult(code: nil, spawnError: "ENOENT"),
        ] {
            let r = runner(cs, profile())
            let g = await Guard.run(runner: r, app: app, udid: savedUdid("1"))
            #expect(g.code == "GUARD_FAILED")
            #expect(r.calls.count == 1)
        }
    }

    @Test("the deny-listed free team on the app -> FREE_TEAM_SELECTED, profile never read")
    func freeApp() async {
        let r = runner(codesign(team: "6ZU5Z6ZKK7"), profile())
        let g = await Guard.run(runner: r, app: app, udid: savedUdid("1"))
        #expect(g.code == "FREE_TEAM_SELECTED")
        #expect(r.calls.count == 1)
    }

    @Test("another team on the app -> WRONG_TEAM, profile never read")
    func wrongApp() async {
        let r = runner(codesign(team: "ZZZZZZZZZZ"), profile())
        let g = await Guard.run(runner: r, app: app, udid: savedUdid("1"))
        #expect(g.code == "WRONG_TEAM")
        #expect(r.calls.count == 1)
    }

    @Test("the team is matched exactly, not by prefix or case")
    func exactTeam() async {
        for team in ["7AGMPUPP6", "7AGMPUPP640", "7agmpupp64"] {
            #expect(await verdict(codesign(team: team), profile()).code == "WRONG_TEAM", "\(team)")
        }
    }

    @Test("a profile that cannot be decoded -> GUARD_FAILED", arguments: [
        RunResult(code: 1, stderr: "security: error"), RunResult(code: nil, spawnError: "ENOENT"),
        RunResult(stdout: "not a plist"), RunResult(stdout: ""), RunResult(stdout: "<plist><array/></plist>"),
    ])
    func undecodable(cms: RunResult) async {
        #expect(await verdict(codesign(team: "7AGMPUPP64"), cms).code == "GUARD_FAILED")
    }

    @Test("the profile of the free team -> FREE_TEAM_SELECTED; another team -> WRONG_TEAM; none -> WRONG_TEAM")
    func profileTeam() async {
        let cs = codesign(team: "7AGMPUPP64")
        #expect(await verdict(cs, profile(team: "6ZU5Z6ZKK7")).code == "FREE_TEAM_SELECTED")
        #expect(await verdict(cs, profile(team: "ZZZZZZZZZZ")).code == "WRONG_TEAM")
        #expect(await verdict(cs, profile(team: nil)).code == "WRONG_TEAM")
    }

    @Test("the device must be in ProvisionedDevices -> DEVICE_NOT_IN_PROFILE")
    func deviceNotListed() async {
        let cs = codesign(team: "7AGMPUPP64")
        #expect(await verdict(cs, profile(devices: [savedUdid("9")])).code == "DEVICE_NOT_IN_PROFILE")
        #expect(await verdict(cs, profile(devices: [])).code == "DEVICE_NOT_IN_PROFILE")
        let noKey = RunResult(
            stdout: "<plist><dict><key>TeamIdentifier</key><array><string>7AGMPUPP64</string></array></dict></plist>")
        #expect(await verdict(cs, noKey).code == "DEVICE_NOT_IN_PROFILE")
    }

    @Test("device matching ignores case on both sides")
    func caseInsensitive() async {
        let cs = codesign(team: "7AGMPUPP64")
        #expect(await verdict(cs, profile(devices: [savedUdid("1").lowercased()])).passed)
        #expect(await verdict(cs, profile(devices: [savedUdid("1")]), udid: savedUdid("1").lowercased()).passed)
    }
}

@Suite("guard: parsing")
struct GuardParsingTests {
    @Test("a realistic profile: header, DOCTYPE, other keys, dates and nested entitlements")
    func realistic() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CreationDate</key><date>2026-10-19T12:00:00Z</date>
                <key>Entitlements</key>
                <dict>
                    <key>application-identifier</key><string>7AGMPUPP64.com.example.sideload.canary</string>
                    <key>get-task-allow</key><true/>
                    <key>keychain-access-groups</key><array><string>7AGMPUPP64.*</string></array>
                </dict>
                <key>ProvisionedDevices</key>
                <array>
                    <string>\(savedUdid("A"))</string>
                    <string>\(savedUdid("1"))</string>
                </array>
                <key>TeamIdentifier</key>
                <array>
                    <string>7AGMPUPP64</string>
                </array>
            </dict>
            </plist>
            """
        let p = Guard.parseProfile(xml)
        #expect(p?.team == "7AGMPUPP64")
        #expect(p?.devices == [savedUdid("A").lowercased(), savedUdid("1").lowercased()])
    }

    @Test("only the top-level keys count: a nested TeamIdentifier or string list is ignored")
    func nestedDecoys() {
        let xml = """
            <plist version="1.0"><dict>
              <key>Entitlements</key><dict>
                <key>TeamIdentifier</key><array><string>ZZZZZZZZZZ</string></array>
                <key>ProvisionedDevices</key><array><string>decoy</string></array>
              </dict>
              <key>TeamIdentifier</key><array><string>7AGMPUPP64</string></array>
              <key>ProvisionedDevices</key><array><string>AAAA</string></array>
            </dict></plist>
            """
        let p = Guard.parseProfile(xml)
        #expect(p?.team == "7AGMPUPP64")
        #expect(p?.devices == ["aaaa"])
    }

    @Test("an empty or absent TeamIdentifier array has no team")
    func noTeam() {
        #expect(Guard.parseProfile("<plist><dict><key>TeamIdentifier</key><array/></dict></plist>")?.team == nil)
        #expect(Guard.parseProfile("<plist><dict/></plist>")?.team == nil)
    }

    @Test("input that is not a plist dictionary does not parse", arguments: ["", "garbage", "<plist><string>x</string></plist>", "<plist><array/></plist>", "<dict>"])
    func notPlist(text: String) {
        #expect(Guard.parseProfile(text) == nil)
    }

    @Test("TeamIdentifier comes from the start of a line, from stderr or stdout")
    func codesignParsing() {
        #expect(Guard.signedTeam(stderr: "a\nTeamIdentifier=7AGMPUPP64\nb", stdout: "") == "7AGMPUPP64")
        #expect(Guard.signedTeam(stderr: "", stdout: "TeamIdentifier=7AGMPUPP64") == "7AGMPUPP64")
        #expect(Guard.signedTeam(stderr: "TeamIdentifier=not set", stdout: "") == nil)
        #expect(Guard.signedTeam(stderr: "Authority=x TeamIdentifier=7AGMPUPP64", stdout: "") == nil)
        #expect(Guard.signedTeam(stderr: "", stdout: "") == nil)
    }
}
