import Foundation
import Testing

@testable import SideloadCore

// Helpers shared by DoctorTests, DeviceCommandTests and CLITests. Fake IDs come from `savedUdid` / `savedCoreId`
// (ConfigTestSupport), assembled at runtime.

/// A clock that always reports the same instant.
struct FixedClock: WallClock {
    let instant: Date

    init(_ instant: Date) {
        self.instant = instant
    }

    func now() -> Date { instant }
}

/// 2026-10-19 12:00 UTC, the `NOW` of the Node tests.
let testNow = Date(timeIntervalSince1970: 1_792_411_200)

func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// A `devicectl list devices` entry (jsonVersion 5 shape).
func deviceEntryJSON(
    name: String, udid: String, coreId: String, platform: String = "iOS", reality: String = "physical",
    pairing: String = "paired", tunnel: String = "connected", hostnames: [String] = [],
    osVersion: String? = nil, osBuild: String? = nil
) -> JSONValue {
    var entry: JSONValue = [
        "identifier": .string(coreId),
        "visibilityClass": reality == "simulated" ? "simulators" : "default",
        "properties": [
            "connection": [
                "pairingState": .string(pairing), "tunnelState": .string(tunnel), "transportType": "wired",
                "potentialHostnames": .array(hostnames.map { .string($0) }),
            ],
            "hardware": ["platform": .string(platform), "reality": .string(reality), "udid": .string(udid)],
            "state": ["name": .string(name)],
        ],
    ]
    // The legacy `deviceProperties` dict, where a physical device's OS version and build live.
    if osVersion != nil || osBuild != nil {
        entry = entry.setting(
            ["deviceProperties"],
            to: [
                "osVersionNumber": osVersion.map(JSONValue.string) ?? .null,
                "osBuildUpdate": osBuild.map(JSONValue.string) ?? .null,
            ])
    }
    return entry
}

func deviceListJSON(_ entries: JSONValue...) -> JSONValue {
    ["info": ["outcome": "success"], "result": ["devices": .array(entries)]]
}

func phoneEntryJSON(
    name: String = "Test iPhone", seed: String = "1", reality: String = "physical", tunnel: String = "connected"
) -> JSONValue {
    deviceEntryJSON(name: name, udid: savedUdid(seed), coreId: savedCoreId(seed), reality: reality, tunnel: tunnel)
}

/// Scripted answers for everything the checks and device commands run. `devices == nil` means devicectl
/// exits with `devicectlCode` and writes nothing.
struct Route: Sendable {
    var xcodebuild = RunResult(stdout: "Xcode 27.0\nBuild version 27A266a\n")
    var xcodeSelect = RunResult(stdout: "/Applications/Xcode.app/Contents/Developer\n")
    /// `xcrun --find <tool>` fails for these tools.
    var missingTools: Set<String> = []
    var pkgInstalled = true
    var devices: JSONValue?
    var devicectlCode: Int32 = 0

    var script: FakeRunner.Script {
        { spec in
            switch (spec.executable, spec.args.first) {
            case ("xcodebuild", _): return xcodebuild
            case ("xcode-select", _): return xcodeSelect
            case ("/usr/sbin/pkgutil", _):
                return pkgInstalled
                    ? RunResult(stdout: "package-id: com.apple.pkg.CLTools_Executables\nversion: 27.0.0.0.1\n")
                    : RunResult(code: 1, stderr: "No receipt")
            case ("xcrun", "--find"):
                let tool = spec.args.dropFirst().first ?? ""
                return missingTools.contains(tool) ? RunResult(code: 1) : RunResult(stdout: "/x/\(tool)\n")
            case ("xcrun", "devicectl"):
                if let devices, let path = spec.args.firstIndex(of: "--json-output").map({ spec.args[$0 + 1] }),
                    let data = try? JSONEncoder().encode(devices)
                {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                return RunResult(code: devicectlCode)
            default: return RunResult()
            }
        }
    }
}

struct FakeFileSystem: FileSystem {
    struct Failure: Error {}

    var freeBytes: UInt64?

    func freeBytes(at path: String) throws -> UInt64 {
        guard let freeBytes else { throw Failure() }
        return freeBytes
    }

    static func free(gb: Double) -> FakeFileSystem { FakeFileSystem(freeBytes: UInt64(gb * Double(1 << 30))) }
}

/// Fake services over an existing temp home. Nothing here touches the real `$SIDELOAD_HOME`.
func fakeServices(
    _ paths: Paths, route: Route = Route(), keychain: FakeKeychain = FakeKeychain(), now: Date = testNow,
    fs: FakeFileSystem = .free(gb: 50)
) -> (services: Services, runner: FakeRunner) {
    let runner = FakeRunner(route.script)
    return (
        Services(runner: runner, fs: fs, clock: FixedClock(now), keychain: keychain, home: paths),
        runner
    )
}

/// A throwaway certificate as the keychain client would report it for a trusted, unexpired identity.
func keychainCert(_ base64: String) throws -> KeychainCertificate {
    let der = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
    var read = try #require(CertificateReader.read(der: der))
    read.isValidForCodeSigning = true
    return read
}

func decodeJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension Envelope {
    /// The envelope as the CLI would print it (redacted), decoded back.
    func printed() throws -> (text: String, json: JSONValue) {
        let text = try Output.render(self)
        return (text, try decodeJSON(text))
    }

    var errorCodes: [String] { errors.map(\.code) }
}
