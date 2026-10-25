import Darwin
import Foundation
import Testing

@testable import SideloadCore

// The Info.plist rewrite, the profile swap and the signing order. The order is read from the argv a fake Runner
// records; the last suite runs the real `codesign` ad hoc over a synthetic bundle.

private func tempDir() throws -> String { try makeTempDir().path }

@Suite("BundleRewriter")
struct BundleRewriterTests {
    private func write(_ plist: [String: Any], format: PropertyListSerialization.PropertyListFormat, to path: String, mode: mode_t = 0o644) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: URL(fileURLWithPath: path))
        chmod(path, mode)
    }

    @Test("CFBundleIdentifier is replaced and the file keeps its format, its other keys and its mode")
    func keepsFormat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original: [String: Any] = [
            "CFBundleIdentifier": "com.stremio.pal", "CFBundleName": "Stremio", "UIDeviceFamily": [1, 2], "Flag": true, "Count": 3,
        ]
        for (format, magic) in [(PropertyListSerialization.PropertyListFormat.xml, "<?xml"), (.binary, "bplist00")] {
            let path = dir + "/Info-\(format.rawValue).plist"
            try write(original, format: format, to: path, mode: 0o640)
            let old = try BundleRewriter.setBundleIdentifier(infoPlist: path, to: stremioId)
            #expect(old == "com.stremio.pal")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(String(decoding: bytes.prefix(magic.utf8.count), as: UTF8.self) == magic, "\(format)")
            var read = PropertyListSerialization.PropertyListFormat.openStep
            let back = try #require(try PropertyListSerialization.propertyList(from: bytes, options: [], format: &read) as? [String: Any])
            #expect(read == format)
            #expect(back["CFBundleIdentifier"] as? String == stremioId)
            #expect(back["CFBundleName"] as? String == "Stremio" && back["UIDeviceFamily"] as? [Int] == [1, 2])
            #expect(back["Flag"] as? Bool == true && back["Count"] as? Int == 3)
            #expect(modeOf(path) == 0o640)
        }
        #expect(listing(dir).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("no CFBundleIdentifier, not a plist, a symlink or a folder -> INFO_PLIST_INVALID, and nothing is written")
    func invalid() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(["CFBundleName": "x"], format: .xml, to: dir + "/none.plist")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: dir + "/junk.plist"))
        try write(["CFBundleIdentifier": "a"], format: .xml, to: dir + "/real.plist")
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.plist", withDestinationPath: dir + "/real.plist")
        try FileManager.default.createDirectory(atPath: dir + "/dir.plist", withIntermediateDirectories: true)
        for name in ["none.plist", "junk.plist", "link.plist", "dir.plist", "absent.plist"] {
            do {
                try BundleRewriter.setBundleIdentifier(infoPlist: dir + "/" + name, to: "x.y")
                Issue.record("\(name) was accepted")
            } catch {
                #expect(errorCode(of: error) == "INFO_PLIST_INVALID", "\(name)")
            }
        }
        #expect(try plistDictionary(dir + "/real.plist")["CFBundleIdentifier"] as? String == "a", "the link's target is untouched")
    }

    @Test("an oversize Info.plist is refused")
    func oversize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(["CFBundleIdentifier": "a"], format: .xml, to: dir + "/Info.plist")
        #expect(throws: SideloadError.self) { try BundleRewriter.setBundleIdentifier(infoPlist: dir + "/Info.plist", to: "b", maxBytes: 10) }
    }

    @Test("the old _CodeSignature and embedded.mobileprovision go (a folder, a file or a link), and the new profile bytes are put in")
    func profile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let app = dir + "/Test.app"
        try FileManager.default.createDirectory(atPath: app + "/_CodeSignature", withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: URL(fileURLWithPath: app + "/_CodeSignature/CodeResources"))
        try FileManager.default.createDirectory(atPath: dir + "/elsewhere", withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: dir + "/elsewhere/old.mobileprovision"))
        try FileManager.default.createSymbolicLink(
            atPath: app + "/embedded.mobileprovision", withDestinationPath: dir + "/elsewhere/old.mobileprovision")
        let new = Data((0..<256).map { UInt8($0) })
        try BundleRewriter.installProfile(new, into: app)
        #expect(listing(app).sorted() == ["embedded.mobileprovision"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: app + "/embedded.mobileprovision")) == new)
        #expect(modeOf(app + "/embedded.mobileprovision") == 0o644)
        #expect(try String(contentsOfFile: dir + "/elsewhere/old.mobileprovision", encoding: .utf8) == "keep", "the link target is untouched")
    }

    @Test("an app with neither is fine too")
    func profileFresh() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Test.app", withIntermediateDirectories: true)
        try BundleRewriter.installProfile(Data("p".utf8), into: dir + "/Test.app")
        #expect(listing(dir + "/Test.app") == ["embedded.mobileprovision"])
    }
}

/// A tree with nested code in several places and depths (plain files; the fake runner never reads them).
private func nestedTree() throws -> (root: String, app: String) {
    let root = try tempDir()
    let app = root + "/Test.app"
    let fm = FileManager.default
    for dir in [
        "Frameworks/A.framework", "Frameworks/B.framework/Frameworks/Inner.framework", "Frameworks/A.framework/Libs", "PlugIns", "Assets",
    ] { try fm.createDirectory(atPath: app + "/" + dir, withIntermediateDirectories: true) }
    for file in [
        "Test", "Frameworks/A.framework/A", "Frameworks/A.framework/Libs/libdeep.dylib", "Frameworks/libtop.dylib",
        "Frameworks/B.framework/B", "Frameworks/B.framework/Frameworks/Inner.framework/Inner", "Assets/data.bin",
        "Assets/notcode.dylib.txt",
    ] { try Data("x".utf8).write(to: URL(fileURLWithPath: app + "/" + file)) }
    return (root, app)
}

@Suite("BundleSigner order")
struct BundleSignerOrderTests {
    private let sha1 = String(repeating: "AB", count: 20)

    @Test("nested code is found anywhere, deepest first, ties by path; resources that only look like code are not")
    func nested() throws {
        let (root, app) = try nestedTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let found = BundleSigner.nestedCode(in: app).map { String($0.dropFirst(app.count + 1)) }
        #expect(found == [
            "Frameworks/A.framework/Libs/libdeep.dylib", "Frameworks/B.framework/Frameworks/Inner.framework",
            "Frameworks/A.framework", "Frameworks/B.framework", "Frameworks/libtop.dylib",
        ])
        // Every item comes after everything inside it.
        for (i, item) in found.enumerated() {
            #expect(found.suffix(from: i + 1).allSatisfy { !$0.hasPrefix(item + "/") }, "\(item) is signed after something inside it")
        }
    }

    @Test("the argv: -f -s <sha1> --timestamp=none for each nested item, then the app with entitlements and DER, then --verify")
    func argv() async throws {
        let (root, app) = try nestedTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = FakeRunner()
        try await BundleSigner(runner: runner, identity: sha1).sign(app: app, entitlements: root + "/ent.plist")
        let nested = BundleSigner.nestedCode(in: app)
        #expect(nested.count == 5)
        var expected: [[String]] = nested.map { ["-f", "-s", sha1, "--timestamp=none", $0] }
        expected.append([
            "-f", "-s", sha1, "--timestamp=none", "--entitlements", root + "/ent.plist", "--generate-entitlement-der", app,
        ])
        expected.append(["--verify", "--strict", "--deep", app])
        #expect(runner.calls.map(\.args) == expected)
        #expect(runner.calls.allSatisfy { $0.executable == "/usr/bin/codesign" })
        // The identity is the SHA-1, never a name; a timeout bounds every call, the verify shorter than the signing.
        #expect(runner.calls.dropLast().allSatisfy { $0.timeout == .seconds(300) } && runner.calls.last?.timeout == .seconds(120))
    }

    @Test("an app with no nested code is signed once, then verified")
    func plain() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Test.app", withIntermediateDirectories: true)
        let runner = FakeRunner()
        try await BundleSigner(runner: runner, identity: sha1).sign(app: root + "/Test.app", entitlements: root + "/e.plist")
        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].args.contains("--entitlements") && runner.calls[1].args.first == "--verify")
    }

    @Test("the first failing call stops the run; later calls are never made")
    func stops() async throws {
        let (root, app) = try nestedTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = FakeRunner(results: [RunResult(), RunResult(code: 1, stderr: "secret stderr text"), RunResult()])
        do {
            try await BundleSigner(runner: runner, identity: sha1).sign(app: app, entitlements: root + "/e.plist")
            Issue.record("expected a failure")
        } catch let error as SideloadError {
            #expect(error.code == "CODESIGN_FAILED" && error.data["step"] == "nested")
            #expect(!error.message.contains("secret"))
        }
        #expect(runner.calls.count == 2)
    }

    @Test("each failure shape maps to its code, and the tool's text never reaches the message")
    func failures() {
        func map(_ r: RunResult, _ step: String = "app") -> SideloadError? { BundleSigner.failure(r, step: step, label: "signing the app") }
        #expect(map(RunResult()) == nil)
        #expect(map(RunResult(code: 1))?.code == "CODESIGN_FAILED")
        #expect(map(RunResult(code: nil))?.code == "CODESIGN_FAILED")
        #expect(map(RunResult(code: nil, timedOut: true))?.code == "CODESIGN_FAILED")
        #expect(map(RunResult(code: nil, overflow: true))?.code == "CODESIGN_FAILED")
        #expect(map(RunResult(code: nil, spawnError: "ENOENT"))?.code == "TOOL_FAILED")
        #expect(map(RunResult(code: nil, spawnError: "INTERRUPTED"))?.code == "CANCELLED")
        #expect(map(RunResult(code: 1, stderr: "x errSecInternalComponent"))?.code == "KEYCHAIN_LOCKED")
        #expect(map(RunResult(code: 1, stderr: "User interaction is not allowed."))?.code == "KEYCHAIN_LOCKED")
        #expect(map(RunResult(code: 1, stderr: "error: no identity found"))?.code == "FREE_IDENTITY_MISSING")
        #expect(map(RunResult(code: 1, stderr: "Apple Development: Someone (ABC)"))?.message.contains("Someone") == false)
        #expect(map(RunResult(code: 3), "verify")?.data["step"] == "verify")
    }
}

@Suite("BundleSigner refuses nested code it does not sign")
struct BundleSignerUnsupportedTests {
    private let sha1 = String(repeating: "AB", count: 20)
    private let machO = Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0])

    private func app(_ build: (String) throws -> Void) throws -> (root: String, app: String) {
        let root = try tempDir()
        let app = root + "/Test.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        try infoPlist(["CFBundleExecutable": "Test", "CFBundleIdentifier": "io.example.test"]).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        try machO.write(to: URL(fileURLWithPath: app + "/Test"))
        try build(app)
        return (root, app)
    }

    private func bundle(_ path: String, executable: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "io.example.nested"]
        if let executable {
            plist["CFBundleExecutable"] = executable
            try machO.write(to: URL(fileURLWithPath: path + "/" + executable))
        }
        try infoPlist(plist).write(to: URL(fileURLWithPath: path + "/Info.plist"))
    }

    @Test("a nested .app, an .xpc, a .bundle with an executable and a loose Mach-O are refused by relative path; nothing is run")
    func refused() async throws {
        let (root, app) = try app { app in
            try bundle(app + "/Frameworks/Tool.app")
            try bundle(app + "/XPCServices/Helper.xpc")
            try bundle(app + "/Resources/Code.bundle", executable: "Code")
            try bundle(app + "/Frameworks/F.framework/Services/Inner.xpc")
            try machO.write(to: URL(fileURLWithPath: app + "/helper-tool"))
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BundleSigner.unsupportedNestedCode(in: app) == [
            "Frameworks/F.framework/Services/Inner.xpc", "Frameworks/Tool.app", "Resources/Code.bundle", "XPCServices/Helper.xpc",
            "helper-tool",
        ])
        let runner = FakeRunner()
        do {
            try await BundleSigner(runner: runner, identity: sha1).sign(app: app, entitlements: root + "/e.plist")
            Issue.record("expected a refusal")
        } catch let error as SideloadError {
            #expect(error.code == "NESTED_CODE_UNSUPPORTED")
            #expect(error.message.contains("Frameworks/F.framework/Services/Inner.xpc") && error.message.contains("4 more"))
            #expect(error.data["nestedCode"]?.array?.count == 5)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("a Mach-O in a framework other than its CFBundleExecutable is refused by relative path; the framework's own binary passes")
    func frameworkHelper() async throws {
        let (root, app) = try app { app in
            try bundle(app + "/Frameworks/Core.framework", executable: "Core")
            try machO.write(to: URL(fileURLWithPath: app + "/Frameworks/Core.framework/helper-tool"))
            try bundle(app + "/Frameworks/Plain.framework", executable: "Plain")
            // No readable Info.plist: nothing in it is the framework's binary.
            try FileManager.default.createDirectory(atPath: app + "/Frameworks/Odd.framework", withIntermediateDirectories: true)
            try machO.write(to: URL(fileURLWithPath: app + "/Frameworks/Odd.framework/Odd"))
            // A nested framework answers to its own Info.plist, not the outer one's.
            try bundle(app + "/Frameworks/Outer.framework", executable: "Outer")
            try bundle(app + "/Frameworks/Outer.framework/Frameworks/Inner.framework", executable: "Inner")
            try machO.write(to: URL(fileURLWithPath: app + "/Frameworks/Outer.framework/Frameworks/Inner.framework/Outer"))
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BundleSigner.unsupportedNestedCode(in: app) == [
            "Frameworks/Core.framework/helper-tool", "Frameworks/Odd.framework/Odd",
            "Frameworks/Outer.framework/Frameworks/Inner.framework/Outer",
        ])
        let runner = FakeRunner()
        do {
            try await BundleSigner(runner: runner, identity: sha1).sign(app: app, entitlements: root + "/e.plist")
            Issue.record("expected a refusal")
        } catch let error as SideloadError {
            #expect(error.code == "NESTED_CODE_UNSUPPORTED" && error.message.contains("Frameworks/Core.framework/helper-tool"))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("universal and byte-swapped Mach-O magic are found; text and short files are not")
    func magic() throws {
        let (root, app) = try app { app in
            for (name, bytes) in [
                ("fat", [0xca, 0xfe, 0xba, 0xbe]), ("fatswapped", [0xbe, 0xba, 0xfe, 0xca]), ("thin32", [0xce, 0xfa, 0xed, 0xfe]),
                ("text", Array("#!/bin/sh".utf8)), ("short", [0xcf, 0xfa]),
            ] as [(String, [UInt8])] { try Data(bytes).write(to: URL(fileURLWithPath: app + "/" + name)) }
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BundleSigner.unsupportedNestedCode(in: app) == ["fat", "fatswapped", "thin32"])
    }

    @Test("what sign does handle passes: frameworks (and the Mach-O inside them), dylibs, resource bundles, data, the main executable")
    func allowed() async throws {
        let (root, app) = try app { app in
            try bundle(app + "/Frameworks/Core.framework", executable: "Core")
            try machO.write(to: URL(fileURLWithPath: app + "/Frameworks/Core.framework/libinside.dylib"))
            try Data("not code".utf8).write(to: URL(fileURLWithPath: app + "/Frameworks/Core.framework/notes.txt"))
            try machO.write(to: URL(fileURLWithPath: app + "/Frameworks/libhelper.dylib"))
            try bundle(app + "/Resources/Assets.bundle")
            try Data("data".utf8).write(to: URL(fileURLWithPath: app + "/Resources/blob.bin"))
        }
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BundleSigner.unsupportedNestedCode(in: app).isEmpty)
        let runner = FakeRunner()
        try await BundleSigner(runner: runner, identity: sha1).sign(app: app, entitlements: root + "/e.plist")
        #expect(runner.calls.count == 5)
    }
}

@Suite("BundleSigner with the real codesign (ad hoc)")
struct BundleSignerRealTests {
    private func bundles() -> [BundleSpec] {
        var app = BundleSpec.app("Test", bundleId: "io.example.test", sign: false)
        app.extraFiles["Frameworks/libextra.dylib"] = Data()
        return [
            app,
            BundleSpec(
                directory: "Payload/Test.app/Frameworks/Lib.framework",
                plist: ["CFBundleIdentifier": "io.example.lib", "CFBundleExecutable": "Lib", "CFBundleName": "Lib"],
                executableName: "Lib", sign: false),
        ]
    }

    @Test("a synthetic app with a framework and a dylib is signed, carries exactly the entitlements given, and verifies --strict --deep")
    func signs() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var specs = bundles()
        // A real Mach-O for the dylib.
        specs[0].extraFiles["Frameworks/libextra.dylib"] = try Data(
            contentsOf: URL(fileURLWithPath: try await MachOTemplates.shared.path(platform: "ios", minOS: "15.0")))
        try await layOut(specs, at: dir)
        let app = dir + "/Payload/Test.app"
        let entitlements = dir + "/ent.plist"
        try infoPlist(["get-task-allow": true, "keychain-access-groups": ["TEAM.io.example.test"]]).write(to: URL(fileURLWithPath: entitlements))

        let runner = RecordingRunner()
        // Ad hoc stands in for the identity: the argv is the same shape.
        try await BundleSigner(runner: runner, identity: "-").sign(app: app, entitlements: entitlements)

        let calls = runner.calls.map(\.args)
        #expect(calls.count == 4, "framework, dylib, app, verify")
        #expect(calls[0].last?.hasSuffix("Lib.framework") == true && calls[1].last?.hasSuffix("libextra.dylib") == true)
        #expect(calls[2].contains("--generate-entitlement-der") && calls[3] == ["--verify", "--strict", "--deep", app])
        let ent = try await signedEntitlements(app)
        #expect(Set(ent.keys) == ["get-task-allow", "keychain-access-groups"])
        #expect(ent["get-task-allow"] as? Bool == true)
        // A direct check, apart from the one the signer ran.
        await tool("/usr/bin/codesign", ["--verify", "--strict", "--deep", app])
        // Tampering with sealed content breaks it, which is what the verify step is for.
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        let verify = await PosixSpawnRunner().run(
            CommandSpec(executable: "/usr/bin/codesign", args: ["--verify", "--strict", "--deep", app], timeout: .seconds(30)))
        #expect(verify.code != 0)
    }

    @Test("a failing verify step is CODESIGN_FAILED with step verify")
    func verifyFails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await layOut([BundleSpec.app("Test", bundleId: "io.example.test", sign: false)], at: dir)
        let app = dir + "/Payload/Test.app"
        try infoPlist([:]).write(to: URL(fileURLWithPath: dir + "/e.plist"))
        // The real runner for everything but the verification, which fails.
        let runner = RecordingRunner(PosixSpawnRunner())
        let faulty = FailVerify(inner: runner)
        do {
            try await BundleSigner(runner: faulty, identity: "-").sign(app: app, entitlements: dir + "/e.plist")
            Issue.record("expected a failure")
        } catch let error as SideloadError {
            #expect(error.code == "CODESIGN_FAILED" && error.data["step"] == "verify")
        }
    }
}

private struct FailVerify: Runner {
    let inner: any Runner

    func run(_ spec: CommandSpec) async -> RunResult {
        spec.args.first == "--verify" ? RunResult(code: 1, stderr: "a signature problem") : await inner.run(spec)
    }
}
