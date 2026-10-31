import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// Canary cases (ported from the former Node suite; the five guard cases are one parameterised test) against a
// scripted fake world: nothing here runs xcodebuild, devicectl or any real tool, and nothing touches the real
// device, the portal or `~/.sideload`. Parity with Node is pinned by `CanaryParityTests`.

private func code(_ out: Envelope) -> String? { out.errors.first?.code }

private func warningCodes(_ out: Envelope) -> [String] {
    out.data["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
}

private func strings(_ value: JSONValue?) -> [String]? { value?.array?.compactMap(\.string) }

private let yes = CanaryOptions(device: "iphone", yes: true)
private let keep = CanaryOptions(device: "iphone", yes: true, keep: true)

@Suite("canary: confirmation and config")
struct CanaryConfirmationTests {
    @Test("requires --device")
    func requiresDevice() async throws {
        try await withCanaryWorld { w in
            let out = await w.run(CanaryOptions(yes: true))
            #expect(code(out) == "USAGE")
            #expect(w.calls.isEmpty)
        }
    }

    @Test("missing bundleIdPrefix -> CONFIG_MISSING with a fix, nothing run")
    func missingPrefix() async throws {
        try await withCanaryWorld(config: iphoneConfig()) { w in
            let out = await w.run()
            #expect(!out.ok)
            #expect(code(out) == "CONFIG_MISSING")
            #expect(out.errors[0].fix?.contains("bundleIdPrefix") == true)
            #expect(w.calls.isEmpty)
        }
    }

    @Test("an invalid bundleIdPrefix is CONFIG_MISSING too", arguments: ["", "1com.example", "com..example", "com.example.", "com example", "com.exämple"])
    func invalidPrefix(prefix: String) async throws {
        try await withCanaryWorld(config: iphoneConfig(bundleIdPrefix: prefix)) { w in
            #expect(code(await w.run()) == "CONFIG_MISSING")
            #expect(w.calls.isEmpty)
        }
    }

    @Test("missing --yes -> CONFIRM_REQUIRED explaining portal side effects, nothing run")
    func missingYes() async throws {
        try await withCanaryWorld { w in
            let out = await w.run(CanaryOptions(device: "iphone", yes: false))
            #expect(!out.ok)
            #expect(code(out) == "CONFIRM_REQUIRED")
            let message = out.errors[0].message
            #expect(message.contains("App ID") && message.contains("development profile") && message.contains("register"))
            #expect(out.data["bundleId"] == .string(canaryBundle))
            #expect(w.calls.isEmpty)
        }
    }

    @Test("unknown alias -> DEVICE_NOT_SAVED")
    func unknownAlias() async throws {
        try await withCanaryWorld { w in
            // Node rejected with the error; the Swift command returns it as the failure envelope.
            let out = await w.run(CanaryOptions(device: "ipad", yes: true))
            #expect(code(out) == "DEVICE_NOT_SAVED")
            #expect(w.calls.isEmpty)
        }
    }

    @Test("a saved device without a UDID -> DEVICE_NOT_SAVED, nothing run")
    func noUdid() async throws {
        let config = canaryConfig { $0.devices["iphone"]?.udid = nil }
        try await withCanaryWorld(config: config) { w in
            #expect(code(await w.run()) == "DEVICE_NOT_SAVED")
            #expect(w.calls.isEmpty)
        }
    }
}

@Suite("canary: flow")
struct CanaryFlowTests {
    @Test("blocked path: classifies 0xe8008018, never uninstalls, logs and scrubs")
    func blocked() async throws {
        try await withCanaryWorld(CanaryScenario(install: try .failure("install-blocked-8018-hex.json"))) { w in
            let out = await w.run()
            #expect(out.ok)
            #expect(out.exitCode == 0)
            #expect(out.data["status"] == "blocked")
            #expect(out.data["code"] == "0xe8008018")
            #expect(out.data["guard"] == "passed")
            #expect(w.installs.count == 1)
            #expect(w.uninstalls.isEmpty)
            #expect(out.data["deviceDelta"] == [])

            let lines = try w.jsonlLines
            #expect(lines.count == 1)
            #expect(lines[0]["status"] == "blocked")
            #expect(lines[0]["xcodeVersion"] == "27.0 (27A266a)")
            #expect(lines[0]["device"] == .string("…" + savedUdid("1").suffix(4)))
            let raw = try String(contentsOfFile: w.paths.canaryLog, encoding: .utf8)
            #expect(!raw.contains(savedUdid("1")))

            let files = w.savedInstalls
            #expect(files.count == 1)
            let saved = try w.savedInstall(files[0])
            #expect(saved.contains("0xe8008018"))
            #expect(modeOf(w.paths.logs + "/" + files[0]) == 0o600)
        }
    }

    @Test("saves the scrubbed devicectl JSON only for the first non-success, with IDs redacted")
    func savesOnce() async throws {
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(["error", "userInfo", "device"], to: .string("\(savedUdid("1")) \(savedCoreId("1"))"))
            .setting(["info", "environment"], to: ["HOME": "/Users/someone"])
        try await withCanaryWorld(CanaryScenario(install: InstallScript(code: 1, payload: payload))) { w in
            _ = await w.run()
            _ = await w.run()
            let files = w.savedInstalls
            #expect(files.count == 1)
            let saved = try w.savedInstall(files[0])
            #expect(!saved.contains(savedUdid("1")) && !saved.contains(savedCoreId("1")))
            #expect(!saved.contains("someone"))
            let raw = try String(contentsOfFile: w.paths.canaryLog, encoding: .utf8)
            #expect(raw.split(separator: "\n").count == 2)
        }
    }

    @Test("working path: installs then uninstalls, delta empty, app list restored")
    func working() async throws {
        try await withCanaryWorld { w in
            let out = await w.run()
            #expect(out.ok)
            #expect(out.data["status"] == "working")
            #expect(out.data["bundleId"] == .string(canaryBundle))
            let order = w.calls.compactMap { c -> String? in
                if CanaryWorld.isDevicectl(c, "device", "install", "app") { return "install" }
                if CanaryWorld.isDevicectl(c, "device", "uninstall", "app") { return "uninstall" }
                return nil
            }
            #expect(order == ["install", "uninstall"])
            #expect(w.uninstalls[0].args.last == canaryBundle)
            #expect(out.data["deviceDelta"] == [])
            #expect(out.data["warnings"] == [])
            #expect(!w.installed)
            #expect(w.savedInstalls.isEmpty)
        }
    }

    @Test("--keep skips the uninstall and tolerates exactly the canary in the delta")
    func keepFlag() async throws {
        try await withCanaryWorld { w in
            let out = await w.run(keep)
            #expect(out.data["status"] == "working")
            #expect(w.uninstalls.isEmpty)
            #expect(out.data["deviceDelta"] == [.string(canaryBundle)])
            #expect(out.data["warnings"] == [])
        }
    }

    @Test("failed uninstall adds CANARY_LEFT_ON_DEVICE and a delta warning")
    func failedUninstall() async throws {
        try await withCanaryWorld(CanaryScenario(uninstallFails: true)) { w in
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(warningCodes(out) == ["CANARY_LEFT_ON_DEVICE", "unexpected-app-delta"])
        }
    }

    @Test("an unexpected app in the after-snapshot only warns")
    func unexpectedApp() async throws {
        try await withCanaryWorld(CanaryScenario(extraAfter: true)) { w in
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(out.data["deviceDelta"] == ["com.unexpected.app"])
            #expect(warningCodes(out).contains("unexpected-app-delta"))
            #expect(w.uninstalls.count == 1, "only the canary itself")
        }
    }

    @Test("builds with the pinned team, provisioning updates, a 10 minute timeout and the configured bundle id")
    func buildArguments() async throws {
        try await withCanaryWorld { w in
            _ = await w.run()
            let b = try #require(w.builds.first)
            #expect(w.builds.count == 1)
            #expect(b.executable == "xcodebuild")
            #expect(b.args == [
                "-project", canaryProject, "-scheme", "Canary", "-configuration", "Debug",
                "-destination", "id=\(savedUdid("1"))", "-derivedDataPath", w.paths.builds + "/canary",
                "-allowProvisioningUpdates", "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=7AGMPUPP64",
                "CODE_SIGN_IDENTITY=Apple Development", "PRODUCT_BUNDLE_IDENTIFIER=\(canaryBundle)", "build",
            ])
            #expect(b.timeout == .seconds(600))
            #expect(b.maxOutputBytes == 128 * 1024 * 1024)
        }
    }

    @Test("the default project is the repo's canary/Canary.xcodeproj")
    func defaultProject() {
        #expect(CanaryCommand.defaultProject.hasSuffix("/canary/Canary.xcodeproj"))
        #expect(FileManager.default.fileExists(atPath: CanaryCommand.defaultProject))
    }

    @Test("unknown install failure -> error with the raw code, no uninstall")
    func unknownFailure() async throws {
        try await withCanaryWorld(CanaryScenario(install: try .failure("install-unknown.json"))) { w in
            let out = await w.run()
            #expect(!out.ok)
            #expect(out.data["status"] == "error")
            #expect(code(out) == "1234567")
            #expect(w.uninstalls.isEmpty)
        }
    }

    @Test("locked device -> error, not blocked")
    func locked() async throws {
        try await withCanaryWorld(CanaryScenario(install: try .failure("install-locked.json"))) { w in
            let out = await w.run()
            #expect(out.data["status"] == "error")
            #expect(out.data["code"] == "DEVICE_LOCKED")
            #expect(out.errors[0].fix == "Unlock the device and retry.")
        }
    }

    @Test("progress lines go through the injected log, in order")
    func progress() async throws {
        try await withCanaryWorld { w in
            _ = await w.run()
            #expect(w.logged == [
                "canary: preflight", "canary: snapshot before", "canary: building (up to 10 minutes)",
                "canary: pre-install guard", "canary: installing", "canary: uninstalling",
            ])
        }
    }
}

@Suite("canary: scrubbing and ambiguous installs")
struct CanaryAmbiguousTests {
    @Test("scrubbed install JSON replaces device names and hostnames with <device>")
    func scrubbed() async throws {
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(
                ["error", "userInfo", "NSLocalizedDescription", "string"],
                to: "Failed to install on Test iPhone (owner-phone.coredevice.local) 0xe8008018")
            .setting(["error", "userInfo", "deviceName"], to: "Test iPhone")
            .setting(["error", "userInfo", "Test iPhone"], to: "as a key")
        let scenario = CanaryScenario(
            install: InstallScript(code: 1, payload: payload), hostnames: ["owner-phone.coredevice.local"])
        try await withCanaryWorld(scenario) { w in
            _ = await w.run()
            let saved = try w.savedInstall(try #require(w.savedInstalls.first))
            #expect(!saved.contains("Test iPhone"))
            #expect(!saved.contains("owner-phone"))
            #expect(saved.contains("<device>"))
            #expect(saved.contains("0xe8008018"))
        }
    }

    @Test("a timed-out install that still landed is uninstalled (exact id only) with a warning")
    func timedOutLanded() async throws {
        try await withCanaryWorld(CanaryScenario(install: .timeout)) { w in
            let out = await w.run()
            #expect(out.data["status"] == "error")
            #expect(code(out) == "TIMEOUT")
            #expect(w.uninstalls.count == 1)
            #expect(w.uninstalls[0].args.last == canaryBundle)
            #expect(warningCodes(out).contains("CANARY_REMOVED_AFTER_AMBIGUOUS_INSTALL"))
            #expect(out.data["deviceDelta"] == [])
            #expect(!w.installed)
        }
    }

    @Test("--keep leaves an ambiguous canary alone")
    func keepAmbiguous() async throws {
        try await withCanaryWorld(CanaryScenario(install: .timeout)) { w in
            let out = await w.run(keep)
            #expect(w.uninstalls.isEmpty)
            #expect(out.data["deviceDelta"] == [.string(canaryBundle)])
        }
    }

    @Test("does not uninstall a canary id that was already on the device before the run")
    func preexistingAmbiguous() async throws {
        try await withCanaryWorld(CanaryScenario(install: .timeout, others: ["com.apple.mobilesafari", canaryBundle])) { w in
            _ = await w.run()
            #expect(w.uninstalls.isEmpty)
        }
    }

    @Test("does not uninstall after a working install when the canary was already on the device")
    func preexistingWorking() async throws {
        try await withCanaryWorld(CanaryScenario(others: ["com.apple.mobilesafari", canaryBundle])) { w in
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(w.uninstalls.isEmpty)
        }
    }

    @Test("reports CANARY_LEFT_ON_DEVICE when the cleanup uninstall fails")
    func cleanupFails() async throws {
        try await withCanaryWorld(CanaryScenario(install: .timeout, uninstallFails: true)) { w in
            let out = await w.run()
            #expect(warningCodes(out).contains("CANARY_LEFT_ON_DEVICE"))
        }
    }
}

@Suite("canary: scrub fallback and output limits")
struct CanaryLimitTests {
    @Test("falls back to names saved in config when devicectl list fails, incl. short names as whole words")
    func scrubFallback() async throws {
        let config = canaryConfig {
            $0.devices["iphone"]?.name = "Owner Phone"
            $0.devices["iphone"]?.hostnames = ["owner-phone.local"]
            $0.devices["other"] = SavedDevice(udid: savedUdid("2"), platform: "ios", name: "Ab")
        }
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(
                ["error", "userInfo", "NSLocalizedDescription", "string"],
                to: "Failed on Owner Phone at owner-phone.local for Ab; Table stays, 0xe8008018")
        let scenario = CanaryScenario(install: InstallScript(code: 1, payload: payload), listFailsAfter: 1)
        try await withCanaryWorld(scenario, config: config) { w in
            _ = await w.run()
            let saved = try w.savedInstall(try #require(w.savedInstalls.first))
            #expect(!saved.contains("Owner Phone") && !saved.contains("owner-phone"))
            #expect(saved.firstMatch(of: /\bAb\b/) == nil)
            #expect(saved.contains("Table stays"))
        }
    }

    @Test("names from a devicectl listing that exited non-zero are scrubbed too, as in Node")
    func scrubFromFailingListing() async throws {
        let payload = try installFixture("install-blocked-8018-hex.json")
            .setting(
                ["error", "userInfo", "NSLocalizedDescription", "string"],
                to: "Failed on Test iPhone via owner-phone.coredevice.local 0xe8008018")
        let scenario = CanaryScenario(
            install: InstallScript(code: 1, payload: payload), hostnames: ["owner-phone.coredevice.local"],
            listFailsAfter: 1, failingListWritesJSON: true)
        try await withCanaryWorld(scenario) { w in
            _ = await w.run()
            let saved = try w.savedInstall(try #require(w.savedInstalls.first))
            #expect(!saved.contains("Test iPhone") && !saved.contains("owner-phone"))
            #expect(saved.contains("0xe8008018"))
        }
    }

    @Test("a build that floods output is reported as OUTPUT_LIMIT and never installs")
    func buildFlood() async throws {
        try await withCanaryWorld(CanaryScenario(buildOverflow: true)) { w in
            let out = await w.run()
            #expect(code(out) == "OUTPUT_LIMIT")
            #expect(w.installs.isEmpty)
        }
    }

    @Test("install overflow is ambiguous: error OUTPUT_LIMIT, cleanup runs, logged, no throw")
    func installOverflow() async throws {
        try await withCanaryWorld(CanaryScenario(installOverflow: true)) { w in
            let out = await w.run()
            #expect(!out.ok)
            #expect(out.data["status"] == "error")
            #expect(code(out) == "OUTPUT_LIMIT")
            #expect(w.uninstalls.count == 1)
            #expect(w.uninstalls[0].args.last == canaryBundle)
            #expect(warningCodes(out).contains("CANARY_REMOVED_AFTER_AMBIGUOUS_INSTALL"))
            #expect(out.data["deviceDelta"] == [])
            let lines = try w.jsonlLines
            #expect(lines.last?["code"] == "OUTPUT_LIMIT")
        }
    }

    @Test("uninstall overflow after a good install is a failed uninstall: CANARY_LEFT_ON_DEVICE, still logged")
    func uninstallOverflow() async throws {
        try await withCanaryWorld(CanaryScenario(uninstallOverflow: true)) { w in
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(warningCodes(out).contains("CANARY_LEFT_ON_DEVICE"))
            #expect(w.uninstalls.count == 1)
            let lines = try w.jsonlLines
            #expect(lines.count == 1)
        }
    }

    @Test("cleanup uninstall overflow after an ambiguous install warns CANARY_LEFT_ON_DEVICE")
    func cleanupOverflow() async throws {
        try await withCanaryWorld(CanaryScenario(installOverflow: true, uninstallOverflow: true)) { w in
            let out = await w.run()
            #expect(code(out) == "OUTPUT_LIMIT")
            #expect(warningCodes(out).contains("CANARY_LEFT_ON_DEVICE"))
        }
    }

    @Test("snapshot overflow after install only warns")
    func snapshotOverflow() async throws {
        try await withCanaryWorld(CanaryScenario(snapshotOverflowOn: 2)) { w in
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(warningCodes(out).contains("SNAPSHOT_FAILED"))
            #expect(out.data["deviceDelta"] == .null)
        }
    }
}

struct GuardCase: CustomTestStringConvertible, Sendable {
    let code: String
    let name: String
    let scenario: CanaryScenario

    var testDescription: String { name }
}

private let guardCases: [GuardCase] = [
    GuardCase(code: "WRONG_TEAM", name: "app signed by another team", scenario: CanaryScenario(signedTeam: "ZZZZZZZZZZ")),
    GuardCase(code: "FREE_TEAM_SELECTED", name: "app signed by the free team", scenario: CanaryScenario(signedTeam: "6ZU5Z6ZKK7")),
    GuardCase(code: "WRONG_TEAM", name: "profile of another team", scenario: CanaryScenario(profileTeam: "ZZZZZZZZZZ")),
    GuardCase(code: "FREE_TEAM_SELECTED", name: "profile of the free team", scenario: CanaryScenario(profileTeam: "6ZU5Z6ZKK7")),
    GuardCase(code: "DEVICE_NOT_IN_PROFILE", name: "device missing from the profile", scenario: CanaryScenario(profileDevices: [savedUdid("9")])),
]

@Suite("canary: guards")
struct CanaryGuardFlowTests {
    @Test("a failed guard never reaches devicectl install", arguments: guardCases)
    func guardFailures(c: GuardCase) async throws {
        try await withCanaryWorld(c.scenario) { w in
            let out = await w.run()
            #expect(!out.ok)
            #expect(out.data["status"] == "error")
            #expect(code(out) == c.code)
            #expect(w.installs.isEmpty)
            #expect(w.uninstalls.isEmpty)
            #expect(out.data["guard"]?.string?.hasPrefix("failed:") == true)
            #expect(out.data["guard"] == .string("failed:" + c.code))
            // Only the preflight device listing and the before-snapshot touched the device.
            let devicectl = w.calls.filter { $0.executable == "xcrun" }
            #expect(devicectl.count == 2)
            #expect(CanaryWorld.isDevicectl(devicectl[0], "list", "devices"))
            #expect(CanaryWorld.isDevicectl(devicectl[1], "device", "info", "apps"))
        }
    }

    @Test("profile device matching is case-insensitive")
    func caseInsensitive() async throws {
        try await withCanaryWorld(CanaryScenario(profileDevices: [savedUdid("1").lowercased()])) { w in
            #expect(await w.run().data["status"] == "working")
        }
    }

    @Test("build failure stops before the guard and the install")
    func buildFailure() async throws {
        try await withCanaryWorld(CanaryScenario(buildFails: true)) { w in
            let out = await w.run()
            #expect(code(out) == "BUILD_FAILED")
            #expect(out.errors[0].message.contains("No profiles for the bundle were found"))
            #expect(!w.calls.contains { $0.executable == "/usr/bin/codesign" })
            #expect(w.installs.isEmpty)
        }
    }

    @Test("a build with no Canary.app is BUILD_PRODUCT_MISSING and never reaches the guard")
    func productMissing() async throws {
        try await withCanaryWorld(CanaryScenario(buildSkipsApp: true)) { w in
            let out = await w.run()
            #expect(code(out) == "BUILD_PRODUCT_MISSING")
            #expect(!w.calls.contains { $0.executable == "/usr/bin/codesign" })
            #expect(w.installs.isEmpty)
        }
    }

    @Test("the built app is found like Node's stat: a symlink to a directory counts, a dangling one does not")
    func symlinkedApp() async throws {
        try await withCanaryWorld(CanaryScenario(appIsSymlink: true)) { w in
            #expect(await w.run().data["status"] == "working")
        }
        try await withCanaryWorld(CanaryScenario(appIsDangling: true)) { w in
            let out = await w.run()
            #expect(code(out) == "BUILD_PRODUCT_MISSING")
            #expect(w.installs.isEmpty)
        }
    }

    @Test("preflight failure (only the free cert) stops before building")
    func preflightFailure() async throws {
        try await withCanaryWorld(CanaryScenario(free: true)) { w in
            let out = await w.run()
            #expect(code(out) == "PRECHECK_FAILED")
            #expect(out.data["checks"]?.array?.isEmpty == false)
            #expect(w.builds.isEmpty)
            #expect(w.installs.isEmpty)
        }
    }

    @Test("snapshot failure stops before building")
    func snapshotFailure() async throws {
        try await withCanaryWorld(CanaryScenario(snapshotFails: true)) { w in
            let out = await w.run()
            #expect(code(out) == "SNAPSHOT_FAILED")
            #expect(w.builds.isEmpty)
        }
    }

    @Test("every subprocess call carries a timeout; every devicectl call carries --timeout and --json-output")
    func timeouts() async throws {
        try await withCanaryWorld { w in
            _ = await w.run()
            #expect(!w.calls.isEmpty)
            for c in w.calls {
                #expect(c.timeout > .zero, "\(c.executable)")
                #expect(c.maxOutputBytes > 0)
                if c.executable == "xcrun" && c.args.first == "devicectl" {
                    #expect(c.args.contains("--timeout") && c.args.contains("--json-output"))
                    #expect(c.args.contains("--device") || c.args[1] == "list")
                }
            }
            #expect(w.installs[0].timeout == .seconds(120 + 15))
            #expect(w.installs[0].args.contains("120"))
            #expect(w.uninstalls[0].args.contains("60"))
        }
    }

    @Test("no device id other than the saved CoreDevice UUID is passed to --device")
    func onlySavedId() async throws {
        try await withCanaryWorld { w in
            _ = await w.run()
            let devices = w.calls.filter { $0.args.contains("--device") }
            #expect(!devices.isEmpty)
            for c in devices {
                #expect(c.args[c.args.firstIndex(of: "--device")! + 1] == savedCoreId("1"))
            }
        }
    }

    @Test("only the exact canary id is ever uninstalled, never the other apps")
    func uninstallsOnlyCanary() async throws {
        for scenario in [CanaryScenario(), CanaryScenario(install: .timeout), CanaryScenario(extraAfter: true)] {
            try await withCanaryWorld(scenario) { w in
                _ = await w.run()
                #expect(w.uninstalls.allSatisfy { $0.args.last == canaryBundle })
            }
        }
    }
}

@Suite("canary: lock and logs")
struct CanaryLockLogTests {
    @Test("a second concurrent run gets OPERATION_IN_PROGRESS and touches nothing")
    func lockContention() async throws {
        try await withCanaryWorld { w in
            let held = try OperationLock.acquire(paths: w.paths)
            let blocked = await w.run()
            #expect(code(blocked) == "OPERATION_IN_PROGRESS")
            #expect(!blocked.ok)
            #expect(w.calls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: w.paths.canaryLog))
            held.release()
            #expect(await w.run().data["status"] == "working")
        }
    }

    @Test("the lock is released when the run ends, on success and on failure")
    func lockReleased() async throws {
        for scenario in [CanaryScenario(), CanaryScenario(buildFails: true), CanaryScenario(free: true)] {
            try await withCanaryWorld(scenario) { w in
                _ = await w.run()
                let again = try OperationLock.acquire(paths: w.paths)
                again.release()
            }
        }
    }

    @Test("the confirmation and usage guards run before the lock is taken")
    func guardsBeforeLock() async throws {
        try await withCanaryWorld { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(code(await w.run(CanaryOptions(device: "iphone", yes: false))) == "CONFIRM_REQUIRED")
            #expect(code(await w.run(CanaryOptions(yes: true))) == "USAGE")
        }
    }

    @Test("one canary.jsonl line per run: the original fields plus macosVersion, iosVersion, certFp, certNotAfter")
    func logLine() async throws {
        try await withCanaryWorld(CanaryScenario(install: try .failure("install-blocked-8018-hex.json"))) { w in
            _ = await w.run()
            _ = await w.run(CanaryOptions(device: "iphone", yes: true))
            let raw = try String(contentsOfFile: w.paths.canaryLog, encoding: .utf8)
            #expect(raw.hasSuffix("\n"))
            #expect(raw.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
            let line = try #require(try w.jsonlLines.first)
            guard case .object(let fields) = line else { Issue.record("not an object"); return }
            #expect(
                Set(fields.keys) == [
                    "ts", "status", "code", "device", "xcodeVersion", "guard", "durationMs",
                    "macosVersion", "iosVersion", "certFp", "certNotAfter",
                ])
            #expect(line["ts"] == "2026-10-19T12:00:00.000Z")
            #expect(line["status"] == "blocked")
            #expect(line["code"] == "0xe8008018")
            #expect(line["device"] == .string("…" + savedUdid("1").suffix(4)))
            #expect(line["xcodeVersion"] == "27.0 (27A266a)")
            #expect(line["guard"] == "passed")
            #expect(line["durationMs"] == 0)
            #expect(modeOf(w.paths.canaryLog) == 0o600)
        }
    }

    @Test("a run that stops early still logs its line, with guard skipped and no Xcode version")
    func earlyLog() async throws {
        try await withCanaryWorld(CanaryScenario(free: true)) { w in
            _ = await w.run()
            let line = try #require(try w.jsonlLines.first)
            #expect(line["status"] == "error")
            #expect(line["code"] == "PRECHECK_FAILED")
            #expect(line["guard"] == "skipped")
            #expect(line["xcodeVersion"] == .null)
        }
    }

    @Test("a failing log append is a LOG_WRITE_FAILED warning, not a failed run")
    func logWriteFails() async throws {
        try await withCanaryWorld { w in
            try FileManager.default.createDirectory(atPath: w.paths.canaryLog, withIntermediateDirectories: true)
            let out = await w.run()
            #expect(out.data["status"] == "working")
            #expect(warningCodes(out) == ["LOG_WRITE_FAILED"])
        }
    }

    @Test("appended lines from concurrent writers never interleave")
    func appendIsAtomic() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("x.jsonl").path
        let payload = String(repeating: "x", count: 400)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { try? AppendFile.appendLine("\(i) \(payload)", to: path) }
            }
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 40)
        #expect(lines.allSatisfy { $0.hasSuffix(payload) })
        #expect(Set(lines.map { $0.split(separator: " ")[0] }).count == 40)
    }

    @Test("no output, log or saved JSON carries a UDID, CoreDevice id or device name")
    func noIdentifiers() async throws {
        let config = canaryConfig { $0.devices["iphone"]?.name = "Test iPhone" }
        let scenario = CanaryScenario(install: try .failure("install-blocked-8018-hex.json"))
        try await withCanaryWorld(scenario, config: config) { w in
            let out = await w.run()
            let (text, _) = try out.printed()
            var everything = text + (try String(contentsOfFile: w.paths.canaryLog, encoding: .utf8))
            for f in w.savedInstalls { everything += try w.savedInstall(f) }
            everything += w.logged.joined()
            for secret in [savedUdid("1"), savedCoreId("1"), "Test iPhone"] { #expect(!everything.contains(secret)) }
        }
    }
}

@Suite("command log")
struct CommandLogTests {
    @Test("LoggingRunner logs `exec <file> <args>` before running, redacted, and passes the result through")
    func logsEachCommand() async throws {
        let fake = FakeRunner { _ in RunResult(code: 3, stdout: "out") }
        let seen = Mutex<[String]>([])
        let runner = LoggingRunner(fake) { line in seen.withLock { $0.append(line) } }
        let res = await runner.run(CommandSpec(executable: "xcodebuild", args: ["-destination", "id=x", "build"], timeout: .seconds(1)))
        #expect(res == RunResult(code: 3, stdout: "out"))
        #expect(seen.withLock { $0 } == ["exec xcodebuild -destination id=x build"])
        #expect(fake.calls.count == 1)
        _ = await runner.run(CommandSpec(executable: "/usr/bin/true", timeout: .seconds(1)))
        #expect(seen.withLock { $0 }.last == "exec /usr/bin/true ")
    }

    @Test("commands.log gets one timestamped, redacted line per subprocess, with mode 0600")
    func fileSink() async throws {
        try await withTestHome { paths, _ in
            let runner = LoggingRunner(FakeRunner(), log: ProgressLog.makeFileOnly(home: paths, clock: FixedClock(testNow)))
            _ = await runner.run(
                CommandSpec(
                    executable: "xcodebuild", args: ["-destination", "id=\(savedUdid("1"))", "x@example.invalid", "/Users/someone/p"],
                    timeout: .seconds(1)))
            _ = await runner.run(CommandSpec(executable: "xcrun", args: ["devicectl", "--device", savedCoreId("1")], timeout: .seconds(1)))
            let text = try String(contentsOfFile: paths.commandsLog, encoding: .utf8)
            #expect(
                text == """
                    2026-10-19T12:00:00.000Z exec xcodebuild -destination id=…\(savedUdid("1").suffix(4)) <email> /Users/<user>/p
                    2026-10-19T12:00:00.000Z exec xcrun devicectl --device …\(savedCoreId("1").suffix(4))

                    """)
            #expect(!text.contains(savedUdid("1")) && !text.contains(savedCoreId("1")))
            #expect(modeOf(paths.commandsLog) == 0o600)
        }
    }

    @Test("the live services log every subprocess through the runner, so every command leaves a trail")
    func liveServices() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = Services.live(environment: ["SIDELOAD_HOME": dir.path + "/home"])
        try services.home.ensureHome()
        // /usr/bin/true is harmless; nothing here touches xcodebuild, devicectl or the real home.
        let res = await services.runner.run(CommandSpec(executable: "/usr/bin/true", timeout: .seconds(10)))
        #expect(res.code == 0)
        let text = try String(contentsOfFile: services.home.commandsLog, encoding: .utf8)
        #expect(text.hasSuffix(" exec /usr/bin/true \n"))
    }

    @Test("doctor and canary through fake services reach the runner unchanged (decoration is live-only)")
    func fakesUndecorated() async throws {
        try await withCanaryWorld { w in
            _ = await w.run()
            #expect(!FileManager.default.fileExists(atPath: w.paths.commandsLog))
        }
    }
}

@Suite("progress log")
struct ProgressLogTests {
    @Test("a progress line is redacted, written to stderr and appended to logs/commands.log with a timestamp")
    func writesBoth() async throws {
        try await withTestHome { paths, _ in
            let sink = paths.tmp + "/stderr.txt"
            let fd = open(sink, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            defer { close(fd) }
            let log = ProgressLog.make(home: paths, clock: FixedClock(testNow), stderrFD: fd)
            log("canary: preflight \(savedUdid("1")) in /Users/someone/x")
            log("canary: installing")
            let expected = ["canary: preflight …\(savedUdid("1").suffix(4)) in /Users/<user>/x", "canary: installing"]
            let err = try String(contentsOfFile: sink, encoding: .utf8)
            #expect(err == expected.map { $0 + "\n" }.joined())
            let file = try String(contentsOfFile: paths.commandsLog, encoding: .utf8)
            #expect(file == expected.map { "2026-10-19T12:00:00.000Z \($0)\n" }.joined())
            #expect(modeOf(paths.commandsLog) == 0o600)
        }
    }

    @Test("a failing sink never breaks the command")
    func neverThrows() async throws {
        let paths = Paths(home: "/nonexistent-sideload-home")
        let log = ProgressLog.make(home: paths, clock: FixedClock(testNow), stderrFD: -1)
        log("canary: preflight")
    }
}

@Suite("canary: CLI")
struct CanaryCLITests {
    @Test("sideload canary --device <alias> --yes runs through the parser; --keep is accepted")
    func parsed() async throws {
        try await withCanaryWorld { w in
            let out = await run(argv: ["canary", "--device", "iphone", "--yes"], services: w.services)
            #expect(out.ok)
            #expect(out.command == "canary")
            #expect(out.data["status"] == "working")
            #expect(w.uninstalls.count == 1)
        }
        try await withCanaryWorld { w in
            let out = await run(argv: ["canary", "--device=iphone", "--yes", "--keep"], services: w.services)
            #expect(out.data["status"] == "working")
            #expect(w.uninstalls.isEmpty)
        }
    }

    @Test("canary without --yes is CONFIRM_REQUIRED; unknown options and positionals are USAGE")
    func usage() async throws {
        try await withCanaryWorld { w in
            #expect(code(await run(argv: ["canary", "--device", "iphone"], services: w.services)) == "CONFIRM_REQUIRED")
            #expect(code(await run(argv: ["canary"], services: w.services)) == "USAGE")
            #expect(code(await run(argv: ["canary", "--device"], services: w.services)) == "USAGE")
            #expect(code(await run(argv: ["canary", "--bogus"], services: w.services)) == "USAGE")
            #expect(code(await run(argv: ["canary", "extra", "--device", "iphone", "--yes"], services: w.services)) == "USAGE")
            #expect(w.calls.isEmpty)
        }
    }

    @Test("help lists canary as built")
    func help() async throws {
        try await withCanaryWorld { w in
            let out = await run(argv: ["help"], services: w.services)
            #expect(out.json["built"] == ["doctor", "device", "canary", "ledger", "portal", "export-cert", "status", "inspect", "fetch", "provision", "sign", "install", "refresh", "app", "slot", "updates", "clean"])
        }
    }
}
