import Foundation
import Testing

@testable import SideloadCore

// The DeviceCtl allowlist for app data: exactly three argument shapes (`device info files`, `device copy from`,
// `device copy to`), the free scope, the scoped app's own data container, relative device paths and local paths under
// `$SIDELOAD_HOME/backups/` only. Nothing else that names `copy` or `files` reaches a subprocess.

private let appId = stremioId

private func domain(_ type: String = "appDataContainer", _ id: String = appId) -> [String] {
    ["--domain-type", type, "--domain-identifier", id]
}

@Suite("app-data devicectl allowlist")
struct AppDataAllowlistTests {
    private func world(_ body: (Paths, DeviceCtl, FakeRunner) async throws -> Void) async throws {
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: carrierPrefix)) { paths, store in
            let runner = FakeRunner()
            try await body(paths, DeviceCtl(runner: runner, store: store), runner)
        }
    }

    private func refused(
        _ ctl: DeviceCtl, _ args: [String], positional: [String] = [], scope: DeviceCtl.Scope = .free(bundleId: appId),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await ctl.run(args, deviceAlias: "iphone", positional: positional, scope: scope)
            Issue.record("\(args) \(positional) was allowed", sourceLocation: sourceLocation)
        } catch {
            #expect(errorCode(of: error) == "BUNDLE_ID_NOT_ALLOWED", "\(args) \(positional): \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("the three shapes pass, once each, with the device, timeout and output flags added by the wrapper")
    func shapesPass() async throws {
        try await world { paths, ctl, runner in
            let local = paths.backups + "/iphone/stremio-ios/x.partial/data/Documents/a.json"
            let list = ["device", "info", "files"] + domain() + ["--recurse"]
            let from = ["device", "copy", "from"] + domain() + ["--source", "Documents/a.json", "--destination", local]
            let to = ["device", "copy", "to"] + domain() + ["--source", local, "--destination", "Documents/a.json"]
            for args in [list, from, to] {
                _ = try await ctl.run(args, deviceAlias: "iphone", timeoutSec: 20, scope: .free(bundleId: appId))
            }
            #expect(runner.calls.count == 3)
            for (spec, args) in zip(runner.calls, [list, from, to]) {
                #expect(spec.args.first == "devicectl")
                var bare: [String] = []
                var i = 1
                while i < spec.args.count {
                    if ["--device", "--timeout", "--json-output"].contains(spec.args[i]) {
                        i += 2
                    } else {
                        bare.append(spec.args[i])
                        i += 1
                    }
                }
                #expect(bare == args, "the argv is the shape, nothing more")
                #expect(spec.args.contains("--device") && spec.args.contains("--timeout") && spec.args.contains("--json-output"))
            }
        }
    }

    @Test("the flags may come in any order")
    func anyOrder() async throws {
        try await world { paths, ctl, runner in
            let local = paths.backups + "/iphone/stremio-ios/x/data/a"
            _ = try await ctl.run(
                ["device", "copy", "from", "--destination", local, "--domain-identifier", appId, "--source", "a", "--domain-type", "appDataContainer"],
                deviceAlias: "iphone", scope: .free(bundleId: appId))
            #expect(runner.calls.count == 1)
        }
    }

    @Test("refusals: another domain, another or paid bundle, extra flags, odd paths, extra tokens; no subprocess")
    func refusals() async throws {
        try await world { paths, ctl, runner in
            let local = paths.backups + "/iphone/stremio-ios/x/data/a"
            let from = ["device", "copy", "from"] + domain() + ["--source", "a", "--destination", local]
            let list = ["device", "info", "files"] + domain() + ["--recurse"]
            let apollo = "io.github.dividedby.free.apollo"
            // Another domain type.
            for type in ["appGroupDataContainer", "temporary", "systemCrashLogs", "appdatacontainer", ""] {
                await refused(ctl, ["device", "info", "files"] + domain(type) + ["--recurse"])
                await refused(ctl, ["device", "copy", "from"] + domain(type) + ["--source", "a", "--destination", local])
            }
            // The identifier is not the scoped app: another free app, a foreign app, the lab's.
            await refused(ctl, ["device", "info", "files"] + domain("appDataContainer", apollo) + ["--recurse"])
            await refused(ctl, ["device", "info", "files"] + domain("appDataContainer", wdaId) + ["--recurse"], scope: .free(bundleId: wdaId))
            await refused(ctl, ["device", "info", "files"] + domain("appDataContainer", "com.apple.mobilesafari") + ["--recurse"])
            // Paid scope (the default) refuses every app-data call, even for a free ID.
            await refused(ctl, list, scope: .paid)
            await refused(ctl, from, scope: .paid)
            // A flag the shapes do not have.
            await refused(ctl, from + ["--user", "mobile"])
            await refused(ctl, list + ["--user", "mobile"])
            await refused(ctl, list + ["--source", "a"])
            await refused(ctl, from + ["--recurse"])
            await refused(ctl, ["device", "info", "files"] + domain())  // no --recurse
            await refused(ctl, Array(list.dropLast()) + ["--verbose"])
            // Repeated or `=` flags, a flag without its value, extra tokens.
            await refused(ctl, from + ["--source", "b"])
            await refused(ctl, from + ["--domain-type", "appDataContainer"])
            await refused(ctl, ["device", "copy", "from"] + domain() + ["--source=a", "--destination", local])
            await refused(ctl, ["device", "info", "files", "--domain-type=appDataContainer", "--domain-identifier", appId, "--recurse"])
            await refused(ctl, ["device", "copy", "from"] + domain() + ["--source", "a", "--destination"])
            await refused(ctl, from + ["extra"])
            await refused(ctl, from, positional: ["extra"])
            await refused(ctl, list, positional: ["files"])
            await refused(ctl, ["device", "copy", "from"] + domain() + ["--destination", local])
            // Another subcommand that names copy or files.
            for words in [["device", "copy", "delete"], ["device", "copy"], ["device", "copy", "to", "from"],
                ["copy", "from"], ["device", "files"], ["device", "info", "files", "files"], ["device", "uninstall", "app", "copy"]]
            {
                await refused(ctl, words + domain() + ["--source", "a", "--destination", local, "--recurse"])
            }
            await refused(ctl, ["device", "process", "launch"], positional: ["files"])
            await refused(ctl, ["Device", "Copy", "From"] + domain() + ["--source", "a", "--destination", local])
            // Device paths: absolute, `..`, `.`, empty, dash-leading, NUL, empty value.
            for bad in ["/etc/passwd", "../x", "a/../b", "a/..", "./a", "a//b", "a/", "-x", "", "a\0b", "/"] {
                await refused(ctl, ["device", "copy", "from"] + domain() + ["--source", bad, "--destination", local])
                await refused(ctl, ["device", "copy", "to"] + domain() + ["--source", local, "--destination", bad])
            }
            // Local paths: outside backups, relative, the folder itself, `..` out of it, a sibling with the same prefix.
            for bad in [
                paths.home + "/config.json", "/tmp/x", "data/a", paths.backups, paths.backups + "/", paths.backups + "/../config.json",
                paths.backups + "/a/../../config.json", paths.backups + "x/a", paths.home + "/secrets/p12", paths.backups + "/a/./b",
                paths.backups + "//a", paths.backups + "/a\0",
            ] {
                await refused(ctl, ["device", "copy", "from"] + domain() + ["--source", "a", "--destination", bad])
                await refused(ctl, ["device", "copy", "to"] + domain() + ["--source", bad, "--destination", "a"])
            }
            #expect(runner.calls.isEmpty, "none of them reached a subprocess")
        }
    }

    @Test("a copy needs a free-team bundle ID in the scope, even when the argv names it")
    func scopeMustBeFree() async throws {
        try await world { _, ctl, runner in
            await refused(ctl, ["device", "info", "files"] + domain("appDataContainer", "com.example.app") + ["--recurse"], scope: .free(bundleId: "com.example.app"))
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("a device path may be named like a subcommand word")
    func pathsNamedLikeWords() async throws {
        try await world { paths, ctl, runner in
            let local = paths.backups + "/iphone/stremio-ios/x/data/install"
            _ = try await ctl.run(
                ["device", "copy", "from"] + domain() + ["--source", "install", "--destination", local], deviceAlias: "iphone",
                scope: .free(bundleId: appId))
            #expect(runner.calls.count == 1)
        }
    }

    @Test("only FreeDevice.swift names these subcommands (DeviceCtl.swift allowlists them); no other source builds these argument vectors")
    func sourcesScan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let word = try NSRegularExpression(pattern: #""info",\s*"files"|"copy",\s*"(from|to)""#)
        let backupFlag = try NSRegularExpression(pattern: #""--domain-type"|"appDataContainer""#)
        var wordFiles: [String] = []
        var flagFiles: [String] = []
        var seen = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            seen += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(location: 0, length: (text as NSString).length)
            if word.numberOfMatches(in: text, range: range) > 0 { wordFiles.append(url.lastPathComponent) }
            if backupFlag.numberOfMatches(in: text, range: range) > 0 { flagFiles.append(url.lastPathComponent) }
        }
        #expect(seen > 20)
        #expect(wordFiles.sorted() == ["DeviceCtl.swift", "FreeDevice.swift"], "\(wordFiles)")
        #expect(flagFiles.sorted() == ["DeviceCtl.swift", "FreeDevice.swift"], "\(flagFiles)")
    }
}
