import Darwin
import Foundation
import Testing

@testable import SideloadCore

// `ExtensionStripper` over trees made on disk (plain files and Info.plists, no Mach-O): what is removed, what is
// reported, and what the independent re-walk (`remaining`) still finds.

private struct Tree {
    let root: String
    var app: String { root + "/Test.app" }

    init() throws { root = try makeTempDir().path }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: app + "/" + relative, withIntermediateDirectories: true)
    }

    func file(_ relative: String, _ text: String = "x") throws {
        try dir(parentPath("/" + relative).dropFirst().description)
        try Data(text.utf8).write(to: URL(fileURLWithPath: app + "/" + relative))
    }

    /// A bundle with an Info.plist.
    func bundle(_ relative: String, id: String?, point: String? = nil, extra: [String: Any] = [:]) throws {
        try dir(relative)
        var plist = extra
        if let id { plist["CFBundleIdentifier"] = id }
        if let point { plist["NSExtension"] = ["NSExtensionPointIdentifier": point] }
        try infoPlist(plist).write(to: URL(fileURLWithPath: app + "/" + relative + "/Info.plist"))
    }

    var names: [String] { tree(app) }
}

/// `codesign -d --entitlements - --xml <bundle>`: groups for `Widget`, plain entitlements for `Kit`, unsigned otherwise.
private func entitlementRunner() -> FakeRunner {
    FakeRunner { spec in
        guard spec.executable == "/usr/bin/codesign", spec.args.prefix(4) == ["-d", "--entitlements", "-", "--xml"],
            let path = spec.args.last
        else { return RunResult(code: 1) }
        func xml(_ body: String) -> RunResult {
            RunResult(stdout: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>\(body)</dict></plist>")
        }
        if path.hasSuffix("Widget.appex") {
            return xml(
                "<key>aps-environment</key><string>production</string><key>com.apple.security.application-groups</key><array><string>group.one</string><string>group.two</string></array>"
            )
        }
        if path.hasSuffix("Kit.appex") { return xml("<key>get-task-allow</key><false/>") }
        return RunResult(code: 1, stderr: "\(path): code object is not signed at all\n")
    }
}

private func stripper(_ runner: FakeRunner = entitlementRunner(), limits: InspectLimits = InspectLimits()) -> ExtensionStripper {
    ExtensionStripper(runner: runner, limits: limits)
}

@Suite("ExtensionStripper")
struct ExtensionStripperTests {
    @Test("every PlugIns/*.appex goes, then PlugIns/ itself; what each declared is reported")
    func plugins() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("PlugIns/Widget.appex", id: "com.example.widget", point: "com.apple.widgetkit-extension")
        try t.bundle("PlugIns/Kit.appex", id: "com.example.kit", point: "com.apple.share-services")
        try t.file("Info.plist")
        let outcome = try await stripper().strip(app: t.app)
        #expect(outcome.stripped.map(\.path) == ["PlugIns/Kit.appex", "PlugIns/Widget.appex"])
        let widget = try #require(outcome.stripped.last)
        #expect(widget.bundleId == "com.example.widget" && widget.extensionPoint == "com.apple.widgetkit-extension")
        #expect(widget.entitlementKeys == ["aps-environment", "com.apple.security.application-groups"])
        #expect(widget.appGroups == ["group.one", "group.two"])
        let kit = try #require(outcome.stripped.first)
        #expect(kit.entitlementKeys == ["get-task-allow"] && kit.appGroups.isEmpty)
        #expect(outcome.warnings.isEmpty)
        #expect(t.names == ["Info.plist"])
        #expect(ExtensionStripper.remaining(in: t.app).isEmpty)
        #expect(widget.json["bundleId"] == "com.example.widget" && widget.json["appGroups"] == ["group.one", "group.two"])
    }

    @Test("other content in PlugIns/ is kept, with a warning")
    func pluginsKept() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("PlugIns/Widget.appex", id: "com.example.widget")
        try t.file("PlugIns/readme.txt")
        let outcome = try await stripper().strip(app: t.app)
        #expect(t.names == ["PlugIns", "PlugIns/readme.txt"])
        #expect(outcome.warnings.map { $0["code"]?.string } == ["PLUGINS_NOT_EMPTY"])
    }

    @Test("a nested appex, all of Extensions/ and all of Watch/ (with the appex inside it) are removed")
    func nestedExtensionsAndWatch() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("Frameworks/F.framework/PlugIns/Deep.appex", id: "com.example.deep")
        try t.file("Frameworks/F.framework/F")
        try t.bundle("Extensions/Kit.appex", id: "com.example.kit", point: "com.apple.extensionkit-service")
        try t.file("Extensions/notes.txt")
        try t.bundle("Watch/Watch.app", id: "com.example.watch", extra: ["WKWatchKitApp": true])
        try t.bundle("Watch/Watch.app/PlugIns/WatchExt.appex", id: "com.example.watch.ext")
        try t.file("Keep.txt")
        let outcome = try await stripper().strip(app: t.app)
        // Watch/'s own appex goes with it and is not listed on its own.
        #expect(outcome.stripped.map(\.path) == ["Extensions/Kit.appex", "Frameworks/F.framework/PlugIns/Deep.appex", "Watch/Watch.app"])
        #expect(outcome.stripped.last?.bundleId == "com.example.watch")
        #expect(!t.names.contains { $0.hasPrefix("Watch") || $0.hasPrefix("Extensions") })
        #expect(t.names.contains("Frameworks/F.framework/F") && t.names.contains("Keep.txt"))
        #expect(ExtensionStripper.remaining(in: t.app).isEmpty)
    }

    @Test("names are matched without regard to case, as on a case-insensitive volume")
    func caseInsensitive() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("plugins/Thing.APPEX", id: "com.example.thing")
        try t.bundle("WATCH/W.app", id: "com.example.w")
        try t.bundle("extensions/E.Appex", id: "com.example.e")
        let outcome = try await stripper().strip(app: t.app)
        #expect(outcome.stripped.count == 3)
        #expect(t.names.isEmpty)
    }

    @Test("an app with nothing to strip is left alone and nothing is run")
    func nothing() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.file("Info.plist")
        try t.bundle("Frameworks/F.framework", id: "com.example.f")
        let runner = entitlementRunner()
        let outcome = try await stripper(runner).strip(app: t.app)
        #expect(outcome.stripped.isEmpty && outcome.warnings.isEmpty)
        #expect(runner.calls.isEmpty)
        #expect(t.names == ["Frameworks", "Frameworks/F.framework", "Frameworks/F.framework/Info.plist", "Info.plist"])
    }

    @Test("an extension whose Info.plist cannot be read is still removed, with a warning and no bundle ID")
    func unreadable() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.dir("PlugIns/Broken.appex")
        try t.file("PlugIns/Broken.appex/Info.plist", "not a plist")
        let outcome = try await stripper().strip(app: t.app)
        #expect(outcome.stripped.count == 1 && outcome.stripped[0].bundleId == nil && outcome.stripped[0].extensionPoint == nil)
        #expect(outcome.warnings.map { $0["code"]?.string } == ["EXTENSION_UNREADABLE"])
        #expect(t.names.isEmpty)
    }

    @Test("only the first maxExtensions are listed; all are removed")
    func truncated() async throws {
        let t = try Tree()
        defer { t.remove() }
        for n in 1...3 { try t.bundle("PlugIns/E\(n).appex", id: "com.example.e\(n)") }
        var limits = InspectLimits()
        limits.maxExtensions = 2
        let outcome = try await stripper(limits: limits).strip(app: t.app)
        #expect(outcome.stripped.count == 2)
        #expect(outcome.warnings.map { $0["code"]?.string } == ["EXTENSIONS_TRUNCATED"])
        #expect(t.names.isEmpty)
    }

    @Test("a removal that fails leaves the appex for the re-walk to find")
    func removalFails() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("PlugIns/Widget.appex", id: "com.example.widget")
        var s = stripper()
        s.remove = { _ in false }
        _ = try await s.strip(app: t.app)
        #expect(ExtensionStripper.remaining(in: t.app) == ["PlugIns/Widget.appex"])
    }

    @Test("the re-walk finds an appex anywhere, a symlink named *.appex, Extensions/ and Watch/, and a watch app by its plist")
    func remaining() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("A/B/C/Deep.appex", id: "x")
        try t.bundle("Extensions", id: nil)
        try t.bundle("Watch", id: nil)
        try t.bundle("Frameworks/F.framework/Hidden.app", id: "y", extra: ["WKWatchKitApp": true])
        try t.bundle("Frameworks/G.framework/Sibling.app", id: "z", extra: ["WKCompanionAppBundleIdentifier": "w"])
        try t.bundle("Frameworks/H.framework/Ordinary.app", id: "ok")
        try t.bundle("Frameworks/I.framework/Platforms.app", id: "p", extra: ["CFBundleSupportedPlatforms": ["WatchOS"]])
        try FileManager.default.createSymbolicLink(atPath: t.app + "/link.appex", withDestinationPath: "/tmp")
        #expect(ExtensionStripper.remaining(in: t.app) == [
            "A/B/C/Deep.appex", "Extensions", "Frameworks/F.framework/Hidden.app", "Frameworks/G.framework/Sibling.app",
            "Frameworks/I.framework/Platforms.app", "Watch", "link.appex",
        ])
    }

    @Test("a tree nested past the depth limit is reported as remaining rather than skipped")
    func tooDeep() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.dir("a/b/c/d")
        var limits = InspectLimits()
        limits.maxTreeDepth = 2
        #expect(!ExtensionStripper.remaining(in: t.app, limits: limits).isEmpty)
    }

    @Test("an interrupted codesign read is CANCELLED, not a quiet empty list")
    func interrupted() async throws {
        let t = try Tree()
        defer { t.remove() }
        try t.bundle("PlugIns/Widget.appex", id: "com.example.widget")
        let runner = FakeRunner { _ in RunResult(code: nil, spawnError: "INTERRUPTED") }
        await #expect(throws: SideloadError.self) { try await stripper(runner).strip(app: t.app) }
    }
}
