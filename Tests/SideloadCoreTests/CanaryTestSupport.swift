import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// A scripted fake world for the canary: keychain, devicectl, xcodebuild, codesign and `security cms`. Every
// subprocess goes through `FakeRunner`; no real tool, device, portal or `~/.sideload` is touched. Fake IDs come
// from `savedUdid` / `savedCoreId`, so no UDID-shaped literal is committed.

let canaryBundle = "com.example.sideload.canary"
let canaryProject = "/fake/canary/Canary.xcodeproj"

func canaryConfig(_ edit: (inout Config) -> Void = { _ in }) -> Config {
    var config = iphoneConfig(bundleIdPrefix: "com.example")
    edit(&config)
    return config
}

func installFixture(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: fixture(name))))
}

extension JSONValue {
    /// A copy with the value at `path` replaced (intermediate objects must exist).
    func setting(_ path: [String], to value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self, let head = path.first else { return value }
        fields[head] = path.count == 1 ? value : (fields[head] ?? .object([:])).setting(Array(path.dropFirst()), to: value)
        return .object(fields)
    }
}

/// What `devicectl device install app` does in a scenario.
struct InstallScript: Sendable {
    var code: Int32? = 0
    var payload: JSONValue?
    var timedOut = false
    var stderr = ""
    /// The canary lands on the device even though the install did not report success.
    var installsAnyway = false

    static func success() throws -> InstallScript { InstallScript(payload: try installFixture("install-success.json")) }

    static func failure(_ fixtureName: String) throws -> InstallScript {
        InstallScript(code: 1, payload: try installFixture(fixtureName))
    }

    static let timeout = InstallScript(code: nil, payload: nil, timedOut: true, installsAnyway: true)
}

struct CanaryScenario: Sendable {
    var free = false
    var install: InstallScript?
    var buildOverflow = false
    var buildFails = false
    var buildStderr = "error: No profiles for the bundle were found"
    /// The build reports success but leaves no Canary.app.
    var buildSkipsApp = false
    /// Canary.app is a symlink to a real directory / to nothing.
    var appIsSymlink = false
    var appIsDangling = false
    var signedTeam = "7AGMPUPP64"
    var profileTeam = "7AGMPUPP64"
    var profileDevices: [String] = [savedUdid("1")]
    /// `CreationDate`, `ExpirationDate` and `DeveloperCertificates` (base64 DER) of the embedded profile.
    var profileCreated = "2026-10-01T08:00:00Z"
    var profileExpires = "2027-10-01T08:00:00Z"
    var profileCerts: [String] = [TestCerts.paid]
    var snapshotFails = false
    var extraAfter = false
    var installOverflow = false
    var uninstallOverflow = false
    var uninstallFails = false
    /// The n-th `device info apps` call overflows (1 = before, 2 = after).
    var snapshotOverflowOn: Int?
    var others = ["com.apple.mobilesafari"]
    var hostnames: [String] = []
    /// `list devices` calls after this many fail.
    var listFailsAfter: Int?
    /// A failing `list devices` still writes its JSON (exit code 1).
    var failingListWritesJSON = false
    /// `sw_vers` answers (empty means it prints nothing) and the device's OS in the listing (nil omits them).
    var xcodeVersion = "27.0"
    var macosVersion = "27.0.1"
    var macosBuild = "27A100"
    var iosVersion: String? = "27.0.1"
    var iosBuild: String? = "24A446"
    /// The device's name as `devicectl list devices` shows it.
    var deviceName = "Test iPhone"
    /// Who runs the canary, for redaction. Fixed so tests do not depend on the machine's account.
    var localUser = LocalUser(login: "pat", fullName: "Pat Q. Tester", homeDirectory: "/Users/pat")
}

final class CanaryWorld: Sendable {
    struct State {
        var installed = false
        var snapshots = 0
        var lists = 0
        var logged: [String] = []
    }

    /// `Mutex` is noncopyable; the scripted runner and the log closure share it through this box.
    final class Box: Sendable {
        let mutex = Mutex(State())

        func withLock<T>(_ body: (inout State) -> T) -> T { mutex.withLock { body(&$0) } }
    }

    let paths: Paths
    let runner: FakeRunner
    let services: Services
    private let box: Box

    var state: State { box.withLock { $0 } }
    var installed: Bool { state.installed }
    var logged: [String] { state.logged }

    init(paths: Paths, scenario s: CanaryScenario, install: InstallScript) throws {
        let box = Box()
        self.box = box
        self.paths = paths
        let list = deviceListJSON(
            deviceEntryJSON(
                name: s.deviceName, udid: savedUdid("1"), coreId: savedCoreId("1"), hostnames: s.hostnames,
                osVersion: s.iosVersion, osBuild: s.iosBuild))
        let runner = FakeRunner { spec in
            Self.respond(to: spec, scenario: s, install: install, list: list, box: box)
        }
        self.runner = runner
        let keychain = FakeKeychain([try keychainCert(s.free ? TestCerts.free : TestCerts.paid)])
        services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: keychain, home: paths,
            log: { line in box.withLock { $0.logged.append(line) } }, canaryProject: canaryProject,
            localUser: s.localUser)
    }

    private static func write(_ json: JSONValue, to spec: CommandSpec) {
        guard let i = spec.args.firstIndex(of: "--json-output"), i + 1 < spec.args.count,
            let data = try? JSONEncoder().encode(json)
        else { return }
        try? data.write(to: URL(fileURLWithPath: spec.args[i + 1]))
    }

    private static func respond(
        to spec: CommandSpec, scenario s: CanaryScenario, install: InstallScript, list: JSONValue,
        box: Box
    ) -> RunResult {
        let args = spec.args
        switch (spec.executable, args.first) {
        case ("xcodebuild", "-version"):
            return RunResult(stdout: "Xcode \(s.xcodeVersion)\nBuild version 27A266a\n")
        case ("xcodebuild", _):
            if s.buildOverflow { return RunResult(code: nil, overflow: true) }
            if s.buildFails { return RunResult(code: 65, stderr: s.buildStderr) }
            if s.buildSkipsApp { return RunResult() }
            let derived = args[args.firstIndex(of: "-derivedDataPath")! + 1]
            let products = derived + "/Build/Products/Debug-iphoneos"
            let appPath = products + "/Canary.app"
            if s.appIsSymlink || s.appIsDangling {
                try? FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: true)
                let target = derived + "/Real.app"
                if s.appIsSymlink { try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true) }
                try? FileManager.default.createSymbolicLink(atPath: appPath, withDestinationPath: target)
            } else {
                try? FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: true)
            }
            return RunResult()
        case ("/usr/bin/sw_vers", _):
            return RunResult(stdout: (args.first == "-buildVersion" ? s.macosBuild : s.macosVersion) + "\n")
        case ("/usr/bin/codesign", _):
            return RunResult(stderr: "Identifier=x\nTeamIdentifier=\(s.signedTeam)\n")
        case ("/usr/bin/security", "cms"):
            return RunResult(
                stdout: profileXML(
                    team: s.profileTeam, devices: s.profileDevices, created: s.profileCreated,
                    expires: s.profileExpires, certs: s.profileCerts))
        case ("xcrun", "devicectl"):
            return devicectl(spec, scenario: s, install: install, list: list, box: box)
        default:
            return RunResult()
        }
    }

    private static func devicectl(
        _ spec: CommandSpec, scenario s: CanaryScenario, install: InstallScript, list: JSONValue,
        box: Box
    ) -> RunResult {
        func isSub(_ sub: String...) -> Bool { Array(spec.args.dropFirst().prefix(sub.count)) == sub }
        switch true {
        case isSub("list", "devices"):
            let n = box.withLock { state -> Int in
                state.lists += 1
                return state.lists
            }
            if let after = s.listFailsAfter, n > after {
                if s.failingListWritesJSON { write(list, to: spec) }
                return RunResult(code: 1)
            }
            write(list, to: spec)
            return RunResult()
        case isSub("device", "info", "apps"):
            if s.snapshotFails { return RunResult(code: 1) }
            let (n, installed) = box.withLock { state -> (Int, Bool) in
                state.snapshots += 1
                return (state.snapshots, state.installed)
            }
            if s.snapshotOverflowOn == n { return RunResult(code: nil, overflow: true) }
            var apps = s.others + (installed ? [canaryBundle] : [])
            if s.extraAfter && n > 1 { apps.append("com.unexpected.app") }
            write(["result": ["apps": .array(apps.map { ["bundleIdentifier": .string($0)] })]], to: spec)
            return RunResult()
        case isSub("device", "install", "app"):
            if s.installOverflow {
                box.withLock { $0.installed = true }  // the canary lands even though the output flooded
                return RunResult(code: nil, overflow: true)
            }
            if let payload = install.payload { write(payload, to: spec) }
            if install.code == 0 || install.installsAnyway { box.withLock { $0.installed = true } }
            return RunResult(code: install.code, stderr: install.stderr, timedOut: install.timedOut)
        case isSub("device", "uninstall", "app"):
            if s.uninstallOverflow { return RunResult(code: nil, overflow: true) }
            if s.uninstallFails { return RunResult(code: 1) }
            box.withLock { $0.installed = false }
            return RunResult()
        default:
            return RunResult()
        }
    }

    // MARK: Inspecting what ran

    var calls: [CommandSpec] { runner.calls }

    static func isDevicectl(_ c: CommandSpec, _ sub: String...) -> Bool {
        c.executable == "xcrun" && c.args.first == "devicectl" && Array(c.args.dropFirst().prefix(sub.count)) == sub
    }

    var installs: [CommandSpec] { calls.filter { Self.isDevicectl($0, "device", "install", "app") } }
    var uninstalls: [CommandSpec] { calls.filter { Self.isDevicectl($0, "device", "uninstall", "app") } }
    var builds: [CommandSpec] { calls.filter { $0.executable == "xcodebuild" && $0.args.contains("build") } }

    func run(_ options: CanaryOptions = CanaryOptions(device: "iphone", yes: true)) async -> Envelope {
        await CanaryCommand.run(services, options)
    }

    /// The `canary-install-*.json` files the run left in `logs/`.
    var savedInstalls: [String] {
        listing(paths.logs).filter { $0.hasPrefix("canary-install-") }.sorted()
    }

    func savedInstall(_ name: String) throws -> String {
        try String(contentsOfFile: paths.logs + "/" + name, encoding: .utf8)
    }

    var jsonlLines: [JSONValue] {
        get throws {
            let text = (try? String(contentsOfFile: paths.canaryLog, encoding: .utf8)) ?? ""
            return try text.split(separator: "\n").map { try decodeJSON(String($0)) }
        }
    }
}

/// A profile as `security cms -D` prints it: XML header, DOCTYPE, other keys, and the two that matter.
func profileXML(
    team: String?, devices: [String], created: String? = nil, expires: String? = nil, certs: [String]? = nil
) -> String {
    let strings = { (a: [String]) in a.map { "<string>\($0)</string>" }.joined(separator: "\n\t\t") }
    let dates = [("CreationDate", created), ("ExpirationDate", expires)]
        .compactMap { key, value in value.map { "\t<key>\(key)</key>\n\t<date>\($0)</date>\n" } }.joined()
    let certificates = certs.map { list in
        "\t<key>DeveloperCertificates</key>\n\t<array>\n"
            + list.map { "\t\t<data>\($0)</data>\n" }.joined() + "\t</array>\n"
    } ?? ""
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(dates)\(certificates)\t<key>Name</key>
        \t<string>iOS Team Provisioning Profile</string>
        \t<key>ApplicationIdentifierPrefix</key>
        \t<array>
        \t\t<string>7AGMPUPP64</string>
        \t</array>
        \t<key>TeamIdentifier</key>
        \t<array>
        \t\t\(team.map { "<string>\($0)</string>" } ?? "")
        \t</array>
        \t<key>ProvisionedDevices</key>
        \t<array>
        \t\t\(strings(devices))
        \t</array>
        </dict>
        </plist>
        """
}

/// Runs `body` with a fresh canary world over a temp home (never the real one).
func withCanaryWorld<T>(
    _ scenario: CanaryScenario = CanaryScenario(), config: Config = canaryConfig(),
    _ body: (CanaryWorld) async throws -> T
) async throws -> T {
    let install = try scenario.install ?? InstallScript.success()
    return try await withTestHome(config: config) { paths, _ in
        try await body(CanaryWorld(paths: paths, scenario: scenario, install: install))
    }
}
