import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Fakes and fixtures for `sign`. The IPAs are synthetic archives built at runtime that mirror the three real apps
// (Stremio iOS with one WidgetKit appex, Stremio tvOS with none, Apollo with an app group and no appex), signed ad hoc
// like InspectTestSupport's. The world runs the real `ditto`, `lipo`, `vtool` and `codesign` over them, with three
// exceptions that are scripted: the free identity (a signing call that names the pinned SHA-1 is carried out ad
// hoc), the facts only a real certificate would give (`TeamIdentifier`, the extracted leaf) and `security cms -D` /
// `devicectl`. No real keychain identity, device, profile or network.

/// The three real apps, as `fetch` names them.
enum SampleApp: String {
    case stremioIOS = "stremio-ios"
    case stremioTVOS = "stremio-tvos"
    case apollo

    var upstreamId: String { self == .apollo ? "com.christianselig.Apollo" : "com.stremio.pal" }
    var freeId: String { self == .apollo ? apolloId : stremioId }
    var platform: String { self == .stremioTVOS ? "tvos" : "ios" }
    var profilePlatform: String { self == .stremioTVOS ? "tvOS" : "iOS" }
    var executable: String { self == .apollo ? "Apollo" : "Stremio" }
    var version: String { self == .apollo ? "3.9.0" : "1.9.6b142" }
    var ipaName: String { self == .apollo ? "Apollo-Reborn-3.9.0-GLASS-NOEXTENSIONS.ipa" : "stremio.ipa" }
    var deviceAlias: String { self == .stremioTVOS ? "appletv" : "iphone" }
    var seed: String { self == .stremioTVOS ? "2" : "1" }
}

enum IPAVariant: String {
    /// What the real fetch found: iOS has the widget appex, tvOS and Apollo have none.
    case real
    /// Every kind of thing `sign` removes: nested appex, `Extensions/`, a watch app with its own appex.
    case everything
    /// A watch app hidden where the stripper does not look, so only the re-walk can see it.
    case hiddenWatch
    /// An XPC service, nested code `sign` does not handle.
    case xpc
    /// An app that says nothing about its minimum OS: no build version in the binary, no MinimumOSVersion.
    case noMinOS
}

private let upstreamTeam = "ABCDE12345"

private func mainEntitlements(_ app: SampleApp) -> [String: Any] {
    var ent: [String: Any] = [
        "application-identifier": "\(upstreamTeam).\(app.upstreamId)",
        "com.apple.developer.team-identifier": upstreamTeam,
        "keychain-access-groups": ["\(upstreamTeam).\(app.upstreamId)"],
    ]
    switch app {
    case .stremioIOS:
        ent["aps-environment"] = "production"
        ent["get-task-allow"] = false
        ent["com.apple.developer.associated-domains"] = ["applinks:strem.io"]
    case .stremioTVOS:
        break
    case .apollo:
        ent["com.apple.security.application-groups"] = ["group.com.christianselig.apollo"]
        ent["com.apple.developer.associated-domains"] = ["applinks:apolloapp.io"]
    }
    return ent
}

/// Builds the bundles of one sample IPA.
private func sampleBundles(_ app: SampleApp, _ variant: IPAVariant) async throws -> [BundleSpec] {
    let name = app.executable
    let dylib = try Data(contentsOf: URL(fileURLWithPath: try await MachOTemplates.shared.path(platform: app.platform, minOS: "15.0")))
    var main = BundleSpec.app(
        name, bundleId: app.upstreamId, executable: name, platform: app.platform, minOS: "15.0",
        entitlements: mainEntitlements(app))
    main.extraFiles["Frameworks/libhelper.dylib"] = dylib
    if variant == .noMinOS {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thin = dir.path + "/thin", versioned = dir.path + "/versioned", bare = dir.path + "/bare"
        await tool("/usr/bin/lipo", ["-thin", "arm64e", "/usr/bin/true", "-output", thin])
        await tool("/usr/bin/vtool", ["-set-build-version", "ios", "15.0", "17.0", "-replace", "-output", versioned, thin])
        await tool("/usr/bin/vtool", ["-remove-build-version", "ios", "-output", bare, versioned])
        main.plist?["MinimumOSVersion"] = nil
        main.executableName = nil
        main.extraFiles[name] = try Data(contentsOf: URL(fileURLWithPath: bare))
    }
    var bundles: [BundleSpec] = [main]
    let framework = BundleSpec(
        directory: "Payload/\(name).app/Frameworks/Core.framework",
        plist: ["CFBundleIdentifier": "org.example.core", "CFBundleExecutable": "Core", "CFBundleName": "Core"],
        executableName: "Core", platform: app.platform, minOS: "15.0", sign: variant != .hiddenWatch)
    bundles.append(framework)

    if app == .stremioIOS {
        bundles.append(
            .appex(
                "StremioDownloadsWidget", bundleId: "com.stremio.pal.downloads-widget", point: "com.apple.widgetkit-extension",
                entitlements: ["com.apple.security.application-groups": ["group.com.stremio.pal"]], app: name))
    }
    switch variant {
    case .real: break
    case .everything:
        bundles.append(
            .appex("Kit", bundleId: app.upstreamId + ".kit", point: "com.apple.extensionkit-service", sign: true, app: name)
                .moved(to: "Payload/\(name).app/Extensions/Kit.appex"))
        bundles.append(
            BundleSpec(
                directory: "Payload/\(name).app/Watch/Watch.app",
                plist: [
                    "CFBundleIdentifier": app.upstreamId + ".watchkitapp", "CFBundleExecutable": "WatchApp",
                    "WKWatchKitApp": true, "WKCompanionAppBundleIdentifier": app.upstreamId,
                ], executableName: "WatchApp", platform: "ios", minOS: "15.0"))
        bundles.append(
            .appex("WatchExt", bundleId: app.upstreamId + ".watchkitapp.ext", point: "com.apple.watchkit", app: name)
                .moved(to: "Payload/\(name).app/Watch/Watch.app/PlugIns/WatchExt.appex"))
        bundles.append(
            .appex("Deep", bundleId: app.upstreamId + ".deep", point: "com.apple.share-services", app: name)
                .moved(to: "Payload/\(name).app/Frameworks/Core.framework/PlugIns/Deep.appex"))
    case .noMinOS: break
    case .xpc:
        bundles.append(
            BundleSpec(
                directory: "Payload/\(name).app/XPCServices/Helper.xpc",
                plist: ["CFBundleIdentifier": app.upstreamId + ".helper", "CFBundlePackageType": "XPC!"],
                executableName: nil, sign: false))
    case .hiddenWatch:
        bundles.append(
            BundleSpec(
                directory: "Payload/\(name).app/Frameworks/Core.framework/Hidden.app",
                plist: ["CFBundleIdentifier": app.upstreamId + ".hidden", "WKWatchKitApp": true],
                executableName: nil, sign: false))
    }
    return bundles
}

extension BundleSpec {
    func moved(to directory: String) -> BundleSpec {
        var copy = self
        copy.directory = directory
        return copy
    }
}

/// IPAs are built once per process (codesign is slow) and shared.
actor SignIPAs {
    static let shared = SignIPAs()
    private var cache: [String: Task<Data, any Error>] = [:]

    func data(_ app: SampleApp, _ variant: IPAVariant = .real) async throws -> Data {
        let key = app.rawValue + "/" + variant.rawValue
        if let task = cache[key] { return try await task.value }
        let task = Task<Data, any Error> {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            return try Data(contentsOf: URL(fileURLWithPath: try await makeIPA(try await sampleBundles(app, variant), in: dir.path)))
        }
        cache[key] = task
        return try await task.value
    }
}

// MARK: scripted runner

/// What the scripted parts of the world do.
struct SignScript: Sendable {
    /// The device's OS as `devicectl list devices` reports it; nil leaves it out.
    var deviceOS: String? = "26.0"
    /// `devicectl` exits non-zero and writes nothing.
    var devicectlFails = false
    /// The team `codesign -dvv` reports for the signed app (the real ad hoc signature has none).
    var reportedTeam: String? = Team.free
    /// The leaf `--extract-certificates` writes; nil writes nothing.
    var leaf: Data?
    /// Signing calls (`-s <identity>`) fail with this result.
    var signingFailure: RunResult?
    /// Signing calls past this many fail (to stop in the middle).
    var failAfterSigningCalls: Int?
}

/// Runs the real tools, except where the world is scripted (see the file comment). Records every call as it was
/// made, before any rewriting.
final class SignRunner: Runner {
    private let real = PosixSpawnRunner()
    private let recorded = Mutex<[CommandSpec]>([])
    private let signingCalls = Mutex(0)
    let pinnedSha1: String
    let script: SignScript
    let devices: JSONValue

    init(pinnedSha1: String, script: SignScript, devices: JSONValue) {
        self.pinnedSha1 = pinnedSha1
        self.script = script
        self.devices = devices
    }

    var calls: [CommandSpec] { recorded.withLock { $0 } }
    var codesignCalls: [CommandSpec] { calls.filter { $0.executable == "/usr/bin/codesign" } }
    /// The `-s <identity>` calls, in order.
    var signingArgs: [[String]] { codesignCalls.map(\.args).filter { $0.contains("-s") } }

    func run(_ spec: CommandSpec) async -> RunResult {
        recorded.withLock { $0.append(spec) }
        switch spec.executable {
        case "/usr/bin/codesign": return await codesign(spec)
        case "/usr/bin/security":
            // `security cms -D` decodes stdin (the bytes the command read) or `-i <file>`; the "CMS" files in these
            // tests are the plist itself.
            if spec.args == ["cms", "-D"], let stdin = spec.stdin { return RunResult(stdout: String(decoding: stdin, as: UTF8.self)) }
            guard spec.args.count == 4, spec.args.prefix(3) == ["cms", "-D", "-i"],
                let text = try? String(contentsOfFile: spec.args[3], encoding: .utf8)
            else { return RunResult(code: 1) }
            return RunResult(stdout: text)
        case "xcrun":
            guard spec.args.first == "devicectl" else { return RunResult(code: 1) }
            if script.devicectlFails { return RunResult(code: 1) }
            if let path = spec.args.firstIndex(of: "--json-output").map({ spec.args[$0 + 1] }),
                let data = try? JSONEncoder().encode(devices)
            {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            return RunResult()
        default: return await real.run(spec)
        }
    }

    private func codesign(_ spec: CommandSpec) async -> RunResult {
        var args = spec.args
        if let i = args.firstIndex(of: "-s"), i + 1 < args.count {
            let n = signingCalls.withLock { value in
                value += 1
                return value
            }
            if let failure = script.signingFailure { return failure }
            if let limit = script.failAfterSigningCalls, n > limit { return RunResult(code: 1, stderr: "scripted failure") }
            // Only the pinned identity is carried out (ad hoc: there is no real one); a name would not match.
            guard args[i + 1] == pinnedSha1 else { return RunResult(code: 1, stderr: "no identity found") }
            args[i + 1] = "-"
            return await real.run(CommandSpec(executable: spec.executable, args: args, timeout: spec.timeout))
        }
        if let flag = args.first(where: { $0.hasPrefix("--extract-certificates=") }) {
            if let leaf = script.leaf {
                FileManager.default.createFile(atPath: String(flag.dropFirst("--extract-certificates=".count)) + "0", contents: leaf)
            }
            return RunResult()
        }
        let result = await real.run(spec)
        if args.first == "-dvv", result.code == 0 {
            // An ad hoc signature has no team; say what the pinned certificate's would.
            var out = result
            out.stderr = out.stderr.replacingOccurrences(
                of: "TeamIdentifier=not set", with: script.reportedTeam.map { "TeamIdentifier=\($0)" } ?? "TeamIdentifier=not set")
            return out
        }
        return result
    }
}

// MARK: world

enum ManifestMode {
    case approved
    /// The entry exists and is not approved.
    case unapproved
    /// No entry at all.
    case none
    /// Approved at 1.0.0, then a newer fetch that is not.
    case newerUnapproved
    /// The IPA's bytes changed after the manifest recorded them.
    case tampered
    /// The IPA file is gone.
    case missingFile
}

enum ProfileMode {
    case valid
    case noRecord
    case missingFile
    case expired
    case wrongTeam
    case wrongAppId
    case wrongPlatform
    case wrongDevice
    case wrongCertificate
    case noGetTaskAllow
    case undecodable
    case otherUUID
    case symlink
    case foreignFile
    case farFuture
}

struct SignWorld {
    let paths: Paths
    let store: ConfigStore
    let services: Services
    let runner: SignRunner
    let app: SampleApp
    let sha256: String
    let pinnedSha1: String

    var alias: String { app.deviceAlias }
    var key: String { "\(alias)/\(app.rawValue)" }
    var signedRoot: String { paths.signedBuilds }
    var signedApp: String { "\(signedRoot)/\(app.rawValue)/\(alias)/\(app.executable).app" }
    var relativeSigned: String { "builds/signed/\(app.rawValue)/\(alias)/\(app.executable).app" }

    func ledger() throws -> Ledger { try services.ledgerStore.load() }

    func run(
        app: String? = nil, device: String? = nil, yes: Bool = true, registry: ScratchRegistry = ScratchRegistry(),
        hooks: SignHooks = SignHooks()
    ) async -> Envelope {
        await SignCommand.run(
            services, SignOptions(app: app ?? self.app.rawValue, device: device ?? alias, yes: yes), registry: registry, hooks: hooks)
    }

    /// Scratch folders left under `$SIDELOAD_HOME/tmp`.
    var leftovers: [String] { listing(paths.tmp).filter { $0.hasPrefix("sign-") || $0.hasPrefix("inspect-") } }

    /// The printed (redacted) object, as the CLI would write it.
    func printed(_ envelope: Envelope) throws -> (text: String, json: JSONValue) { try envelope.printed() }
}

func profileFile(_ w: SignWorld, uuid: String) -> String {
    "\(w.paths.freeProfiles)/\(w.app.rawValue)/\(w.alias)/\(uuid).mobileprovision"
}

let signProfileUUID = "0F0F0F0F-1111-2222-3333-444444444444"

/// Runs `body` against a temp home with the sample app fetched, approved and provisioned, unless a mode says otherwise.
func withSignWorld(
    app: SampleApp = .stremioIOS, variant: IPAVariant = .real, manifest: ManifestMode = .approved,
    profile: ProfileMode = .valid, pin: Bool = true, script: SignScript = SignScript(), minOS: String? = "15.0",
    declaredMinOS: String? = nil,
    keychain: [KeychainCertificate]? = nil, prefix: String? = carrierPrefix, ledger: ((inout Ledger) -> Void)? = nil,
    config tweak: ((inout Config) -> Void)? = nil, _ body: (SignWorld) async throws -> Void
) async throws {
    let free = try freeKeychainCert()
    let freeDER = try certDER(TestCerts.free)
    var script = script
    if script.leaf == nil { script.leaf = freeDER }
    let ipa = try await SignIPAs.shared.data(app, variant)
    let digest = sha256Hex(ipa)

    var config = provisionConfig(
        prefix: prefix, extra: pin ? ["freeTeam": ["certFp8": .string(LedgerSync.fp8(free.reference))]] : [:])
    tweak?(&config)
    try await withTestHome(config: config) { paths, store in
        // Fetched and approved.
        func entry(version: String, approved: Bool, fetchedAt: Date) -> ManifestEntry {
            ManifestEntry(
                app: app.rawValue, version: version, file: "\(app.rawValue)/\(version)/\(app.ipaName)", urlHost: "example.test",
                sha256: digest, upstreamDigest: digest, size: Int64(ipa.count), fetchedAt: fetchedAt, approved: approved,
                approvedAt: approved ? fetchedAt : nil, build: "142", declaredSize: Int64(ipa.count), minOS: declaredMinOS,
                inspectMinOS: minOS)
        }
        var entries: [ManifestEntry] = []
        let old = testNow.addingTimeInterval(-3 * 86_400)
        switch manifest {
        case .approved, .tampered, .missingFile: entries = [entry(version: app.version, approved: true, fetchedAt: old)]
        case .unapproved: entries = [entry(version: app.version, approved: false, fetchedAt: old)]
        case .none: break
        case .newerUnapproved:
            entries = [
                entry(version: "1.0.0", approved: true, fetchedAt: old.addingTimeInterval(-86_400)),
                entry(version: app.version, approved: false, fetchedAt: old),
            ]
        }
        var manifestFile = Manifest()
        manifestFile.entries = entries
        try ManifestStore(paths: paths).save(manifestFile)
        for e in entries {
            let dir = "\(paths.downloads)/\(e.app)/\(e.version)"
            try makeDirectories(dir, mode: 0o700)
            if manifest == .missingFile { continue }
            var bytes = ipa
            if manifest == .tampered { bytes.append(Data("tampered".utf8)) }
            try bytes.write(to: URL(fileURLWithPath: "\(dir)/\(app.ipaName)"))
        }

        // Provisioned.
        let udid = savedUdid(app.seed)
        let alias = app.deviceAlias
        let uuid = signProfileUUID
        if profile != .noRecord {
            let expires: Date
            switch profile {
            case .expired: expires = testNow.addingTimeInterval(-3600)
            case .farFuture: expires = testNow.addingTimeInterval(30 * 86_400)
            default: expires = daysFromNow(5)
            }
            let xml = try profileXML(
                uuid: profile == .otherUUID ? "AAAAAAAA-1111-2222-3333-444444444444" : uuid,
                team: profile == .wrongTeam ? Team.paid : Team.free,
                applicationIdentifier: Team.free + "." + (profile == .wrongAppId ? app.freeId + "x" : app.freeId),
                getTaskAllow: profile == .noGetTaskAllow ? false : true,
                devices: [profile == .wrongDevice ? savedUdid("9") : udid],
                certs: [profile == .wrongCertificate ? try certDER(TestCerts.other) : freeDER],
                platform: [profile == .wrongPlatform ? (app == .stremioTVOS ? "iOS" : "tvOS") : app.profilePlatform],
                created: daysFromNow(-2), expires: expires)
            let dir = "\(paths.freeProfiles)/\(app.rawValue)/\(alias)"
            try makeDirectories(dir, mode: 0o700)
            let file = "\(dir)/\(uuid).mobileprovision"
            switch profile {
            case .missingFile: break
            case .undecodable: try Data("not a plist".utf8).write(to: URL(fileURLWithPath: file))
            case .symlink:
                let target = paths.home + "/elsewhere.mobileprovision"
                try Data(xml.utf8).write(to: URL(fileURLWithPath: target))
                try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target)
            default: try Data(xml.utf8).write(to: URL(fileURLWithPath: file))
            }
            try await LedgerStore(paths: paths).update { ledger in
                ledger.freeProfiles = [
                    LedgerFreeProfile(
                        id: "\(alias)/\(app.rawValue)", device: alias, deviceTail: Redactor.tail4(udid), app: app.rawValue,
                        bundleId: app.freeId, profileUuid: uuid, created: daysFromNow(-2), expires: expires,
                        certFp8: LedgerSync.fp8(free.reference),
                        file: profile == .foreignFile ? "profiles/free/other/\(uuid).mobileprovision" : "profiles/free/\(app.rawValue)/\(alias)/\(uuid).mobileprovision")
                ]
            }
        }
        if let ledger { try await LedgerStore(paths: paths).update { ledger(&$0) } }

        let entryJSON = deviceEntryJSON(
            name: app == .stremioTVOS ? "Test Apple TV" : "Test iPhone", udid: udid, coreId: savedCoreId(app.seed),
            platform: app == .stremioTVOS ? "tvOS" : "iOS", osVersion: script.deviceOS)
        let runner = SignRunner(pinnedSha1: free.reference.uppercased(), script: script, devices: deviceListJSON(entryJSON))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
            keychain: FakeKeychain(keychain ?? [free]), home: paths)
        try await body(
            SignWorld(
                paths: paths, store: store, services: services, runner: runner, app: app, sha256: digest,
                pinnedSha1: free.reference.uppercased()))
    }
}

// MARK: reading the result

/// `codesign -d --entitlements - --xml <app>`, parsed.
func signedEntitlements(_ app: String) async throws -> [String: Any] {
    let r = await PosixSpawnRunner().run(
        CommandSpec(executable: "/usr/bin/codesign", args: ["-d", "--entitlements", "-", "--xml", app], timeout: .seconds(30)))
    #expect(r.code == 0, "codesign -d failed: \(r.stderr)")
    return (try? PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), options: [], format: nil)) as? [String: Any] ?? [:]
}

func plistDictionary(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
}

/// Every path under `root`, relative, sorted (no symlink followed).
func tree(_ root: String) -> [String] {
    var out: [String] = []
    var pending = [""]
    while let rel = pending.popLast() {
        for name in listing(root + (rel.isEmpty ? "" : "/" + rel)) {
            let child = rel.isEmpty ? name : rel + "/" + name
            out.append(child)
            var st = stat()
            if lstat(root + "/" + child, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { pending.append(child) }
        }
    }
    return out.sorted()
}
