import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Synthetic IPAs for the inspect tests, built at runtime in temp directories. Executables are copies of a system
// Mach-O (`/usr/bin/true`) with the platform rewritten by `vtool`; they are signed ad hoc with `codesign`. No real
// IPA, no network, no device, no keychain identity.

/// Runs a real tool; fails the test on a non-zero exit.
@discardableResult
func tool(_ executable: String, _ args: [String], sourceLocation: SourceLocation = #_sourceLocation) async -> String {
    let result = await PosixSpawnRunner().run(CommandSpec(executable: executable, args: args, timeout: .seconds(60)))
    #expect(result.code == 0, "\(executable) \(args.first ?? "") failed: \(result.stderr)", sourceLocation: sourceLocation)
    return result.stdout
}

func writeText(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

func infoPlist(_ entries: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
}

/// Thin Mach-O templates, made once per test process (one task per kind, so parallel tests share it).
actor MachOTemplates {
    static let shared = MachOTemplates()
    private var tasks: [String: Task<String, any Error>] = [:]
    private var directory: String?

    /// A Mach-O file with the given platform and minimum OS, no code signature. `universal` adds an x86_64 slice.
    func path(platform: String, minOS: String, universal: Bool = false) async throws -> String {
        let key = "\(platform)-\(minOS)-\(universal)"
        if directory == nil { directory = try makeTempDir().path }
        if let task = tasks[key] { return try await task.value }
        let dir = directory!
        let task = Task<String, any Error> {
            let thin = dir + "/\(key)-thin"
            await tool("/usr/bin/lipo", ["-thin", "arm64e", "/usr/bin/true", "-output", thin])
            let platformed = dir + "/\(key)-platformed"
            await tool("/usr/bin/vtool", ["-set-build-version", platform, minOS, "17.0", "-replace", "-output", platformed, thin])
            await tool("/usr/bin/codesign", ["--remove-signature", platformed])
            guard universal else { return platformed }
            let x86 = dir + "/\(key)-x86"
            await tool("/usr/bin/lipo", ["-thin", "x86_64", "/usr/bin/true", "-output", x86])
            let fat = dir + "/\(key)-fat"
            await tool("/usr/bin/lipo", ["-create", platformed, x86, "-output", fat])
            return fat
        }
        tasks[key] = task
        return try await task.value
    }
}

/// One bundle in a synthetic IPA.
struct BundleSpec {
    var directory: String  // relative to the IPA root, e.g. `Payload/Test.app`
    var plist: [String: Any]?
    var executableName: String? = "Test"
    var platform = "ios"
    var minOS = "15.0"
    var universal = false
    var sign: Bool = true
    var entitlements: [String: Any]? = nil
    var extraFiles: [String: Data] = [:]

    static func app(
        _ name: String = "Test", bundleId: String = "io.example.test", executable: String = "Test",
        platform: String = "ios", minOS: String = "15.0", extra: [String: Any] = [:], sign: Bool = true,
        entitlements: [String: Any]? = nil, universal: Bool = false
    ) -> BundleSpec {
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleId, "CFBundleExecutable": executable, "CFBundleName": name,
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45", "MinimumOSVersion": minOS,
            "UIDeviceFamily": [1, 2], "CFBundleSupportedPlatforms": [platform == "ios" ? "iPhoneOS" : "AppleTVOS"],
        ]
        for (k, v) in extra { plist[k] = v }
        return BundleSpec(
            directory: "Payload/\(name).app", plist: plist, executableName: executable, platform: platform, minOS: minOS,
            universal: universal, sign: sign, entitlements: entitlements)
    }

    static func appex(
        _ name: String = "Share", bundleId: String = "io.example.test.share", point: String = "com.apple.share-services",
        sign: Bool = true, entitlements: [String: Any]? = nil, app: String = "Test"
    ) -> BundleSpec {
        BundleSpec(
            directory: "Payload/\(app).app/PlugIns/\(name).appex",
            plist: [
                "CFBundleIdentifier": bundleId, "CFBundleExecutable": name,
                "NSExtension": ["NSExtensionPointIdentifier": point],
            ], executableName: name, sign: sign, entitlements: entitlements)
    }
}

/// Lays out the bundles under `root`, signs each (appex first), and returns nothing; the caller zips `root`.
func layOut(_ bundles: [BundleSpec], at root: String) async throws {
    let fm = FileManager.default
    // Deepest first, so an appex is signed before the app that contains it.
    for bundle in bundles.sorted(by: { $0.directory.count > $1.directory.count }) {
        let dir = root + "/" + bundle.directory
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let plist = bundle.plist { try infoPlist(plist).write(to: URL(fileURLWithPath: dir + "/Info.plist")) }
        if let name = bundle.executableName {
            let template = try await MachOTemplates.shared.path(platform: bundle.platform, minOS: bundle.minOS, universal: bundle.universal)
            try fm.copyItem(atPath: template, toPath: dir + "/" + name)
        }
        for (relative, data) in bundle.extraFiles {
            let path = dir + "/" + relative
            try fm.createDirectory(atPath: parentPath(path), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
    for bundle in bundles.sorted(by: { $0.directory.count > $1.directory.count }) where bundle.sign && bundle.executableName != nil {
        let dir = root + "/" + bundle.directory
        var args = ["-f", "-s", "-"]
        if let entitlements = bundle.entitlements {
            let path = root + "/ent-\(UUID().uuidString).plist"
            try infoPlist(entitlements).write(to: URL(fileURLWithPath: path))
            args += ["--entitlements", path]
        }
        await tool("/usr/bin/codesign", args + [dir])
    }
}

/// A `.ipa` made from `bundles` with the real `ditto`.
func makeIPA(_ bundles: [BundleSpec], in dir: String, name: String = "test.ipa") async throws -> String {
    let root = dir + "/root-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try await layOut(bundles, at: root)
    let ipa = dir + "/" + name
    await tool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", root + "/Payload", ipa])
    try? FileManager.default.removeItem(atPath: root)
    return ipa
}

// MARK: hand-made ZIP files

private let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xffff_ffff
    for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
    return c ^ 0xffff_ffff
}

struct RawZipEntry {
    var name: [UInt8]
    var data: [UInt8] = []
    /// Unix mode (type bits included); 0 leaves the attributes empty.
    var mode: UInt32 = 0o100644
    var host: UInt8 = 3
    var flags: UInt16 = 0
    /// What the central directory claims, when it should lie.
    var declaredSize: UInt32?

    init(_ name: String, _ data: [UInt8] = [], mode: UInt32 = 0o100644) {
        self.name = Array(name.utf8)
        self.data = data
        self.mode = mode
    }
}

/// A stored (uncompressed) ZIP with exactly the bytes and attributes asked for.
func rawZip(_ entries: [RawZipEntry], comment: [UInt8] = []) -> Data {
    var out: [UInt8] = []
    var central: [UInt8] = []
    func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    for entry in entries {
        let offset = UInt32(out.count)
        let crc = crc32(entry.data)
        let size = UInt32(entry.data.count)
        out += le32(0x0403_4b50) + le16(20) + le16(entry.flags) + le16(0) + le16(0) + le16(0x21) + le32(crc) + le32(size) + le32(size)
        out += le16(UInt16(entry.name.count)) + le16(0) + entry.name + entry.data
        central += le32(0x0201_4b50) + le16(UInt16(entry.host) << 8 | 20) + le16(20) + le16(entry.flags) + le16(0) + le16(0) + le16(0x21)
        central += le32(crc) + le32(size) + le32(entry.declaredSize ?? size) + le16(UInt16(entry.name.count)) + le16(0) + le16(0)
        central += le16(0) + le16(0) + le32(entry.mode << 16) + le32(offset) + entry.name
    }
    let cdOffset = UInt32(out.count)
    out += central
    out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
    out += le32(UInt32(central.count)) + le32(cdOffset) + le16(UInt16(comment.count)) + comment
    return Data(out)
}

// MARK: running inspect

/// Records every spec and delegates to the real runner.
final class RecordingRunner: Runner {
    private let inner: any Runner
    private let recorded = Mutex<[CommandSpec]>([])
    private let afterRun: (@Sendable (CommandSpec) -> Void)?

    init(_ inner: any Runner = PosixSpawnRunner(), afterRun: (@Sendable (CommandSpec) -> Void)? = nil) {
        self.inner = inner
        self.afterRun = afterRun
    }

    var calls: [CommandSpec] { recorded.withLock { $0 } }

    func run(_ spec: CommandSpec) async -> RunResult {
        recorded.withLock { $0.append(spec) }
        let result = await inner.run(spec)
        afterRun?(spec)
        return result
    }
}

struct InspectWorld {
    var envelope: Envelope
    var json: JSONValue
    var text: String
    var runner: RecordingRunner
    var paths: Paths
    var code: String? { envelope.errors.first?.code }
    /// Scratch folders left under `$SIDELOAD_HOME/tmp`.
    var leftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: paths.tmp)) ?? []).filter { $0.hasPrefix("inspect-") } }
}

/// Runs `inspect` over a temp home with a recording real runner. `prepare` builds the IPA inside the temp directory.
func inspectIPA(
    limits: InspectLimits = InspectLimits(), registry: ScratchRegistry = ScratchRegistry(),
    runner makeRunner: (@Sendable () -> RecordingRunner)? = nil,
    prepare: (_ dir: String) async throws -> String
) async throws -> InspectWorld {
    try await withTestHome { paths, _ in
        try await inspectIn(paths: paths, limits: limits, registry: registry, makeRunner: makeRunner, prepare: prepare)
    }
}

private func inspectIn(
    paths: Paths, limits: InspectLimits, registry: ScratchRegistry, makeRunner: (@Sendable () -> RecordingRunner)?,
    prepare: (String) async throws -> String
) async throws -> InspectWorld {
    let workDir = paths.home + "/ipas"
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    let ipa = try await prepare(workDir)
    let runner = makeRunner?() ?? RecordingRunner()
    var services = Services(
        runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(), home: paths)
    services.log = { _ in }
    let envelope = await InspectCommand.run(services, InspectOptions(path: ipa), registry: registry, limits: limits)
    let (text, json) = try envelope.printed()
    return InspectWorld(envelope: envelope, json: json, text: text, runner: runner, paths: paths)
}
