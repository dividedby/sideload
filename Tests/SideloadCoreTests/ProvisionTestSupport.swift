import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Fakes for `provision`: a keychain that answers differently on each read (so the identity diff has a before and
// an after), a runner that plays xcodebuild (it writes the embedded profile into the derived data, as the real
// build would) and `security cms -D` (the "CMS" files in these tests are the plist itself), and synthetic
// profiles. Nothing here runs a real xcodebuild, touches the real keychain, a device or the network.

/// Replays `reads[i]` for the i-th read, then the last one for every later read. A nil entry throws.
final class SequencedKeychain: KeychainClient {
    private let reads: [[KeychainCertificate]?]
    private let index = Mutex(0)

    init(_ reads: [[KeychainCertificate]?]) {
        precondition(!reads.isEmpty)
        self.reads = reads
    }

    var readCount: Int { index.withLock { $0 } }

    func developmentIdentities() throws -> [KeychainCertificate] {
        let i = index.withLock { n in
            defer { n += 1 }
            return n
        }
        guard let identities = reads[min(i, reads.count - 1)] else { throw KeychainError("locked") }
        return identities
    }
}

let carrierPrefix = "io.github.dividedby"
let stremioId = "io.github.dividedby.free.stremio"
let apolloId = "io.github.dividedby.free.apollo"
let fillerId = "io.github.dividedby.free.filler"

/// The throwaway free-team certificate (`TestCerts.free`) as the keychain would report it.
func freeKeychainCert() throws -> KeychainCertificate { try keychainCert(TestCerts.free) }

/// A second valid free-team identity with an unrelated SHA-1.
func otherFreeCert(_ seed: String = "AB", fp8: String? = nil, notAfter: Date? = nil) -> KeychainCertificate {
    let reference = (fp8?.uppercased() ?? "") + String(repeating: seed, count: 20)
    return KeychainCertificate(
        reference: String(reference.prefix(40)),
        info: CertInfo(ous: [Team.free], notAfter: notAfter ?? daysFromNow(300)), isValidForCodeSigning: true,
        commonName: "Apple Development: Second Person (\(seed)SECOND00)")
}

/// A profile as Xcode would embed it for `bundleId`, valid unless a parameter says otherwise.
func freeProfileXML(
    bundleId: String = stremioId, uuid: String = "0F0F0F0F-1111-2222-3333-444444444444", team: String = Team.free,
    applicationIdentifier: String? = nil, getTaskAllow: Any = true, devices: [String]? = nil, certs: [Data]? = nil,
    platform: [String] = ["iOS"], created: Date? = nil, expires: Date? = nil
) throws -> String {
    try profileXML(
        uuid: uuid, team: team, applicationIdentifier: applicationIdentifier ?? Team.free + "." + bundleId,
        getTaskAllow: getTaskAllow, devices: devices ?? [savedUdid("1")], certs: certs ?? [try certDER(TestCerts.free)],
        platform: platform, created: created ?? daysFromNow(0), expires: expires ?? daysFromNow(7))
}

/// What was in the faked Xcode folders when the first `xcodebuild` ran.
final class CacheAtBuild: Sendable {
    private let seen = Mutex<[String]?>(nil)

    var files: [String]? { seen.withLock { $0 } }

    private let ledgerText = Mutex<String?>(nil)

    /// The ledger file as it was when the first `xcodebuild` ran (nil: no ledger file yet, or no build).
    var ledgerAtBuild: Ledger? {
        ledgerText.withLock { $0 }.flatMap { try? LedgerStore.parse(Data($0.utf8)) }
    }

    func recordLedger(_ path: String) {
        ledgerText.withLock { if $0 == nil { $0 = try? String(contentsOfFile: path, encoding: .utf8) } }
    }

    func record(_ dirs: [String]) {
        seen.withLock { seen in
            if seen == nil {
                seen = dirs.flatMap { dir in
                    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
                }.sorted()
            }
        }
    }
}

struct ProvisionWorld {
    let paths: Paths
    let store: ConfigStore
    let services: Services
    let runner: FakeRunner
    let keychain: SequencedKeychain
    /// Stand-ins for Xcode's two provisioning-profile folders.
    let cacheDirs: [String]
    /// The files in `cacheDirs` when the first `xcodebuild` ran (to prove `--renew` moved them first).
    let cacheAtBuild: CacheAtBuild

    var builds: [CommandSpec] { runner.calls.filter { $0.executable == "xcodebuild" } }
    var securityCalls: [CommandSpec] { runner.calls.filter { $0.executable == "/usr/bin/security" } }

    func ledger() throws -> Ledger { try services.ledgerStore.load() }

    func config() throws -> Config { try store.load() }

    func run(_ options: ProvisionOptions) async -> Envelope { await ProvisionCommand.run(services, options) }

    /// `--app stremio-ios --device iphone --yes`.
    func run(
        app: String = "stremio-ios", device: String = "iphone", register: Bool = false, renew: Bool = false,
        yes: Bool = true
    ) async -> Envelope {
        await run(ProvisionOptions(app: app, device: device, registerDevice: register, renew: renew, yes: yes))
    }
}

/// How the faked `xcodebuild` behaves.
struct BuildScript: Sendable {
    var result = RunResult(stdout: "** BUILD SUCCEEDED **\n")
    /// The profile it embeds when the build succeeds; nil embeds nothing (a product with no profile).
    var profile: String?
    /// Create the `.app` even though `profile` is nil.
    var createApp = true
    var sdk = "iphoneos"
    /// Make `embedded.mobileprovision` a symlink to this (a path the test made) instead of a file.
    var embedAsSymlinkTo: String?
    /// Make `embedded.mobileprovision` a directory.
    var embedAsDirectory = false
    /// The team `codesign -dvv` reports for the built app (nil: `not set`, an unsigned build).
    var signedTeam: String? = Team.free
    /// The signature's leaf certificate DER that `codesign --extract-certificates` writes (nil: the throwaway free one).
    var leaf: Data?
    /// The exit code of `ditto`, which the filler's staging uses to copy the signed carrier.
    var dittoCode: Int32 = 0
    /// Leave the executable out of the built app.
    var omitExecutable = false
}

let twoDevices: [String: SavedDevice] = [
    "iphone": SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios", name: "Test iPhone"),
    "appletv": SavedDevice(udid: savedUdid("2"), coreDeviceId: savedCoreId("2"), platform: "tvos", name: "Test Apple TV"),
]

func provisionConfig(prefix: String? = carrierPrefix, extra: [String: JSONValue] = [:]) -> Config {
    Config(devices: twoDevices, bundleIdPrefix: prefix, extra: extra)
}

/// Runs `body` against a fresh temp home with fake services. `reads` are the successive keychain reads (the
/// first is the preflight and "before" snapshot, the second the "after" snapshot).
func withProvisionWorld(
    config: Config = provisionConfig(), reads: [[KeychainCertificate]?]? = nil, build: BuildScript? = nil,
    cache: [String: String] = [:], _ body: (ProvisionWorld) async throws -> Void
) async throws {
    let free = try freeKeychainCert()
    let script = try build ?? BuildScript(profile: try freeProfileXML())
    let leaf = try script.leaf ?? certDER(TestCerts.free)
    try await withTestHome(config: config) { paths, store in
        let cacheDirs = [paths.home + "/xcode-cache-1", paths.home + "/xcode-cache-2"]
        for dir in cacheDirs { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        for (relative, content) in cache {
            try Data(content.utf8).write(to: URL(fileURLWithPath: relative.hasPrefix("/") ? relative : paths.home + "/" + relative))
        }
        let cacheAtBuild = CacheAtBuild()
        let runner = FakeRunner { spec in
            switch spec.executable {
            case "xcodebuild":
                cacheAtBuild.record(cacheDirs)
                cacheAtBuild.recordLedger(paths.ledger)
                guard script.result.code == 0, !script.result.timedOut, !script.result.overflow,
                    script.result.spawnError == nil, script.createApp,
                    let dd = spec.args.firstIndex(of: "-derivedDataPath").map({ spec.args[$0 + 1] })
                else { return script.result }
                let app = "\(dd)/Build/Products/Debug-\(script.sdk)/Carrier.app"
                try? FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
                let embedded = app + "/embedded.mobileprovision"
                let identifier = spec.args.first { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER=") }.map { String($0.dropFirst(26)) } ?? ""
                let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Carrier"]
                try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: URL(fileURLWithPath: app + "/Info.plist"))
                if !script.omitExecutable { try? Data("carrier executable".utf8).write(to: URL(fileURLWithPath: app + "/Carrier")) }
                if let target = script.embedAsSymlinkTo {
                    try? FileManager.default.createSymbolicLink(atPath: embedded, withDestinationPath: target)
                } else if script.embedAsDirectory {
                    try? FileManager.default.createDirectory(atPath: embedded, withIntermediateDirectories: true)
                } else if let profile = script.profile {
                    try? Data(profile.utf8).write(to: URL(fileURLWithPath: app + "/embedded.mobileprovision"))
                }
                return script.result
            case "/usr/bin/ditto":
                guard script.dittoCode == 0, spec.args.count == 2 else { return RunResult(code: script.dittoCode) }
                do { try FileManager.default.copyItem(atPath: spec.args[0], toPath: spec.args[1]) } catch { return RunResult(code: 1) }
                return RunResult()
            case "/usr/bin/codesign":
                if spec.args.first == "-dvv" {
                    let path = (spec.args.last ?? "") + "/Info.plist"
                    let plist = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
                        try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
                    }
                    let team = script.signedTeam.map { "TeamIdentifier=\($0)" } ?? "TeamIdentifier=not set"
                    return RunResult(stderr: "Identifier=\(plist?["CFBundleIdentifier"] as? String ?? "")\n\(team)\n")
                }
                if let flag = spec.args.first(where: { $0.hasPrefix("--extract-certificates=") }) {
                    FileManager.default.createFile(
                        atPath: String(flag.dropFirst("--extract-certificates=".count)) + "0", contents: leaf)
                    return RunResult()
                }
                return RunResult(code: 1)  // `-d --entitlements`: unreadable, which the guard skips
            case "/usr/bin/security":
                // `security cms -D` decodes stdin (the bytes the command read); `-i <file>` reads a file. The test
                // files hold the plist directly.
                if spec.args == ["cms", "-D"], let stdin = spec.stdin {
                    return RunResult(stdout: String(decoding: stdin, as: UTF8.self))
                }
                guard spec.args.count == 4, let text = try? String(contentsOfFile: spec.args[3], encoding: .utf8) else {
                    return RunResult(code: 1)
                }
                return RunResult(stdout: text)
            default: return RunResult()
            }
        }
        let keychain = SequencedKeychain(reads ?? [[free], [free]])
        var services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: keychain, home: paths)
        services.xcodeProfileDirectories = cacheDirs
        try await body(
            ProvisionWorld(
                paths: paths, store: store, services: services, runner: runner, keychain: keychain,
                cacheDirs: cacheDirs, cacheAtBuild: cacheAtBuild))
    }
}
