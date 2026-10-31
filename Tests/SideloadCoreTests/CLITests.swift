import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// In-process CLI tests: `run(argv:services:)` with fake services over a temp home (dispatch and device cases). The one-write/exit-code gate is `Interrupt.finishMain`, covered in SignalTests.

private struct Run {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var runner: FakeRunner
    var paths: Paths
    /// `config.json` as the command left it (the temp home is gone once `invoke` returns).
    var config: Config?

    var code: String? { envelope.errors.first?.code }
}

private func invoke(
    _ argv: [String], config: Config? = Config(devices: [:]), devices: JSONValue = deviceListJSON(phoneEntryJSON()),
    keychain: FakeKeychain = FakeKeychain()
) async throws -> Run {
    try await withTestHome(config: config) { paths, _ in
        let (services, runner) = fakeServices(paths, route: Route(devices: devices), keychain: keychain)
        let envelope = await run(argv: argv, services: services)
        let (text, json) = try envelope.printed()
        return Run(
            envelope: envelope, text: text, json: json, runner: runner, paths: paths,
            config: try? ConfigStore(paths: paths).load())
    }
}

@Suite("CLI dispatch")
struct CLITests {
    @Test("install, app and slot are dispatched: usage first, no device call, and --yes is needed where the owner is")
    func freeDeviceDispatch() async throws {
        #expect(try await invoke(["install"]).code == "USAGE")
        #expect(try await invoke(["install", "--app", "stremio-ios", "--force"]).code == "USAGE")
        #expect(try await invoke(["install", "extra"]).code == "USAGE")
        #expect(try await invoke(["app"]).code == "USAGE")
        #expect(try await invoke(["app", "remove"]).code == "USAGE")
        #expect(try await invoke(["app", "wipe", "--app", "apollo", "--device", "iphone"]).code == "USAGE")
        #expect(try await invoke(["slot"]).code == "USAGE")
        #expect(try await invoke(["slot", "lend", "--device", "iphone", "--yes"]).code == "USAGE", "slot takes no --yes")
        #expect(try await invoke(["slot", "borrow", "--device", "iphone"]).code == "USAGE")
        #expect(try await invoke(["slot", "return", "--device", "iphone", "--app", "stremio-ios"]).code == "USAGE", "slot return takes no --app")
        #expect(try await invoke(["slot", "restore"]).code == "USAGE")
        #expect(try await invoke(["slot", "restore", "--udid", "abc", "--yes"]).code == "USAGE", "restore takes the alias only")
        let restore = try await invoke(["slot", "restore", "--device", "iphone", "--app", "stremio-ios", "--yes"])
        #expect(restore.code == "DEVICE_NOT_SAVED" && restore.envelope.command == "slot")
        #expect(restore.runner.calls.isEmpty)
        let out = try await invoke(["install", "--app", "stremio-ios", "--device", "iphone", "--yes"], config: Config(devices: [:], bundleIdPrefix: "io.github.dividedby"))
        #expect(out.code == "DEVICE_NOT_SAVED")
        #expect(out.envelope.command == "install")
        #expect(out.runner.calls.isEmpty)
    }

    @Test("fetch is dispatched: it needs --app, takes only --app and --approve, and refuses a source the owner has not approved")
    func fetchDispatch() async throws {
        #expect(try await invoke(["fetch"]).code == "USAGE")
        #expect(try await invoke(["fetch", "--app", "apollo", "--yes"]).code == "USAGE")
        #expect(try await invoke(["fetch", "--app", "apollo", "extra"]).code == "USAGE")
        #expect(try await invoke(["fetch", "--app", "apollo", "--approve"], config: Config(approvedSources: [["app": "apollo"]])).code == "USAGE", "--approve needs --version")
        #expect(try await invoke(["fetch", "--app", "apollo", "--version", "3.9.0"], config: Config(approvedSources: [["app": "apollo"]])).code == "USAGE")
        let out = try await invoke(["fetch", "--app", "apollo"])
        #expect(out.code == "SOURCE_NOT_ALLOWED")
        #expect(out.envelope.command == "fetch")
        #expect(out.runner.calls.isEmpty)
        // Approved in config, but the default transport throws: no network from a test that forgot a fake.
        let approved = try await invoke(["fetch", "--app", "apollo"], config: Config(approvedSources: [["app": "apollo"]]))
        #expect(approved.code == "FETCH_NETWORK")
    }

    @Test("sign takes --version: it reaches SignOptions (an empty one is USAGE from sign itself), a missing value and strays are USAGE")
    func signVersion() async throws {
        let config = Config(devices: [:], bundleIdPrefix: "io.github.dividedby")
        let empty = try await invoke(["sign", "--app", "apollo", "--device", "iphone", "--version=", "--yes"], config: config)
        #expect(empty.code == "USAGE" && empty.envelope.command == "sign" && empty.envelope.errors.first?.message == "--version needs a version.")
        #expect(try await invoke(["sign", "--app", "apollo", "--device", "iphone", "--version"], config: config).code == "USAGE")
        #expect(try await invoke(["sign", "--app", "apollo", "--device", "iphone", "--versions", "3.9.0"], config: config).code == "USAGE")
        // A version is accepted by the parser: the run goes on to the device, which is not saved here.
        let named = try await invoke(["sign", "--app", "apollo", "--device", "iphone", "--version", "3.9.0", "--yes"], config: config)
        #expect(named.code == "DEVICE_NOT_SAVED" && named.envelope.command == "sign" && named.runner.calls.isEmpty)
        let usage = try await invoke(["help"]).json["usage"]?.array?.compactMap(\.string) ?? []
        #expect(usage.contains("sign --app <apollo|stremio-ios|stremio-tvos> --device <alias> [--version <v>] --yes"))
    }

    @Test("unknown commands and bad flags return JSON errors")
    func unknownAndBad() async throws {
        #expect(try await invoke(["bogus"]).code == "UNKNOWN_COMMAND")
        #expect(try await invoke(["doctor", "--nope"]).code == "USAGE")
        #expect(try await invoke(["--nope"]).code == "USAGE")
        #expect(try await invoke(["doctor", "--yes"]).code == "USAGE", "per-command schema: --yes is not a doctor option")
        #expect(try await invoke(["doctor", "extra"]).code == "USAGE")
        #expect(try await invoke(["device", "list", "extra"]).code == "USAGE")
        #expect(try await invoke(["device", "save", "--alias"]).code == "USAGE")
    }

    @Test("no command, help, -h and --help print the help object")
    func help() async throws {
        for argv in [[], ["help"], ["-h"], ["--help"], ["doctor", "-h"], ["device", "--help"], ["bogus", "-h"], ["sign", "--help"]] {
            let out = try await invoke(argv)
            #expect(out.envelope.ok, "\(argv)")
            #expect(out.json["command"] == "help")
            #expect(out.json["built"] == ["doctor", "device", "canary", "ledger", "portal", "export-cert", "status", "inspect", "fetch", "provision", "sign", "install", "refresh", "app", "slot", "updates", "clean"])
            #expect(out.json["commands"]?.array?.count == 17)
            #expect(out.runner.calls.isEmpty)
        }
    }

    @Test("doctor runs the checks and exits 1 when one fails")
    func doctor() async throws {
        let out = try await invoke(["doctor"], keychain: FakeKeychain([try keychainCert(TestCerts.paid)]))
        #expect(out.json["command"] == "doctor")
        #expect(out.json["checks"]?.array?.count == 6)
        #expect(out.envelope.exitCode == 1, "no saved iPhone")
        #expect(out.code == "CHECK_DEVICE")
        let good = try await invoke(
            ["doctor"], config: iphoneConfig(), keychain: FakeKeychain([try keychainCert(TestCerts.paid)]))
        #expect(good.envelope.ok && good.envelope.exitCode == 0)
    }

    @Test("device save and list go through the parser")
    func device() async throws {
        let saved = try await invoke(["device", "save", "--alias", "iphone", "--match=Test iPhone", "--platform", "ios", "--yes"])
        #expect(saved.envelope.ok)
        #expect(saved.json["device"]?["name"] == "<device>")
        #expect(!saved.text.contains(savedUdid("1")))
        #expect(saved.config?.devices["iphone"]?.udid == savedUdid("1"))

        let list = try await invoke(["device", "list"], config: iphoneConfig())
        #expect(list.json["devices"]?.array?.first?["visibility"] == "ok")

        #expect(try await invoke(["device", "save", "--alias", "x"]).code == "USAGE")
        #expect(try await invoke(["device", "save", "--alias", "x", "--match", "y", "--platform", "macos"]).code == "USAGE")
        #expect(try await invoke(["device", "wat"]).code == "USAGE")
        #expect(try await invoke(["device"]).code == "USAGE")
        let noConfirm = try await invoke(["device", "save", "--alias", "iphone", "--match", "Test iPhone", "--platform", "ios"])
        #expect(noConfirm.code == "CONFIRM_REQUIRED")
        #expect(noConfirm.envelope.exitCode == 1)
    }

    @Test("a home inside a git work tree is refused before any command runs")
    func homeInGit() async throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let paths = Paths(home: repo.appendingPathComponent("home").path)
        let (services, runner) = fakeServices(paths)
        let envelope = await run(argv: ["doctor"], services: services)
        #expect(envelope.errorCodes == ["HOME_IN_GIT_WORKTREE"])
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.home))
    }

    @Test("the home is created with its subdirectories before a command runs")
    func createsHome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.appendingPathComponent("home").path)
        let (services, _) = fakeServices(paths)
        _ = await run(argv: ["device", "list"], services: services)
        #expect(modeOf(paths.home) == 0o700)
        #expect(modeOf(paths.tmp) == 0o700)
    }

    @Test("output never carries ids or names")
    func redaction() async throws {
        let config = Config(devices: ["iphone": SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", name: "Test iPhone")])
        let out = try await invoke(["device", "list"], config: config)
        #expect(!out.text.contains(savedUdid("1")) && !out.text.contains(savedCoreId("1")) && !out.text.contains("Test iPhone"))
    }
}
