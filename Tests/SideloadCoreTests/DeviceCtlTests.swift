import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private func jsonOutputPath(_ args: [String]) -> String {
    args[args.firstIndex(of: "--json-output")! + 1]
}

private func value(after flag: String, in args: [String]) -> String? {
    args.firstIndex(of: flag).map { args[$0 + 1] }
}

@Suite("devicectl")
struct DeviceCtlTests {
    @Test("overflowing devicectl output becomes OUTPUT_LIMIT")
    func overflow() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let runner = FakeRunner { _ in RunResult(code: nil, overflow: true) }
            let ctl = DeviceCtl(runner: runner, store: store)
            do {
                _ = try await ctl.run(["list", "devices"])
                Issue.record("expected OUTPUT_LIMIT")
            } catch {
                #expect(errorCode(of: error) == "OUTPUT_LIMIT")
            }
            #expect(listing(paths.tmp).isEmpty, "the output file is removed on the overflow path")
        }
    }

    @Test("resolves the alias to the CoreDevice UUID and adds --timeout and --json-output")
    func resolvesAlias() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            _ = try await ctl.run(["device", "info", "apps"], deviceAlias: "iphone", timeoutSec: 60)
            let spec = try #require(runner.calls.first)
            #expect(spec.executable == "xcrun")
            #expect(spec.args.first == "devicectl")
            #expect(value(after: "--device", in: spec.args) == savedCoreId("1"))
            #expect(value(after: "--timeout", in: spec.args) == "60")
            #expect(jsonOutputPath(spec.args).hasPrefix(paths.tmp + "/devicectl-"))
            #expect(jsonOutputPath(spec.args).hasSuffix(".json"))
            #expect(spec.timeout == .seconds(75))
            #expect(spec.timeout > .seconds(60))
        }
    }

    @Test("falls back to the UDID when no CoreDevice ID is saved")
    func udidFallback() async throws {
        let config = Config(devices: ["phone": SavedDevice(udid: savedUdid("2"), platform: "ios")])
        try await withTestHome(config: config) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            _ = try await ctl.run(["device", "info", "apps"], deviceAlias: "phone")
            let spec = try #require(runner.calls.first)
            #expect(value(after: "--device", in: spec.args) == savedUdid("2"))
            #expect(value(after: "--timeout", in: spec.args) == "30")
            #expect(spec.timeout == .seconds(45))
        }
    }

    @Test("rejects a --device value that is not a saved ID, and never calls the runner")
    func rejectsUnsaved() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            var attempts: [(args: [String], alias: String?)] = []
            for bad in ["Robins-iPhone", "iphone", savedUdid("9"), "", "some.local"] {
                attempts.append((["device", "info", "apps", "--device", bad], nil))
                attempts.append((["device", "info", "apps", "-d", bad], nil))
            }
            attempts.append((["device", "info", "apps", "--device=\(savedUdid("9"))"], nil))
            attempts.append((["device", "info", "apps", "--device"], nil))
            attempts.append((["device", "info", "apps", "--device", savedUdid("1"), "--device", savedUdid("1")], nil))
            attempts.append((["device", "info", "apps"], "nope"))
            for attempt in attempts {
                do {
                    _ = try await ctl.run(attempt.args, deviceAlias: attempt.alias)
                    Issue.record("expected DEVICE_NOT_SAVED for \(attempt.args)")
                } catch {
                    #expect(errorCode(of: error) == "DEVICE_NOT_SAVED")
                }
            }
            #expect(runner.calls.isEmpty)
            #expect(listing(paths.tmp).isEmpty)
        }
    }

    @Test("accepts a literal --device that is a saved ID, and passes it once")
    func acceptsSaved() async throws {
        try await withTestHome(config: iphoneConfig()) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            _ = try await ctl.run(["device", "info", "apps", "--device", savedUdid("1")])
            _ = try await ctl.run(["device", "info", "apps", "-d=\(savedCoreId("1"))"])
            #expect(runner.calls.count == 2)
            for spec in runner.calls {
                #expect(spec.args.filter { $0 == "--device" }.count == 1)
                #expect(!spec.args.contains { $0.hasPrefix("-d") || $0.hasPrefix("--device=") })
            }
            #expect(value(after: "--device", in: runner.calls[0].args) == savedUdid("1"))
        }
    }

    @Test("refuses caller-supplied --timeout/--json-output and dash-leading positionals")
    func refusesOwnedFlags() async throws {
        try await withTestHome(config: iphoneConfig()) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            func message(_ body: () async throws -> Void) async -> String? {
                do {
                    try await body()
                    return nil
                } catch let e as SideloadError {
                    return e.message
                } catch {
                    return nil
                }
            }
            #expect(await message { _ = try await ctl.run(["list", "devices", "--timeout", "1"]) }?.contains("wrapper") == true)
            #expect(await message { _ = try await ctl.run(["list", "devices", "--timeout=1"]) }?.contains("wrapper") == true)
            #expect(await message { _ = try await ctl.run(["list", "devices", "--json-output", "/x"]) }?.contains("wrapper") == true)
            #expect(
                await message { _ = try await ctl.run(["device", "uninstall", "app"], deviceAlias: "iphone", positional: ["--all"]) }?
                    .contains("positional") == true)
            #expect(await message { _ = try await ctl.run(["list"], timeoutSec: 0) }?.contains("timeoutSec") == true)
            #expect(
                await message { _ = try await ctl.run(["x", "--device", savedUdid("1")], deviceAlias: "iphone") }?
                    .contains("not both") == true)
            #expect(runner.calls.isEmpty)
        }
    }

    @Test("positionals are appended after --json-output")
    func positionals() async throws {
        try await withTestHome(config: iphoneConfig()) { _, store in
            let runner = FakeRunner()
            let ctl = DeviceCtl(runner: runner, store: store)
            _ = try await ctl.run(["device", "uninstall", "app"], deviceAlias: "iphone", positional: ["com.example.app"])
            let args = try #require(runner.calls.first).args
            #expect(args.last == "com.example.app")
            #expect(args.firstIndex(of: "--json-output")! < args.count - 1)
        }
    }

    @Test("parses the JSON file and removes it afterwards")
    func parsesAndRemoves() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let seen = Mutex<(path: String, existed: Bool)?>(nil)
            let runner = FakeRunner { spec in
                let file = jsonOutputPath(spec.args)
                seen.withLock { $0 = (file, FileManager.default.fileExists(atPath: file)) }
                try? Data(#"{"info":{"outcome":"success"}}"#.utf8).write(to: URL(fileURLWithPath: file))
                chmod(file, 0o644)  // devicectl's own mode; the wrapper tightens it before reading
                return RunResult(stderr: String(repeating: "e", count: 5000))
            }
            let ctl = DeviceCtl(runner: runner, store: store)
            let res = try await ctl.run(["list", "devices"], timeoutSec: 20)
            #expect(res.json == ["info": ["outcome": "success"]])
            #expect(res.code == 0)
            #expect(res.stderr.count == 4000)
            let s = try #require(seen.withLock { $0 })
            #expect(!s.existed, "the output file is not pre-created")
            #expect(modeOf(paths.tmp) == 0o700)
            #expect(!FileManager.default.fileExists(atPath: s.path))
            #expect(listing(paths.tmp).isEmpty)
        }
    }

    @Test("returns json:nil when devicectl wrote nothing parseable")
    func jsonNil() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let ctl = DeviceCtl(runner: FakeRunner { _ in RunResult(code: 1) }, store: store)
            let res = try await ctl.run(["list", "devices"])
            #expect(res.json == nil)
            #expect(res.code == 1)

            let garbage = FakeRunner { spec in
                try? Data("{not json".utf8).write(to: URL(fileURLWithPath: jsonOutputPath(spec.args)))
                return RunResult(code: 0)
            }
            let res2 = try await DeviceCtl(runner: garbage, store: store).run(["list", "devices"])
            #expect(res2.json == nil)
            #expect(listing(paths.tmp).isEmpty)
        }
    }

    @Test("reports timeouts and spawn errors as results")
    func timeoutsAndSpawn() async throws {
        try await withTestHome(config: iphoneConfig()) { _, store in
            let timedOut = try await DeviceCtl(
                runner: FakeRunner { _ in RunResult(code: nil, timedOut: true) }, store: store
            ).run(["list", "devices"])
            #expect(timedOut.timedOut && timedOut.code == nil)
            let missing = try await DeviceCtl(
                runner: FakeRunner { _ in RunResult(code: nil, spawnError: "ENOENT") }, store: store
            ).run(["list", "devices"])
            #expect(missing.spawnError == "ENOENT")
        }
    }

    @Test("creates tmp/ when it is missing")
    func createsTmp() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            try FileManager.default.removeItem(atPath: paths.tmp)
            _ = try await DeviceCtl(runner: FakeRunner(), store: store).run(["list", "devices"])
            #expect(modeOf(paths.tmp) == 0o700)
        }
    }
}
