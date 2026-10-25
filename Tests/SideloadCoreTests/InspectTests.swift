import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

private let marker = "SECRETMARKER-4417"

private extension JSONValue {
    var strings: [String]? { array?.compactMap(\.string) }
    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

private func expectFailure(
    _ w: InspectWorld, _ code: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!w.envelope.ok, sourceLocation: sourceLocation)
    #expect(w.code == code, "got \(w.code ?? "ok")", sourceLocation: sourceLocation)
    #expect(w.leftovers.isEmpty, "the scratch folder must be gone", sourceLocation: sourceLocation)
    #expect(!w.text.contains(marker), "an error must not echo file content", sourceLocation: sourceLocation)
}

@Suite("inspect: report")
struct InspectReportTests {
    private let groupEntitlements: [String: Any] = [
        "application-identifier": "TEAM123456.io.example.test", "get-task-allow": true,
        "com.apple.security.application-groups": ["group.io.example", "group.io.example.shared"],
    ]

    @Test("reports the app, its extension, groups, architectures and the hash; leaves no scratch folder")
    func fullReport() async throws {
        var reference = ""
        var ipaSize = 0
        let w = try await inspectIPA { dir in
            let ipaPath = try await makeIPA(
                [
                    .app(extra: ["CFBundleDisplayName": "Test Display"], entitlements: groupEntitlements),
                    .appex(entitlements: ["com.apple.security.application-groups": ["group.io.example", "group.io.example.share"]]),
                ], in: dir)
            ipaSize = try Data(contentsOf: URL(fileURLWithPath: ipaPath)).count
            reference = await tool("/usr/bin/shasum", ["-a", "256", ipaPath])
            return ipaPath
        }
        #expect(w.envelope.ok, "\(w.text)")
        let app = try #require(w.json["app"])
        #expect(app["bundleId"] == "io.example.test")
        #expect(app["name"] == "Test Display")
        #expect(app["version"] == "1.2.3")
        #expect(app["build"] == "45")
        #expect(app["minOS"] == "15.0")
        #expect(app["platform"] == "ios")
        #expect(app["deviceFamily"] == [1, 2])
        #expect(app["executable"] == "Test")
        #expect(app["architectures"] == ["arm64e"])
        #expect(app["signed"] == true)
        #expect(app["entitlements"]?["get-task-allow"] == true)
        #expect(app["entitlements"]?["application-identifier"] == "TEAM123456.io.example.test")
        #expect(app["appGroups"] == ["group.io.example", "group.io.example.shared"])

        let extensions = try #require(w.json["extensions"]?.array)
        #expect(extensions.count == 1)
        #expect(extensions[0]["path"] == "PlugIns/Share.appex")
        #expect(extensions[0]["bundleId"] == "io.example.test.share")
        #expect(extensions[0]["extensionPoint"] == "com.apple.share-services")
        #expect(extensions[0]["executable"] == "Share")
        #expect(extensions[0]["architectures"] == ["arm64e"])
        #expect(extensions[0]["signed"] == true)
        #expect(extensions[0]["appGroups"] == ["group.io.example", "group.io.example.share"])
        #expect(w.json["appGroups"] == ["group.io.example", "group.io.example.share", "group.io.example.shared"])
        #expect(w.json["hasEmbeddedProvision"] == false)
        #expect(w.json["otherCode"] == ["frameworks": 0, "dylibs": 0, "watchApps": 0])
        #expect(w.json["warnings"] == [])

        let ipa = try #require(w.json["ipa"])
        #expect(ipa["sizeBytes"]?.number == Double(ipaSize))
        #expect(ipa["sha256"]?.string?.count == 64)
        #expect(reference.hasPrefix(ipa["sha256"]?.string ?? "?"))

        #expect(w.leftovers.isEmpty)
        #expect(!w.text.contains("inspect-"), "the scratch path must not be printed")
        #expect(w.runner.calls.allSatisfy { $0.executable.hasPrefix("/usr/bin/") && $0.timeout > .zero })
    }

    @Test("an unsigned binary reports signed false and entitlements null")
    func unsigned() async throws {
        let w = try await inspectIPA { try await makeIPA([.app(sign: false)], in: $0) }
        #expect(w.envelope.ok, "\(w.text)")
        #expect(w.json["app"]?["signed"] == false)
        #expect(w.json["app"]?["entitlements"] == .null)
        #expect(w.json["app"]?["appGroups"] == [])
    }

    @Test("a signed binary without entitlements has an empty entitlements object")
    func signedWithoutEntitlements() async throws {
        let w = try await inspectIPA { try await makeIPA([.app()], in: $0) }
        #expect(w.json["app"]?["signed"] == true)
        #expect(w.json["app"]?["entitlements"] == [:])
    }

    @Test("tvOS: platform and minimum OS come from the Mach-O build version; the device family from the plist")
    func tvos() async throws {
        let w = try await inspectIPA {
            try await makeIPA([.app(platform: "tvos", minOS: "16.1", extra: ["UIDeviceFamily": [3]])], in: $0)
        }
        #expect(w.envelope.ok, "\(w.text)")
        #expect(w.json["app"]?["platform"] == "tvos")
        #expect(w.json["app"]?["minOS"] == "16.1")
        #expect(w.json["app"]?["deviceFamily"] == [3])
    }

    @Test("a universal binary lists every architecture")
    func universal() async throws {
        let w = try await inspectIPA { try await makeIPA([.app(universal: true)], in: $0) }
        let archs = Set(try #require(w.json["app"]?["architectures"]?.strings))
        #expect(archs == ["arm64e", "x86_64"])
    }

    @Test("frameworks, dylibs, watch apps and the embedded profile are counted without being read")
    func otherCode() async throws {
        var app = BundleSpec.app(sign: false)
        let blob = Data(marker.utf8)
        app.extraFiles = [
            "Frameworks/A.framework/A": blob, "Frameworks/B.framework/B": blob, "Frameworks/libx.dylib": blob,
            "Watch/W.app/Info.plist": blob, "embedded.mobileprovision": blob,
        ]
        let w = try await inspectIPA { try await makeIPA([app], in: $0) }
        #expect(w.envelope.ok, "\(w.text)")
        #expect(w.json["otherCode"] == ["frameworks": 2, "dylibs": 1, "watchApps": 1])
        #expect(w.json["hasEmbeddedProvision"] == true)
        #expect(!w.text.contains(marker))
    }

    @Test("long plist and entitlement strings are cut to 256 characters")
    func longStrings() async throws {
        let long = String(repeating: "x", count: 1000)
        let w = try await inspectIPA {
            try await makeIPA([.app(extra: ["CFBundleDisplayName": long], entitlements: ["com.example.long": long])], in: $0)
        }
        #expect(w.envelope.ok, "\(w.text)")
        #expect(w.json["app"]?["name"]?.string?.count == 256)
        #expect(w.json["app"]?["entitlements"]?["com.example.long"]?.string?.count == 256)
    }

    @Test("unsigned is recognised only by codesign's own message for this path and exit status 1")
    func unsignedIsAnchored() async {
        func signature(code: Int32, stderr: String) async -> BinaryTools.Signature {
            let runner = FakeRunner { _ in RunResult(code: code, stderr: stderr) }
            return await BinaryTools(runner: runner, limits: InspectLimits()).signature(of: "/x/a.app")
        }
        if case .unsigned = await signature(code: 1, stderr: "/x/a.app: code object is not signed at all\n") {} else { Issue.record("exact message") }
        for (code, text) in [
            (Int32(1), "/x/other.app: code object is not signed at all\n"),
            (1, "error in /x/code object is not signed at all/a.app: invalid signature\n"),
            (1, "/x/a.app: code object is not signed at all (really)\n"),
            (2, "/x/a.app: code object is not signed at all\n"),
        ] {
            if case .unknown = await signature(code: code, stderr: text) {} else { Issue.record("must not be unsigned: \(text)") }
        }
    }

    @Test("build-version output is parsed for LC_BUILD_VERSION and the older LC_VERSION_MIN forms")
    func buildVersionParsing() {
        let modern = "x:\nLoad command 9\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform IOS\n    minos 15.0\n      sdk 17.0\n   ntools 1\n     tool LD\n  version 27037.1\n"
        #expect(BinaryTools.parseBuildVersion(modern) == BinaryTools.BuildVersion(platform: "ios", minOS: "15.0"))
        let old = "Load command 9\n      cmd LC_VERSION_MIN_IPHONEOS\n  cmdsize 16\n  version 9.0\n      sdk 12.0\n"
        #expect(BinaryTools.parseBuildVersion(old) == BinaryTools.BuildVersion(platform: "ios", minOS: "9.0"))
        #expect(BinaryTools.parseBuildVersion("not mach-o") == nil)
        #expect(BinaryTools.parseBuildVersion("cmd LC_BUILD_VERSION\n platform <script>\n minos 1.0\n") == nil)
    }
}

struct HostileEntry: Sendable, CustomTestStringConvertible {
    var label: String
    var entry: RawZipEntry
    var testDescription: String { label }
}

@Suite("inspect: untrusted archive")
struct InspectArchiveTests {
    private static let hostile: [HostileEntry] = [
        HostileEntry(label: "parent directory", entry: RawZipEntry("\(marker)/../../evil")),
        HostileEntry(label: "leading ..", entry: RawZipEntry("../\(marker)")),
        HostileEntry(label: "absolute", entry: RawZipEntry("/tmp/\(marker)")),
        HostileEntry(label: "backslash", entry: RawZipEntry("Payload\\..\\\(marker)")),
        HostileEntry(label: "control character", entry: RawZipEntry("Payload/a\nb\(marker)")),
        HostileEntry(label: "empty name", entry: RawZipEntry("")),
        HostileEntry(label: "symlink", entry: RawZipEntry("Payload/Test.app/\(marker)", Array("/etc".utf8), mode: 0o120755)),
        HostileEntry(label: "symlink, host 0", entry: { var e = RawZipEntry("Payload/Test.app/\(marker)", Array("/etc".utf8), mode: 0o120755); e.host = 0; return e }()),
        HostileEntry(label: "symlink, host 1", entry: { var e = RawZipEntry("Payload/Test.app/\(marker)", Array("/etc".utf8), mode: 0o120755); e.host = 1; return e }()),
        HostileEntry(label: "device node, host 0", entry: { var e = RawZipEntry("Payload/\(marker)", mode: 0o060644); e.host = 0; return e }()),
        HostileEntry(label: "device node", entry: RawZipEntry("Payload/\(marker)", mode: 0o060644)),
        HostileEntry(label: "FIFO", entry: RawZipEntry("Payload/\(marker)", mode: 0o010644)),
        HostileEntry(
            label: "NUL byte", entry: { var e = RawZipEntry(""); e.name = Array("Payload/ok".utf8) + [0] + Array("../../\(marker)".utf8); return e }()),
    ]

    @Test("an unsafe entry is a hard failure before anything runs or is extracted", arguments: hostile)
    func unsafeEntry(_ hostile: HostileEntry) async throws {
        let w = try await inspectIPA { dir in
            let path = dir + "/hostile.ipa"
            try rawZip([RawZipEntry("Payload/", mode: 0o040755), hostile.entry]).write(to: URL(fileURLWithPath: path))
            return path
        }
        expectFailure(w, "IPA_UNSAFE_ENTRY")
        #expect(w.runner.calls.isEmpty, "no tool may run on a refused archive")
    }

    @Test("a symlink that ditto itself recorded is refused")
    func realSymlink() async throws {
        let w = try await inspectIPA { dir in
            let root = dir + "/root"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try await layOut([.app(sign: false)], at: root)
            try FileManager.default.createSymbolicLink(atPath: root + "/Payload/Test.app/link", withDestinationPath: "/etc")
            let ipa = dir + "/link.ipa"
            await tool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", root + "/Payload", ipa])
            return ipa
        }
        expectFailure(w, "IPA_UNSAFE_ENTRY")
        #expect(w.runner.calls.isEmpty)
    }

    @Test("not a ZIP, truncated, or with trailing bytes")
    func notZip() async throws {
        let good = rawZip([RawZipEntry("Payload/", mode: 0o040755)])
        let cases: [Data] = [
            Data(marker.utf8), Data(), good.dropLast(5), good + Data([1, 2, 3]),
        ]
        for bytes in cases {
            let w = try await inspectIPA { dir in
                try bytes.write(to: URL(fileURLWithPath: dir + "/x.ipa"))
                return dir + "/x.ipa"
            }
            expectFailure(w, "IPA_NOT_ZIP")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("an encrypted entry is unsupported")
    func encrypted() async throws {
        var entry = RawZipEntry("Payload/a")
        entry.flags = 1
        let w = try await inspectIPA { dir in
            try rawZip([entry]).write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_UNSUPPORTED_ZIP")
    }

    @Test("too many entries, a declared size over the limit, and a file over the limit")
    func limits() async throws {
        var small = InspectLimits()
        small.maxEntries = 2
        let three = rawZip([RawZipEntry("a"), RawZipEntry("b"), RawZipEntry("c")])
        var w = try await inspectIPA(limits: small) { dir in
            try three.write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_TOO_MANY_ENTRIES")
        #expect(w.runner.calls.isEmpty)

        var tiny = InspectLimits()
        tiny.maxTotalBytes = 100
        var big = RawZipEntry("Payload/big")
        big.declaredSize = 5000
        w = try await inspectIPA(limits: tiny) { dir in
            try rawZip([big]).write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_TOO_LARGE")
        #expect(w.runner.calls.isEmpty)

        var capped = InspectLimits()
        capped.maxFileBytes = 50
        w = try await inspectIPA(limits: capped) { dir in
            try three.write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_TOO_LARGE")
        #expect(w.runner.calls.isEmpty)
    }

    @Test("a header that lies about the size is caught by the extracted bytes")
    func lyingHeader() async throws {
        var liar = RawZipEntry("Payload/Test.app/big", [UInt8](repeating: 7, count: 3 << 20))
        liar.declaredSize = 10
        var limits = InspectLimits()
        limits.maxTotalBytes = 1 << 20
        let w = try await inspectIPA(limits: limits) { dir in
            try rawZip([RawZipEntry("Payload/", mode: 0o040755), RawZipEntry("Payload/Test.app/", mode: 0o040755), liar])
                .write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_TOO_LARGE")
        #expect(w.runner.calls.first?.executable == "/usr/bin/ditto", "the declared sizes passed the pre-check")
    }

    @Test("a missing file, a symlink and a directory are not an IPA")
    func notAFile() async throws {
        for make in [
            { (dir: String) -> String in dir + "/missing.ipa" },
            { (dir: String) -> String in
                let target = dir + "/real.ipa"
                try? rawZip([]).write(to: URL(fileURLWithPath: target))
                try? FileManager.default.createSymbolicLink(atPath: dir + "/link.ipa", withDestinationPath: target)
                return dir + "/link.ipa"
            },
            { (dir: String) -> String in dir },
        ] {
            let w = try await inspectIPA { make($0) }
            expectFailure(w, "IPA_NOT_FOUND")
        }
    }

    @Test("no app, and two apps")
    func appCount() async throws {
        var w = try await inspectIPA { dir in
            try rawZip([RawZipEntry("readme.txt", Array("hi".utf8))]).write(to: URL(fileURLWithPath: dir + "/x.ipa"))
            return dir + "/x.ipa"
        }
        expectFailure(w, "IPA_NO_APP")
        w = try await inspectIPA { try await makeIPA([.app("One", executable: "One"), .app("Two", executable: "Two")], in: $0) }
        expectFailure(w, "IPA_MULTIPLE_APPS")
    }
}

@Suite("inspect: bundle contents")
struct InspectBundleTests {
    @Test("an executable name with a path is refused", arguments: ["../Test", "/bin/sh", "a/b", "..", ".", ""])
    func executableName(_ name: String) async throws {
        var app = BundleSpec.app(executable: name, sign: false)
        app.executableName = nil  // the name is refused before any file is looked for
        let w = try await inspectIPA { try await makeIPA([app], in: $0) }
        expectFailure(w, "IPA_EXECUTABLE_INVALID")
        #expect(!w.runner.calls.contains { $0.executable != "/usr/bin/ditto" }, "no binary tool may run on it")
    }

    @Test("an executable that is not in the bundle")
    func executableMissing() async throws {
        var app = BundleSpec.app(sign: false)
        app.executableName = nil
        let w = try await inspectIPA { try await makeIPA([app], in: $0) }
        expectFailure(w, "IPA_EXECUTABLE_INVALID")
    }

    @Test("an executable that is not Mach-O")
    func notMachO() async throws {
        var app = BundleSpec.app(sign: false)
        app.executableName = nil
        app.extraFiles = ["Test": Data(marker.utf8)]
        let w = try await inspectIPA { try await makeIPA([app], in: $0) }
        expectFailure(w, "IPA_NOT_MACHO")
    }

    @Test("a missing Info.plist, a garbage one, one without an identifier, and an oversized one")
    func infoPlist() async throws {
        var missing = BundleSpec.app(sign: false)
        missing.plist = nil
        var w = try await inspectIPA { try await makeIPA([missing], in: $0) }
        expectFailure(w, "INFO_PLIST_MISSING")

        var garbage = BundleSpec.app(sign: false)
        garbage.plist = nil
        garbage.extraFiles = ["Info.plist": Data("<plist><dict>\(marker)".utf8)]
        w = try await inspectIPA { try await makeIPA([garbage], in: $0) }
        expectFailure(w, "INFO_PLIST_INVALID")

        var noId = BundleSpec.app(sign: false)
        noId.plist?["CFBundleIdentifier"] = nil
        w = try await inspectIPA { try await makeIPA([noId], in: $0) }
        expectFailure(w, "INFO_PLIST_INVALID")

        var limits = InspectLimits()
        limits.maxPlistBytes = 64
        w = try await inspectIPA(limits: limits) { try await makeIPA([.app(sign: false)], in: $0) }
        expectFailure(w, "INFO_PLIST_TOO_LARGE")
    }

    @Test("an extension with a bad executable fails the whole inspection")
    func badExtension() async throws {
        var appex = BundleSpec.appex(sign: false)
        appex.plist?["CFBundleExecutable"] = "../Share"
        let w = try await inspectIPA { try await makeIPA([.app(sign: false), appex], in: $0) }
        expectFailure(w, "IPA_EXECUTABLE_INVALID")
    }
}

/// Runs the real `ditto`, then does what the closure says to the extraction folder.
private func tampering(_ change: @escaping @Sendable (_ dest: String) -> Void) -> @Sendable () -> RecordingRunner {
    { RecordingRunner(afterRun: { spec in if spec.executable == "/usr/bin/ditto", let dest = spec.args.last { change(dest) } }) }
}

@Suite("inspect: extracted tree and cleanup")
struct InspectTreeTests {
    @Test("a symlink in the extracted tree is refused even if the listing was clean")
    func symlinkAfterExtraction() async throws {
        let w = try await inspectIPA(
            runner: tampering { dest in
                try? FileManager.default.createSymbolicLink(atPath: dest + "/Payload/Test.app/evil", withDestinationPath: "/etc")
            }
        ) { try await makeIPA([.app(sign: false)], in: $0) }
        expectFailure(w, "IPA_UNSAFE_TREE")
    }

    @Test("a FIFO or a hard link in the extracted tree is refused")
    func specialFiles() async throws {
        var w = try await inspectIPA(
            runner: tampering { dest in _ = mkfifo(dest + "/Payload/Test.app/pipe", 0o600) }
        ) { try await makeIPA([.app(sign: false)], in: $0) }
        expectFailure(w, "IPA_UNSAFE_TREE")
        w = try await inspectIPA(
            runner: tampering { dest in _ = link(dest + "/Payload/Test.app/Info.plist", dest + "/Payload/Test.app/again") }
        ) { try await makeIPA([.app(sign: false)], in: $0) }
        expectFailure(w, "IPA_UNSAFE_TREE")
    }

    @Test("an interrupt during extraction removes the folder and ends the command")
    func interruptDuringExtraction() async throws {
        let registry = ScratchRegistry()
        let w = try await inspectIPA(
            registry: registry,
            runner: tampering { _ in registry.removeAllAndClose() }
        ) { try await makeIPA([.app(sign: false)], in: $0) }
        expectFailure(w, "CANCELLED")
        #expect(registry.isEmpty)
    }

    @Test("extraction that passes the size cap is stopped through task cancellation")
    func monitorStopsDitto() async throws {
        struct Flooding: Runner {
            let cancelled: Flag
            func run(_ spec: CommandSpec) async -> RunResult {
                guard spec.executable == "/usr/bin/ditto", let dest = spec.args.last else { return RunResult() }
                FileManager.default.createFile(atPath: dest + "/flood", contents: Data(count: 2 << 20))
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                cancelled.set()
                return RunResult(code: nil, signal: SIGTERM)
            }
        }
        var limits = InspectLimits()
        limits.maxTotalBytes = 1 << 20
        limits.monitorInterval = .milliseconds(20)
        let flag = Flag()
        let w = try await inspectIPA(limits: limits, runner: { RecordingRunner(Flooding(cancelled: flag)) }) {
            try await makeIPA([.app(sign: false)], in: $0)
        }
        expectFailure(w, "IPA_TOO_LARGE")
        #expect(flag.isSet, "the runner must have been cancelled")
    }

    @Test("a scratch folder that cannot be removed is reported on success and next to the error on failure")
    func removalFailureIsReported() async throws {
        // An immutable tmp/ stops the final rmdir of the scratch folder; everything inside it is still removed.
        let lockTmp = tampering { dest in _ = chflags(parentPath(parentPath(dest)), UInt32(UF_IMMUTABLE)) }
        var garbage = BundleSpec.app(sign: false)
        garbage.plist = nil
        garbage.extraFiles = ["Info.plist": Data("<plist><dict>".utf8)]
        for (spec, code) in [(BundleSpec.app(sign: false), nil), (garbage, "INFO_PLIST_INVALID")] as [(BundleSpec, String?)] {
            let w = try await inspectIPA(runner: lockTmp) { try await makeIPA([spec], in: $0) }
            defer {
                _ = chflags(w.paths.tmp, 0)
                _ = ScratchDirectory.removeTree(w.paths.home)
            }
            #expect(w.envelope.ok == (code == nil))
            #expect(w.code == code)
            let warnings = w.json["warnings"]?.array ?? []
            #expect(warnings.contains { $0["code"] == "SCRATCH_NOT_REMOVED" }, "got \(w.text)")
        }
    }

    @Test("an unexpected error keeps the leftover warning and never echoes its own description")
    func unexpectedErrorCarriesWarning() {
        struct Odd: Error, CustomStringConvertible { var description: String { marker } }
        let warning = CanaryCommand.warning("SCRATCH_NOT_REMOVED", "m", "f")
        let wrapped = IPAInspector.carrying(warning, Odd())
        #expect(wrapped.code == "INTERNAL_ERROR" && !wrapped.message.contains(marker))
        #expect(wrapped.data["warnings"] == [warning])
        let kept = IPAInspector.carrying(warning, SideloadError("IPA_NO_APP", "x", data: ["warnings": [["code": "A"]]]))
        #expect(kept.code == "IPA_NO_APP" && kept.data["warnings"]?.array?.count == 2)
    }

    @Test("verify refuses symlinks, FIFOs, hard links, deep trees and too many entries")
    func verify() throws {
        let dir = try makeTempDir().path
        defer { _ = ScratchDirectory.removeTree(dir) }
        func fresh(_ name: String) throws -> String {
            let path = dir + "/" + name
            try FileManager.default.createDirectory(atPath: path + "/a", withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path + "/a/f"))
            return path
        }
        let limits = InspectLimits()
        #expect(try ExtractedTree.verify(root: try fresh("ok"), limits: limits).entries == 2)

        let symlinked = try fresh("symlinked")
        try FileManager.default.createSymbolicLink(atPath: symlinked + "/a/s", withDestinationPath: "/")
        #expect(throws: SideloadError.self) { try ExtractedTree.verify(root: symlinked, limits: limits) }

        let fifo = try fresh("fifo")
        _ = mkfifo(fifo + "/a/p", 0o600)
        #expect(throws: SideloadError.self) { try ExtractedTree.verify(root: fifo, limits: limits) }

        let hard = try fresh("hard")
        _ = link(hard + "/a/f", hard + "/a/g")
        #expect(throws: SideloadError.self) { try ExtractedTree.verify(root: hard, limits: limits) }

        let deep = try fresh("deep")
        try FileManager.default.createDirectory(atPath: deep + "/a/b/c/d/e", withIntermediateDirectories: true)
        var shallow = InspectLimits()
        shallow.maxTreeDepth = 3
        #expect(throws: SideloadError.self) { try ExtractedTree.verify(root: deep, limits: shallow) }

        var few = InspectLimits()
        few.maxEntries = 0
        #expect(throws: SideloadError.self) { try ExtractedTree.verify(root: try fresh("many"), limits: few) }
    }

    @Test("removal handles unreadable directories and read-only files, and never follows a symlink out")
    func removal() throws {
        let outside = try makeTempDir().path
        defer { _ = ScratchDirectory.removeTree(outside) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: outside + "/precious"))

        let tree = try makeTempDir().path
        try FileManager.default.createDirectory(atPath: tree + "/locked/inner", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: tree + "/locked/inner/ro"))
        chmod(tree + "/locked/inner/ro", 0o400)
        try FileManager.default.createSymbolicLink(atPath: tree + "/locked/out", withDestinationPath: outside)
        chmod(tree + "/locked/inner", 0o000)
        chmod(tree + "/locked", 0o000)

        #expect(ScratchDirectory.removeTree(tree))
        #expect(!FileManager.default.fileExists(atPath: tree))
        #expect(FileManager.default.fileExists(atPath: outside + "/precious"))
    }

    @Test("the registry removes what is registered, refuses new folders after closing, and is idempotent")
    func registry() throws {
        let registry = ScratchRegistry()
        let tmp = try makeTempDir().path
        defer { _ = ScratchDirectory.removeTree(tmp) }
        let first = try ScratchDirectory.create(under: tmp, registry: registry)
        #expect(!registry.isEmpty)
        #expect(modeOf(first.path) == 0o700)
        registry.removeAllAndClose()
        registry.removeAllAndClose()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(first.remove(), "removing again is fine")
        #expect(throws: SideloadError.self) { try ScratchDirectory.create(under: tmp, registry: registry) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp).isEmpty, "a refused folder is not left behind")
    }
}

final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

@Suite("inspect: command")
struct InspectCommandTests {
    @Test("every subprocess is an Apple tool by absolute path with a timeout; nothing else is touched")
    func onlyAppleTools() async throws {
        let w = try await inspectIPA { try await makeIPA([.app(), .appex()], in: $0) }
        #expect(w.envelope.ok, "\(w.text)")
        let allowed: Set<String> = ["/usr/bin/ditto", "/usr/bin/lipo", "/usr/bin/vtool", "/usr/bin/codesign"]
        #expect(Set(w.runner.calls.map(\.executable)).isSubset(of: allowed))
        #expect(w.runner.calls.allSatisfy { $0.timeout > .zero && $0.stdin == nil })
        // $SIDELOAD_HOME holds what ensureHome made plus the test's own files: no config, ledger, log or lock.
        let after = (try? FileManager.default.contentsOfDirectory(atPath: w.paths.home)) ?? []
        #expect(Set(after).isDisjoint(with: ["config.json", "ledger.json", ".op.lock", ".config.lock", ".ledger.lock"]))
    }

    @Test("the CLI: usage errors, help, and the built list")
    func cli() async throws {
        try await withTestHome { paths, _ in
            let (services, runner) = fakeServices(paths)
            var envelope = await run(argv: ["inspect"], services: services)
            #expect(envelope.errorCodes == ["USAGE"])
            envelope = await run(argv: ["inspect", "a.ipa", "b.ipa"], services: services)
            #expect(envelope.errorCodes == ["USAGE"])
            envelope = await run(argv: ["inspect", "--bogus", "a.ipa"], services: services)
            #expect(envelope.errorCodes == ["USAGE"])
            envelope = await run(argv: ["inspect", paths.home + "/nope.ipa"], services: services)
            #expect(envelope.errorCodes == ["IPA_NOT_FOUND"])
            #expect(runner.calls.isEmpty)
            let help = try await run(argv: ["help"], services: services).printed().json
            #expect(help["built"]?.array?.contains("inspect") == true)
        }
    }
}
