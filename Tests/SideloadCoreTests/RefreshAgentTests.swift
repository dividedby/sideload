import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `refresh --print-agent`: the launchd agent's plist and the owner's commands, as text. Nothing here loads, writes or runs
// anything: the commands it prints are the owner's.

private let label = "io.github.dividedby.sideload.refresh"

/// Services whose user home is `/Users/pat` and whose sideload home is `home` (default `/Users/pat/.sideload`).
private func agentServices(home: String = "/Users/pat/.sideload") -> (services: Services, runner: FakeRunner) {
    let made = fakeServices(Paths(home: home))
    var services = made.services
    services.localUser = LocalUser(login: "pat", homeDirectory: "/Users/pat")
    return (services, made.runner)
}

private func plistText(_ envelope: Envelope) throws -> String {
    try #require(envelope.data["plist"]?.string)
}

private func parsed(_ text: String) throws -> [String: Any] {
    let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
    return try #require(object as? [String: Any])
}

private let goldenDefault = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>Label</key>
    \t<string>io.github.dividedby.sideload.refresh</string>
    \t<key>LimitLoadToSessionType</key>
    \t<string>Aqua</string>
    \t<key>LowPriorityIO</key>
    \t<true/>
    \t<key>ProcessType</key>
    \t<string>Background</string>
    \t<key>ProgramArguments</key>
    \t<array>
    \t\t<string>/Users/pat/.local/bin/sideload</string>
    \t\t<string>refresh</string>
    \t\t<string>--auto</string>
    \t</array>
    \t<key>RunAtLoad</key>
    \t<false/>
    \t<key>StandardErrorPath</key>
    \t<string>/Users/pat/.sideload/logs/launchd-refresh.err</string>
    \t<key>StandardOutPath</key>
    \t<string>/dev/null</string>
    \t<key>StartInterval</key>
    \t<integer>1800</integer>
    </dict>
    </plist>

    """

@Suite("refresh --print-agent")
struct RefreshAgentTests {
    @Test("the default plist is exactly the golden text, with the label, path and the default binary")
    func golden() throws {
        let envelope = RefreshCommand.printAgent(agentServices().services, binary: nil)
        #expect(envelope.ok && envelope.command == "refresh" && envelope.errors.isEmpty)
        #expect(try plistText(envelope) == goldenDefault)
        #expect(envelope.data["label"]?.string == label)
        #expect(envelope.data["path"]?.string == "/Users/pat/Library/LaunchAgents/\(label).plist")
    }

    @Test("the plist parses and holds exactly the planned keys: no KeepAlive, no RunAtLoad true, no environment by default")
    func keys() throws {
        let plist = try parsed(try plistText(RefreshCommand.printAgent(agentServices().services, binary: nil)))
        #expect(
            Set(plist.keys)
                == [
                    "Label", "ProgramArguments", "StartInterval", "RunAtLoad", "ProcessType", "LowPriorityIO",
                    "LimitLoadToSessionType", "StandardErrorPath", "StandardOutPath",
                ])
        #expect(plist["Label"] as? String == label)
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/pat/.local/bin/sideload", "refresh", "--auto"])
        #expect(plist["StartInterval"] as? Int == 1800)
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["StandardOutPath"] as? String == "/dev/null")
        #expect(plist["KeepAlive"] == nil && plist["EnvironmentVariables"] == nil)
    }

    @Test("a binary path with &, < and a space is escaped and reads back as the same path")
    func escaping() throws {
        let binary = "/Users/pat/a & b/<tools>/sideload"
        let text = try plistText(RefreshCommand.printAgent(agentServices().services, binary: binary))
        #expect(text.contains("<string>/Users/pat/a &amp; b/&lt;tools&gt;/sideload</string>"))
        #expect(!text.contains("a & b"))
        #expect(try parsed(text)["ProgramArguments"] as? [String] == [binary, "refresh", "--auto"])
        #expect(AgentPlist.escape(#"a&b<c>"d'e"#) == "a&amp;b&lt;c&gt;&quot;d&apos;e")
    }

    @Test("SIDELOAD_HOME is in the plist only for a non-default home, and the log path follows the real home")
    func sideloadHome() throws {
        let other = RefreshCommand.printAgent(agentServices(home: "/Volumes/Work/sl").services, binary: nil)
        let plist = try parsed(try plistText(other))
        #expect((plist["EnvironmentVariables"] as? [String: String]) == ["SIDELOAD_HOME": "/Volumes/Work/sl"])
        #expect(plist["StandardErrorPath"] as? String == "/Volumes/Work/sl/logs/launchd-refresh.err")
        // A default home spelled with a trailing dot segment is still the default: `Paths` normalises it.
        let normalised = Paths.resolveHome(environment: ["SIDELOAD_HOME": "/Users/pat/./.sideload/"], homeDirectory: "/Users/pat")
        let same = RefreshCommand.printAgent(agentServices(home: normalised.home).services, binary: nil)
        #expect(try parsed(try plistText(same))["EnvironmentVariables"] == nil)
    }

    @Test("the owner's commands: write, lint, bootstrap, kickstart; and how to stop; the plist in the here-document is the plist")
    func commands() throws {
        let envelope = RefreshCommand.printAgent(agentServices().services, binary: nil)
        let install = try #require(envelope.data["install"]?.array).compactMap(\.string)
        let path = "/Users/pat/Library/LaunchAgents/\(label).plist"
        #expect(install.count == 5)
        #expect(install[0] == "mkdir -p /Users/pat/Library/LaunchAgents /Users/pat/.sideload/logs")
        #expect(install[1] == "cat > \(path) <<'SIDELOAD_PLIST_END'\n\(goldenDefault)SIDELOAD_PLIST_END")
        #expect(install[2] == "/usr/bin/plutil -lint \(path)")
        #expect(install[3] == "launchctl bootstrap gui/$(id -u) \(path)")
        #expect(install[4] == "launchctl kickstart -k gui/$(id -u)/\(label)")
        let stop = try #require(envelope.data["stop"]?.array).compactMap(\.string)
        #expect(stop == ["touch /Users/pat/.sideload/refresh.disabled", "launchctl bootout gui/$(id -u)/\(label)"])
    }

    @Test("a path with a space or a quote is shell-quoted in the commands, not in the plist")
    func quoting() throws {
        let envelope = RefreshCommand.printAgent(agentServices(home: "/Volumes/My Work/it's").services, binary: nil)
        let install = try #require(envelope.data["install"]?.array).compactMap(\.string)
        #expect(install[0].hasSuffix(#"'/Volumes/My Work/it'\''s/logs'"#))
        #expect(try #require(envelope.data["stop"]?.array).compactMap(\.string)[0] == #"touch '/Volumes/My Work/it'\''s/refresh.disabled'"#)
        #expect(AgentPlist.shellQuoted("/a/b-c_d.e") == "/a/b-c_d.e" && AgentPlist.shellQuoted("") == "''")
    }

    @Test("a relative or control-character --binary is USAGE; nothing is built")
    func badBinary() {
        for binary in ["sideload", "./sideload", "~/.local/bin/sideload", "", "/a/b\nc", "/a/\u{7}b"] {
            let envelope = RefreshCommand.printAgent(agentServices().services, binary: binary)
            #expect(!envelope.ok && envelope.errors.first?.code == "USAGE" && envelope.data["plist"] == nil, "\(binary.debugDescription)")
        }
    }

    @Test("the printed output keeps the owner's home path; every other redaction, and every other command, still applies")
    func printedKeepsHome() throws {
        let envelope = RefreshCommand.printAgent(agentServices().services, binary: nil)
        let (text, json) = try envelope.printed()
        #expect(json["plist"]?.string == goldenDefault && !text.contains("/Users/<user>"))
        let ordinary = Envelope.result("x", ["path": "/Users/pat/.sideload", "id": .string(savedUdid())])
        let (plain, _) = try ordinary.printed()
        #expect(plain.contains("/Users/<user>/.sideload") && !plain.contains("/Users/pat"))
        // The flag leaves only the user path alone.
        let kept = Envelope(ok: true, command: "x", data: ["path": "/Users/pat/x", "id": .string(savedUdid())], keepsUserPaths: true)
        let (keptText, _) = try kept.printed()
        #expect(keptText.contains("/Users/pat/x") && !keptText.contains(savedUdid()))
    }

    @Test("through the command line: no subprocess, no lock, no file, not even the home; exit 0")
    func pure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.path + "/.sideload"
        let made = fakeServices(Paths(home: home))
        var services = made.services
        let runner = made.runner
        services.localUser = LocalUser(login: "pat", homeDirectory: dir.path)
        let out = await run(argv: ["refresh", "--print-agent"], services: services)
        #expect(out.ok && out.exitCode == 0 && out.command == "refresh")
        #expect(out.data["plist"]?.string?.contains("<string>\(dir.path)/.local/bin/sideload</string>") == true)
        #expect(out.data["plist"]?.string?.contains("SIDELOAD_HOME") == false)
        #expect(runner.calls.isEmpty, "no subprocess")
        #expect(listing(dir.path).isEmpty, "nothing written: the home, the lock and the log folder are not created")

        let viaBinary = await run(argv: ["refresh", "--print-agent", "--binary", "/opt/sl/sideload"], services: services)
        #expect(viaBinary.ok)
        #expect(try plistText(viaBinary).contains("<string>/opt/sl/sideload</string>"))
        let inline = await run(argv: ["refresh", "--print-agent", "--binary=/opt/sl/sideload"], services: services)
        #expect(inline == viaBinary)
        #expect(runner.calls.isEmpty && listing(dir.path).isEmpty)
    }

    @Test("--print-agent takes only --binary, --binary takes --print-agent, and --auto takes neither: all USAGE, nothing built")
    func usage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = fakeServices(Paths(home: dir.path + "/.sideload"))
        var services = made.services
        let runner = made.runner
        services.localUser = LocalUser(login: "pat", homeDirectory: dir.path)
        let bad: [[String]] = [
            ["--print-agent", "--yes"], ["--print-agent", "--force"], ["--print-agent", "--auto"],
            ["--print-agent", "--device", "iphone"], ["--print-agent", "--app", "apollo"], ["--print-agent", "--within", "3"],
            ["--print-agent", "--binary", "/a", "--yes"], ["--binary", "/opt/sl/sideload"], ["--auto", "--binary", "/opt/sl/sideload"],
            ["--print-agent", "--binary"], ["--print-agent", "--binary", "relative/sideload"], ["--print-agent", "extra"],
        ]
        for extra in bad {
            let out = await run(argv: ["refresh"] + extra, services: services)
            #expect(!out.ok && out.exitCode == 1 && out.errors.first?.code == "USAGE" && out.data["plist"] == nil, "\(extra)")
        }
        #expect(runner.calls.isEmpty && listing(dir.path).isEmpty)
    }

    @Test("help lists it")
    func help() async throws {
        let help = await run(argv: ["help"], services: agentServices().services)
        #expect(help.data["usage"]?.array?.contains("refresh --print-agent [--binary <absolute path>]") == true)
    }
}
