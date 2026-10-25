import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// `provision` (design section 18, build step 5). Fakes only: the xcodebuild is a script that writes a synthetic
// profile into the derived data, the keychain replays identity lists, profiles are plists built at runtime.

private let udid1 = savedUdid("1")
private let udid2 = savedUdid("2")

private func fp8(_ cert: KeychainCertificate) -> String { LedgerSync.fp8(cert.reference) }

private func iso(_ date: Date) -> JSONValue { .string(ProgressLog.isoTimestamp(date)) }

private func pinConfig(_ fp8: String, reserved: Int? = nil) -> Config {
    var free: [String: JSONValue] = ["certFp8": .string(fp8)]
    if let reserved { free["reservedAppIds"] = .number(Double(reserved)) }
    return provisionConfig(extra: ["freeTeam": .object(free)])
}

private func tvScript() throws -> BuildScript {
    BuildScript(
        profile: try freeProfileXML(devices: [udid2], platform: ["tvOS"]), sdk: "appletvos")
}

private func seed(_ w: ProvisionWorld, _ body: (inout Ledger) -> Void) async throws {
    try await w.services.ledgerStore.update { body(&$0) }
}

private func tail(_ udid: String) -> String { Redactor.tail4(udid) }

// MARK: usage, device and platform

@Suite("provision: arguments and device")
struct ProvisionArgumentTests {
    @Test("--app and --device are required, and the app must be one of ours")
    func usage() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            #expect(await w.run(ProvisionOptions(device: "iphone", yes: true)).errors.first?.code == "USAGE")
            #expect(await w.run(ProvisionOptions(app: "stremio-ios", yes: true)).errors.first?.code == "USAGE")
            #expect(await w.run(app: "bogus").errors.first?.code == "USAGE")
            #expect(await w.run(app: "com.example.free.x").errors.first?.code == "USAGE")
            #expect(w.runner.calls.isEmpty)
            #expect(w.keychain.readCount == 0)
        }
    }

    @Test("an unsaved device is DEVICE_NOT_SAVED and a missing prefix is CONFIG_MISSING; nothing runs")
    func deviceAndPrefix() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            #expect(await w.run(device: "nope").errors.first?.code == "DEVICE_NOT_SAVED")
            #expect(w.runner.calls.isEmpty)
        }
        try await withProvisionWorld(config: provisionConfig(prefix: nil)) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "CONFIG_MISSING")
            #expect(w.runner.calls.isEmpty)
        }
        try await withProvisionWorld(config: provisionConfig(prefix: "not valid!")) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "CONFIG_MISSING")
        }
    }

    @Test("without --yes it asks for confirmation before any keychain, subprocess or lock", arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func confirm(register: Bool, renew: Bool) async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let out = await w.run(register: register, renew: renew, yes: false)
            #expect(out.errors.first?.code == "CONFIRM_REQUIRED")
            #expect(out.data["bundleId"] == .string(stremioId))
            #expect(out.data["device"] == "iphone")
            #expect(w.runner.calls.isEmpty)
            #expect(w.keychain.readCount == 0)
            #expect(!FileManager.default.fileExists(atPath: w.paths.builds + "/carrier"))
            // The confirmation names the side effects it covers.
            let message = out.errors[0].message
            #expect(message.contains("registers this device") == register)
            #expect(message.contains("moves its own cached profile") == renew)
        }
    }

    @Test("each app maps to its free bundle ID, checked against the allowlist", arguments: [
        ("stremio-ios", "iphone", "io.github.dividedby.free.stremio"),
        ("stremio-tvos", "appletv", "io.github.dividedby.free.stremio"),
        ("apollo", "iphone", "io.github.dividedby.free.apollo"),
    ])
    func bundleIds(app: String, device: String, expected: String) async throws {
        let tv = device == "appletv"
        try await withProvisionWorld(
            build: BuildScript(
                profile: try freeProfileXML(
                    bundleId: expected, devices: [tv ? udid2 : udid1], platform: [tv ? "tvOS" : "iOS"]),
                sdk: tv ? "appletvos" : "iphoneos")
        ) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: app, device: device)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["bundleId"] == .string(expected))
            #expect(Config.isFreeBundleId(expected, prefix: carrierPrefix))
            let build = try #require(w.builds.first)
            #expect(build.args.contains("PRODUCT_BUNDLE_IDENTIFIER=\(expected)"))
            #expect(build.args.contains("id=\(tv ? udid2 : udid1)"))
        }
    }

    @Test("the namespace follows bundleIdPrefix")
    func otherPrefix() async throws {
        try await withProvisionWorld(
            config: provisionConfig(prefix: "com.example"),
            build: BuildScript(profile: try freeProfileXML(bundleId: "com.example.free.apollo"))
        ) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "apollo")
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["bundleId"] == "com.example.free.apollo")
        }
    }

    @Test("the platform of the saved device must match the app", arguments: [
        ("stremio-tvos", "iphone"), ("stremio-ios", "appletv"), ("apollo", "appletv"),
    ])
    func platformMismatch(app: String, device: String) async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let out = await w.run(app: app, device: device)
            #expect(out.errors.first?.code == "PLATFORM_MISMATCH")
            #expect(out.data["app"] == .string(app))
            #expect(w.runner.calls.isEmpty, "no xcodebuild, no security")
            #expect(w.keychain.readCount == 0)
            #expect(!FileManager.default.fileExists(atPath: w.paths.builds + "/carrier"))
        }
    }

    @Test("a saved device with no recorded platform matches no app")
    func noPlatform() async throws {
        let config = Config(
            devices: ["old": SavedDevice(udid: udid1, coreDeviceId: savedCoreId("1"))], bundleIdPrefix: carrierPrefix)
        try await withProvisionWorld(config: config) { (w: ProvisionWorld) async throws in
            #expect(await w.run(device: "old").errors.first?.code == "PLATFORM_MISMATCH")
        }
    }

    @Test("a busy operation lock is OPERATION_IN_PROGRESS and nothing else runs")
    func busyLock() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let held = try OperationLock.acquire(paths: w.paths)
            let out = await w.run()
            #expect(out.errors.first?.code == "OPERATION_IN_PROGRESS")
            #expect(w.runner.calls.isEmpty)
            #expect(w.keychain.readCount == 0)
            held.release()
            #expect(await w.run().ok, "released: it runs")
        }
    }

    @Test("the lock is released after a run, success or failure")
    func lockReleased() async throws {
        try await withProvisionWorld(reads: [nil]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "KEYCHAIN_LOCKED")
            let lock = try OperationLock.acquire(paths: w.paths)
            lock.release()
        }
    }
}

// MARK: the build command

@Suite("provision: xcodebuild")
struct ProvisionBuildTests {
    @Test("the argv, the timeout and the output cap; the identity argument is one element")
    func argv() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(w.builds.count == 1)
            let build = try #require(w.builds.first)
            #expect(build.executable == "xcodebuild")
            #expect(
                build.args == [
                    "-project", w.paths.builds + "/carrier/Carrier.xcodeproj", "-scheme", "Carrier",
                    "-destination", "id=\(udid1)", "-derivedDataPath", w.paths.builds + "/carrier-dd",
                    "-allowProvisioningUpdates", "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=6ZU5Z6ZKK7",
                    "CODE_SIGN_IDENTITY=Apple Development", "PRODUCT_BUNDLE_IDENTIFIER=\(stremioId)", "build",
                ])
            #expect(build.timeout == .seconds(600))
            #expect(build.maxOutputBytes == 128 * 1024 * 1024)
            #expect(!build.args.contains("-allowProvisioningDeviceRegistration"))
            #expect(build.args.filter { $0.contains("Apple Development") } == ["CODE_SIGN_IDENTITY=Apple Development"])
        }
    }

    @Test("-allowProvisioningDeviceRegistration only with --register-device and --yes, right after -allowProvisioningUpdates")
    func registerFlag() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            #expect(await w.run(register: true, yes: true).ok)
            let args = try #require(w.builds.first).args
            #expect(args.filter { $0 == "-allowProvisioningDeviceRegistration" }.count == 1)
            let updates = try #require(args.firstIndex(of: "-allowProvisioningUpdates"))
            #expect(args[updates + 1] == "-allowProvisioningDeviceRegistration")
        }
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            _ = await w.run(register: false, yes: true)
            #expect(try #require(w.builds.first).args.contains("-allowProvisioningDeviceRegistration") == false)
            let refused = await w.run(register: true, yes: false)
            #expect(refused.errors.first?.code == "CONFIRM_REQUIRED")
            #expect(w.builds.count == 1, "the refused run built nothing")
        }
    }

    @Test("every subprocess is an argument array with a timeout; only xcodebuild and security run")
    func noShell() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            _ = await w.run()
            #expect(!w.runner.calls.isEmpty)
            for call in w.runner.calls {
                #expect(["xcodebuild", "/usr/bin/security"].contains(call.executable), "\(call.executable)")
                #expect(call.timeout > .zero)
                #expect(!call.args.contains("-c"))
            }
            let decode = try #require(w.securityCalls.first)
            // The bytes that were read are decoded on stdin, so the stored copy is the decoded one.
            #expect(decode.args == ["cms", "-D"])
            #expect(decode.stdin == Data(try freeProfileXML().utf8))
        }
    }

    @Test("the carrier project is written before the build and the paid canary is not touched")
    func carrierWritten() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            _ = await w.run()
            #expect(FileManager.default.fileExists(atPath: w.paths.builds + "/carrier/Carrier.xcodeproj/project.pbxproj"))
            #expect(!FileManager.default.fileExists(atPath: w.paths.builds + "/canary"))
        }
    }

    @Test("a profile left by an earlier build is never read: the products are cleared first")
    func staleProducts() async throws {
        try await withProvisionWorld(build: BuildScript(profile: nil, createApp: false)) { (w: ProvisionWorld) async throws in
            let app = w.paths.builds + "/carrier-dd/Build/Products/Debug-iphoneos/Carrier.app"
            try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
            try Data(try freeProfileXML().utf8).write(to: URL(fileURLWithPath: app + "/embedded.mobileprovision"))
            let out = await w.run()
            #expect(out.errors.first?.code == "BUILD_PRODUCT_MISSING")
            #expect(!FileManager.default.fileExists(atPath: app))
            #expect(try w.ledger().freeProfiles.isEmpty)
        }
    }

    @Test("a tvOS device builds into Debug-appletvos")
    func tvos() async throws {
        try await withProvisionWorld(build: try tvScript()) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "stremio-tvos", device: "appletv")
            #expect(out.ok, "\(out.errors)")
            #expect(FileManager.default.fileExists(atPath: w.paths.builds + "/carrier-dd/Build/Products/Debug-appletvos/Carrier.app"))
            #expect(out.data["file"] == "profiles/free/stremio-tvos/appletv/0F0F0F0F-1111-2222-3333-444444444444.mobileprovision")
        }
    }
}

// MARK: preflight

@Suite("provision: preflight")
struct ProvisionPreflightTests {
    private func refused(_ w: ProvisionWorld) {
        #expect(w.builds.isEmpty, "nothing was built")
        #expect(!FileManager.default.fileExists(atPath: w.paths.builds + "/carrier"))
    }

    @Test("a keychain that cannot be read is KEYCHAIN_LOCKED")
    func locked() async throws {
        try await withProvisionWorld(reads: [nil]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "KEYCHAIN_LOCKED")
            refused(w)
            #expect(try w.ledger() == Ledger())
        }
    }

    @Test("with no pin, no valid free identity is FREE_IDENTITY_MISSING and several are FREE_IDENTITY_AMBIGUOUS")
    func unpinned() async throws {
        try await withProvisionWorld(reads: [[]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_IDENTITY_MISSING")
            refused(w)
        }
        // A paid-team or expired free identity is not a candidate.
        let expired = otherFreeCert(notAfter: daysFromNow(-1))
        try await withProvisionWorld(reads: [[try keychainCert(TestCerts.paid), expired]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_IDENTITY_MISSING")
        }
        try await withProvisionWorld(reads: [[try freeKeychainCert(), otherFreeCert()]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_IDENTITY_AMBIGUOUS")
            #expect(out.data["candidateFp8"]?.array?.count == 2)
            refused(w)
            #expect(try w.config().freeTeamCertFp8() == nil, "nothing was pinned")
        }
    }

    @Test("a pinned identity must be present and valid, and exactly one")
    func pinned() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(config: pinConfig("deadbeef"), reads: [[free]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_IDENTITY_MISSING")
            #expect(out.data["pinnedFp8"] == "deadbeef")
            refused(w)
        }
        let expired = otherFreeCert(notAfter: daysFromNow(-1))
        try await withProvisionWorld(config: pinConfig(fp8(expired)), reads: [[free, expired]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_IDENTITY_MISSING", "an expired pinned identity is not valid")
        }
        let twinA = otherFreeCert("AB", fp8: "abcdef01"), twinB = otherFreeCert("CD", fp8: "abcdef01")
        try await withProvisionWorld(config: pinConfig("abcdef01"), reads: [[free, twinA, twinB]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_IDENTITY_AMBIGUOUS")
            refused(w)
        }
    }

    @Test("with a pin, another free identity in the keychain does not make it ambiguous")
    func pinnedAmongOthers() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(config: pinConfig(fp8(free)), reads: [[free, otherFreeCert()]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["pinnedFp8"] == .string(fp8(free)))
            #expect(out.data["pinnedNow"] == false)
        }
    }

    @Test("a malformed freeTeam block is CONFIG_INVALID", arguments: [
        JSONValue.string("x"), ["certFp8": "XYZ"], ["certFp8": 12], ["certFp8": "ABCDEF01"], ["reservedAppIds": "4"],
        ["reservedAppIds": 11], ["reservedAppIds": -1], ["reservedAppIds": 2.5],
    ])
    func badConfig(value: JSONValue) async throws {
        try await withProvisionWorld(config: provisionConfig(extra: ["freeTeam": value])) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "CONFIG_INVALID")
            refused(w)
        }
    }

    @Test("the App ID budget: a new bundle ID needs recent + reserved + 1 <= 10")
    func budget() async throws {
        func epochs(_ n: Int) -> [LedgerFreeAppId] {
            (0..<n).map { LedgerFreeAppId(bundleId: "io.github.dividedby.free.x\($0)", epochStart: daysFromNow(-1)) }
        }
        // 5 + 4 + 1 = 10: allowed.
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeAppIds = epochs(5) }
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["appIdNew"] == true)
            #expect(out.data["appIdsLast7Days"] == 6)
        }
        // 6 + 4 + 1 = 11: refused before anything runs.
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeAppIds = epochs(6) }
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_APP_ID_LIMIT")
            #expect(out.data["appIdsLast7Days"] == 6)
            #expect(out.data["reservedAppIds"] == 4)
            refused(w)
            #expect(try w.ledger().freeAppIds.count == 6, "the ledger is unchanged")
        }
        // The owner's reserve moves the line.
        try await withProvisionWorld(config: pinConfig(fp8(try freeKeychainCert()), reserved: 0)) { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeAppIds = epochs(9) }
            #expect(await w.run().ok)
        }
        try await withProvisionWorld(config: pinConfig(fp8(try freeKeychainCert()), reserved: 0)) { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeAppIds = epochs(10) }
            #expect(await w.run().errors.first?.code == "FREE_APP_ID_LIMIT")
        }
    }

    @Test("a bundle ID with a live epoch is not new and is never refused for the budget")
    func liveEpoch() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) {
                $0.freeAppIds = (0..<9).map {
                    LedgerFreeAppId(bundleId: "io.github.dividedby.free.x\($0)", epochStart: daysFromNow(-2))
                } + [LedgerFreeAppId(bundleId: stremioId, epochStart: daysFromNow(-3))]
            }
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["appIdNew"] == false)
            #expect(out.data["appIdsLast7Days"] == 10)
            #expect(try w.ledger().freeAppIds.first { $0.bundleId == stremioId }?.epochStart == daysFromNow(-3), "the epoch is kept")
        }
    }

    @Test("epochs roll over after 7 days: older ones stop counting and the bundle ID starts a new epoch")
    func rollover() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) {
                $0.freeAppIds = (0..<8).map {
                    LedgerFreeAppId(bundleId: "io.github.dividedby.free.x\($0)", epochStart: daysFromNow(-7))
                } + [LedgerFreeAppId(bundleId: stremioId, epochStart: daysFromNow(-8))]
            }
            let out = await w.run()
            #expect(out.ok, "nine old epochs no longer count: \(out.errors)")
            #expect(out.data["appIdNew"] == true, "its own epoch ended")
            #expect(out.data["appIdsLast7Days"] == 1)
            #expect(try w.ledger().freeAppIds == [LedgerFreeAppId(bundleId: stremioId, epochStart: testNow)])
        }
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) {
                $0.freeAppIds = [LedgerFreeAppId(bundleId: stremioId, epochStart: testNow.addingTimeInterval(-7 * 86_400 + 1))]
            }
            #expect(await w.run().data["appIdNew"] == false, "one second short of 7 days is still live")
        }
    }
}

// MARK: the identity diff

@Suite("provision: identity diff")
struct ProvisionIdentityTests {
    @Test("an unchanged identity set passes, and the keychain is read twice (before and after)")
    func unchanged() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free, try keychainCert(TestCerts.paid)], [try keychainCert(TestCerts.paid), free]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["identityChanged"] == false)
            #expect(w.keychain.readCount == 2)
            #expect(try w.ledger().freeSuspended == nil)
        }
    }

    @Test("a paid-team certificate appearing is not a change to the free set")
    func paidNotCounted() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free], [free, try keychainCert(TestCerts.paid)]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().ok)
        }
    }

    @Test("an added free identity is FREE_CERT_CHANGED: nothing is stored or pinned, auto-refresh is suspended")
    func added() async throws {
        let free = try freeKeychainCert(), extra = otherFreeCert()
        try await withProvisionWorld(reads: [[free], [free, extra]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.errors.first?.fix?.contains("suspended") == true)
            #expect(out.data["identityChanged"] == true)
            #expect(out.data["suspended"] == true)
            #expect(out.data["buildSucceeded"] == true)
            #expect(out.data["addedFp8"] == [.string(fp8(extra))])
            #expect(out.data["removedFp8"] == [])
            let ledger = try w.ledger()
            #expect(ledger.freeProfiles.isEmpty)
            let suspended = try #require(ledger.freeSuspended)
            #expect(suspended.code == "FREE_CERT_CHANGED")
            #expect(suspended.addedFp8 == [fp8(extra)] && suspended.removedFp8 == [])
            #expect(suspended.at == testNow)
            #expect(try w.config().freeTeamCertFp8() == nil, "the first run did not pin")
            #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles"))
            #expect(ledger.freeAppIds.map(\.bundleId) == [stremioId], "the build succeeded, so the App ID exists")
        }
    }

    @Test("a removed free identity, the pinned one included, is FREE_CERT_CHANGED")
    func removed() async throws {
        let free = try freeKeychainCert(), other = otherFreeCert()
        try await withProvisionWorld(config: pinConfig(fp8(free)), reads: [[free, other], [free]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.data["removedFp8"] == [.string(fp8(other))])
            #expect(out.data["addedFp8"] == [])
        }
        try await withProvisionWorld(config: pinConfig(fp8(free)), reads: [[free, other], [other]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.data["removedFp8"] == [.string(fp8(free))])
            #expect(try w.ledger().freeSuspended?.removedFp8 == [fp8(free)])
        }
    }

    @Test("an invalid (expired) free identity appearing counts too: the snapshot covers every free identity")
    func invalidCounts() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free], [free, otherFreeCert(notAfter: daysFromNow(-5))]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_CERT_CHANGED")
        }
    }

    @Test("the check runs even when xcodebuild failed, and it outranks the build error")
    func afterFailedBuild() async throws {
        let free = try freeKeychainCert(), extra = otherFreeCert()
        let failing = BuildScript(result: RunResult(code: 65, stderr: "error: something odd\n"))
        try await withProvisionWorld(reads: [[free], [free, extra]], build: failing) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.data["buildSucceeded"] == false)
            #expect(w.keychain.readCount == 2)
            let ledger = try w.ledger()
            #expect(ledger.freeSuspended?.addedFp8 == [fp8(extra)])
            #expect(ledger.freeAppIds.map(\.bundleId) == [stremioId], "xcodebuild ran, so the App ID is counted")
        }
        // Timed out: the same.
        let timedOut = BuildScript(result: RunResult(code: nil, timedOut: true))
        try await withProvisionWorld(reads: [[free], [free, extra]], build: timedOut) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_CERT_CHANGED")
        }
        // Failed with an unchanged set: the build error, no suspension.
        try await withProvisionWorld(reads: [[free], [free]], build: failing) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "PROVISION_FAILED")
            #expect(out.data["identityChanged"] == nil)
            #expect(w.keychain.readCount == 2)
            #expect(try w.ledger().freeSuspended == nil)
        }
    }

    @Test("a keychain that cannot be read after the build fails closed and suspends")
    func afterReadFails() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free], nil]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "IDENTITY_CHECK_FAILED")
            #expect(out.data["suspended"] == true)
            #expect(try w.ledger().freeSuspended?.code == "IDENTITY_CHECK_FAILED")
            #expect(try w.ledger().freeProfiles.isEmpty)
        }
    }

    @Test("a manual success lifts a suspension; the output says so")
    func suspensionCleared() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: daysFromNow(-1)) }
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["suspensionCleared"] == true)
            #expect(try w.ledger().freeSuspended == nil)
        }
    }
}

// MARK: pinning

@Suite("provision: pinning")
struct ProvisionPinningTests {
    @Test("the first success pins the one valid free identity; other freeTeam keys and config are kept")
    func firstRunPins() async throws {
        let free = try freeKeychainCert()
        let config = provisionConfig(extra: ["freeTeam": ["reservedAppIds": 3, "future": "kept"], "other": 1])
        try await withProvisionWorld(config: config) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["pinnedNow"] == true)
            #expect(out.data["pinnedFp8"] == .string(fp8(free)))
            let saved = try w.config()
            #expect(try saved.freeTeamCertFp8() == fp8(free))
            #expect(try saved.freeTeamReservedAppIds() == 3)
            #expect(saved.extra["freeTeam"]?["future"] == "kept")
            #expect(saved.extra["other"] == 1)
            #expect(saved.bundleIdPrefix == carrierPrefix)
            #expect(saved.devices.keys.sorted() == ["appletv", "iphone"])
            #expect(modeOf(w.paths.config) == 0o600)
        }
    }

    @Test("with a pin already set, a success changes no config")
    func pinKept() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(config: pinConfig(fp8(free))) { (w: ProvisionWorld) async throws in
            let before = try Data(contentsOf: URL(fileURLWithPath: w.paths.config))
            #expect(await w.run().ok)
            #expect(try Data(contentsOf: URL(fileURLWithPath: w.paths.config)) == before)
        }
    }

    @Test("a profile that fails a check pins nothing")
    func noPinOnFailure() async throws {
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(getTaskAllow: false))) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "PROFILE_INVALID")
            #expect(try w.config().freeTeamCertFp8() == nil)
        }
    }

    @Test("the identity set changing between the preflight and the pin fails closed")
    func ambiguousAfter() async throws {
        // The same SHA-1 set before and after (so no diff), but a second *valid* free identity is not possible
        // here; instead the candidate disappears from the valid set because it is now expired in the after read.
        let free = try freeKeychainCert()
        var expiredCopy = free
        expiredCopy.info.notAfter = daysFromNow(-1)
        try await withProvisionWorld(reads: [[free], [expiredCopy]]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_IDENTITY_AMBIGUOUS")
            #expect(try w.config().freeTeamCertFp8() == nil)
            #expect(try w.ledger().freeProfiles.isEmpty)
        }
    }
}

// MARK: the profile checks

enum BadProfile: CaseIterable, Sendable {
    case paidTeam, wildcard, otherAppId, otherTeamPrefix, tvosPlatform, noTaskAllow, stringTaskAllow, otherDevice, noDevices,
        otherCert, noCerts, expired, expiresNow, tooLong

    var check: String {
        switch self {
        case .paidTeam: "team"
        case .wildcard, .otherAppId, .otherTeamPrefix: "application-identifier"
        case .tvosPlatform: "platform"
        case .noTaskAllow, .stringTaskAllow: "get-task-allow"
        case .otherDevice, .noDevices: "device"
        case .otherCert, .noCerts: "certificate"
        case .expired, .expiresNow, .tooLong: "expiry"
        }
    }

    func xml() throws -> String {
        switch self {
        case .paidTeam: try freeProfileXML(team: Team.paid, applicationIdentifier: Team.paid + "." + stremioId)
        case .wildcard: try freeProfileXML(applicationIdentifier: Team.free + ".*")
        case .otherAppId: try freeProfileXML(applicationIdentifier: Team.free + ".io.github.dividedby.free.apollo")
        case .otherTeamPrefix: try freeProfileXML(applicationIdentifier: Team.paid + "." + stremioId)
        case .tvosPlatform: try freeProfileXML(platform: ["tvOS"])
        case .noTaskAllow: try freeProfileXML(getTaskAllow: false)
        case .stringTaskAllow: try freeProfileXML(getTaskAllow: "true")
        case .otherDevice: try freeProfileXML(devices: [savedUdid("9")])
        case .noDevices: try freeProfileXML(devices: [])
        case .otherCert: try freeProfileXML(certs: [try certDER(TestCerts.paid)])
        case .noCerts: try freeProfileXML(certs: [])
        case .expired: try freeProfileXML(expires: daysFromNow(-1))
        case .expiresNow: try freeProfileXML(expires: testNow)
        case .tooLong: try freeProfileXML(expires: testNow.addingTimeInterval(8 * 86_400 + 1))
        }
    }
}

@Suite("provision: the embedded profile")
struct ProvisionProfileTests {
    @Test("each failed check is PROFILE_INVALID naming the check; nothing is stored", arguments: BadProfile.allCases)
    func invalid(bad: BadProfile) async throws {
        try await withProvisionWorld(build: BuildScript(profile: try bad.xml())) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "PROFILE_INVALID")
            #expect(out.data["check"] == .string(bad.check))
            let text = try out.printed().text
            #expect(!text.contains(udid1) && !text.contains(savedUdid("9")), "no profile content in the output")
            #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles"))
            #expect(try w.ledger().freeProfiles.isEmpty)
            #expect(try w.config().freeTeamCertFp8() == nil)
        }
    }

    @Test("an undecodable or missing profile is PROFILE_INVALID (decode)")
    func undecodable() async throws {
        for script in [BuildScript(profile: "not a plist"), BuildScript(profile: nil)] {
            try await withProvisionWorld(build: script) { (w: ProvisionWorld) async throws in
                let out = await w.run()
                #expect(out.errors.first?.code == "PROFILE_INVALID")
                #expect(out.data["check"] == "decode")
            }
        }
    }

    @Test("a symlink or a directory where the embedded profile belongs is PROFILE_INVALID (embedded-profile): never read through, never stored")
    func embeddedNotRegular() async throws {
        let elsewhere = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        // A perfectly valid profile, reachable only through the symlink.
        let target = elsewhere.appendingPathComponent("valid.mobileprovision").path
        try Data(try freeProfileXML().utf8).write(to: URL(fileURLWithPath: target))
        var link = BuildScript(profile: nil)
        link.embedAsSymlinkTo = target
        var directory = BuildScript(profile: nil)
        directory.embedAsDirectory = true
        for script in [link, directory] {
            try await withProvisionWorld(build: script) { (w: ProvisionWorld) async throws in
                let out = await w.run()
                #expect(out.errors.first?.code == "PROFILE_INVALID")
                #expect(out.data["check"] == "embedded-profile")
                #expect(w.securityCalls.isEmpty, "nothing was decoded")
                #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles"), "nothing stored")
                #expect(try w.ledger().freeProfiles.isEmpty)
            }
        }
    }

    @Test("a profile that expires in exactly 8 days passes; 6 hours short of now passes the lower bound")
    func boundaries() async throws {
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(expires: testNow.addingTimeInterval(8 * 86_400)))) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["profile"]?["daysLeft"] == 8)
        }
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(expires: testNow.addingTimeInterval(1)))) { (w: ProvisionWorld) async throws in
            #expect(await w.run().ok)
        }
    }

    @Test("the check order is team, application-identifier, platform, get-task-allow, device, certificate, expiry")
    func order() throws {
        let good = ProvisioningProfile(
            uuid: "0F0F0F0F-1111-2222-3333-444444444444", team: Team.free, applicationIdentifier: Team.free + "." + stremioId,
            getTaskAllow: true, platforms: ["iOS"], created: testNow, expires: daysFromNow(7), devices: [udid1.lowercased()],
            certFingerprints: ["AA"])
        func check(_ mutate: (inout ProvisioningProfile) -> Void) -> String? {
            var p = good
            mutate(&p)
            return ProvisionCommand.verify(p, bundleId: stremioId, platform: "iOS", udid: udid1, certificate: "aa", now: testNow)?.check
        }
        #expect(check { _ in } == nil)
        #expect(check { $0.team = nil } == "team")
        #expect(check { $0.applicationIdentifier = nil } == "application-identifier")
        #expect(check { $0.platforms = [] } == "platform")
        #expect(check { $0.getTaskAllow = nil } == "get-task-allow")
        #expect(check { $0.devices = [] } == "device")
        #expect(check { $0.certFingerprints = [] } == "certificate")
        #expect(check { $0.expires = nil } == "expiry")
        // Several wrong at once: the first in the order wins.
        #expect(check { $0.team = Team.paid; $0.expires = nil; $0.devices = [] } == "team")
        #expect(check { $0.devices = []; $0.expires = nil } == "device")
        // The UDID match ignores case.
        #expect(ProvisionCommand.verify(good, bundleId: stremioId, platform: "iOS", udid: udid1.uppercased(), certificate: "AA", now: testNow) == nil)
    }
}

// MARK: storage and records

@Suite("provision: storage and ledger")
struct ProvisionStorageTests {
    @Test("the profile is copied to profiles/free/<app>/<device>/<uuid>.mobileprovision, files 0600 and folders 0700")
    func storage() async throws {
        let xml = try freeProfileXML()
        try await withProvisionWorld(build: BuildScript(profile: xml)) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            let relative = "profiles/free/stremio-ios/iphone/0F0F0F0F-1111-2222-3333-444444444444.mobileprovision"
            #expect(out.data["file"] == .string(relative))
            let file = w.paths.home + "/" + relative
            #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(xml.utf8), "the signed bytes Xcode embedded")
            #expect(modeOf(file) == 0o600)
            for dir in ["profiles", "profiles/free", "profiles/free/stremio-ios", "profiles/free/stremio-ios/iphone"] {
                #expect(modeOf(w.paths.home + "/" + dir) == 0o700, "\(dir)")
            }
            #expect(listing(w.paths.home + "/profiles/free/stremio-ios/iphone").count == 1)
        }
    }

    @Test("two apps and two devices keep separate folders")
    func separate() async throws {
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(bundleId: apolloId))) { (w: ProvisionWorld) async throws in
            #expect(await w.run(app: "apollo").ok)
            #expect(FileManager.default.fileExists(atPath: w.paths.home + "/profiles/free/apollo/iphone"))
            #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles/free/stremio-ios"))
        }
    }

    @Test("the ledger records the profile (keyed device/app), the App ID epoch and no device ID or content")
    func ledgerRecords() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(created: daysFromNow(-0.5), expires: daysFromNow(6.5)))) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            let ledger = try w.ledger()
            let entry = try #require(ledger.freeProfiles.first)
            #expect(ledger.freeProfiles.count == 1)
            #expect(entry.id == "iphone/stremio-ios")
            #expect(entry.device == "iphone" && entry.app == "stremio-ios" && entry.bundleId == stremioId)
            #expect(entry.deviceTail == tail(udid1))
            #expect(entry.profileUuid == "0F0F0F0F-1111-2222-3333-444444444444")
            #expect(entry.created == daysFromNow(-0.5) && entry.expires == daysFromNow(6.5))
            #expect(entry.certFp8 == fp8(free))
            #expect(entry.file == "profiles/free/stremio-ios/iphone/0F0F0F0F-1111-2222-3333-444444444444.mobileprovision")
            #expect(ledger.freeAppIds == [LedgerFreeAppId(bundleId: stremioId, epochStart: testNow)])
            #expect(ledger.freeSuspended == nil)
            // Free profiles stay out of the paid lists.
            #expect(ledger.profiles.isEmpty && ledger.certificates.isEmpty)
            let raw = try String(contentsOfFile: w.paths.ledger, encoding: .utf8)
            for secret in [udid1, savedCoreId("1"), "Test iPhone", free.reference] { #expect(!raw.contains(secret)) }
            #expect(modeOf(w.paths.ledger) == 0o600)
        }
    }

    @Test("the output: profile facts, App ID counts, the pin; no UDID, device name, identity name or full fingerprint")
    func output() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(created: daysFromNow(0), expires: daysFromNow(6.5)))) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok)
            #expect(out.command == "provision")
            #expect(out.data["app"] == "stremio-ios")
            #expect(out.data["device"] == "iphone")
            #expect(out.data["bundleId"] == .string(stremioId))
            #expect(out.data["profile"]?["uuid"] == "0F0F0F0F-1111-2222-3333-444444444444")
            #expect(out.data["profile"]?["created"] == iso(testNow))
            #expect(out.data["profile"]?["expires"] == iso(daysFromNow(6.5)))
            #expect(out.data["profile"]?["daysLeft"] == 6)
            #expect(out.data["appIdNew"] == true)
            #expect(out.data["appIdsLast7Days"] == 1)
            #expect(out.data["identityChanged"] == false)
            #expect(out.data["pinnedFp8"] == .string(fp8(free)))
            let text = try out.printed().text
            for forbidden in [
                udid1, savedCoreId("1"), "Test iPhone", free.reference, free.commonName ?? "?", "TEST000002",
            ] {
                #expect(!text.contains(forbidden), "\(forbidden)")
            }
        }
    }

    @Test("no failure path prints a UDID, a device name or an identity name either")
    func failuresAreClean() async throws {
        let free = try freeKeychainCert()
        let log = "error: build for \(udid1) / \(savedCoreId("1")) failed on Test iPhone, Apple Development: Test (TEST000002), a@b.example\n"
        let scripts: [(BuildScript, [[KeychainCertificate]?])] = [
            (BuildScript(result: RunResult(code: 65, stderr: log)), [[free], [free]]),
            (BuildScript(result: RunResult(code: 65, stderr: log)), [[free], [free, otherFreeCert()]]),
            (BuildScript(profile: try freeProfileXML(getTaskAllow: false)), [[free], [free]]),
            (BuildScript(profile: try freeProfileXML(), createApp: false), [[free], nil]),
        ]
        for (script, reads) in scripts {
            try await withProvisionWorld(reads: reads, build: script) { (w: ProvisionWorld) async throws in
                let out = await w.run()
                #expect(!out.ok)
                let text = try out.printed().text
                for forbidden in [udid1, savedCoreId("1"), "Test iPhone", "TEST000002", "a@b.example", free.reference] {
                    #expect(!text.contains(forbidden), "\(forbidden) in \(out.errors.first?.code ?? "")")
                }
            }
        }
    }
}

// MARK: renewal

@Suite("provision: renewal")
struct ProvisionRenewalTests {
    private func previous(_ w: ProvisionWorld, uuid: String = "AAAAAAAA-0000-0000-0000-000000000001", expires: Date, id: String = "iphone/stremio-ios") async throws {
        try await seed(w) {
            $0.freeProfiles = [
                LedgerFreeProfile(
                    id: id, device: "iphone", deviceTail: tail(udid1), app: "stremio-ios", bundleId: stremioId, profileUuid: uuid,
                    created: expires.addingTimeInterval(-7 * 86_400), expires: expires, certFp8: "00000000", file: "profiles/free/old")
            ]
        }
    }

    @Test("the first profile for a device and app has nothing to compare with")
    func first() async throws {
        try await withProvisionWorld { w in #expect(await w.run().ok) }
    }

    @Test("a new expiry not more than 24 hours past the old one is PROFILE_NOT_RENEWED; the record and files stay")
    func notRenewed() async throws {
        // New expiry is testNow + 7 d.
        for old in [daysFromNow(7), daysFromNow(7 - 0.5), daysFromNow(7 - 1), daysFromNow(8), daysFromNow(30)] {
            try await withProvisionWorld { (w: ProvisionWorld) async throws in
                try await previous(w, expires: old)
                let out = await w.run()
                #expect(out.errors.first?.code == "PROFILE_NOT_RENEWED", "old \(old)")
                #expect(out.errors.first?.fix?.contains("--renew --yes") == true)
                #expect(out.data["profile"]?["daysLeft"] == 7)
                let ledger = try w.ledger()
                #expect(ledger.freeProfiles.map(\.profileUuid) == ["AAAAAAAA-0000-0000-0000-000000000001"], "the record is unchanged")
                #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles"), "nothing stored")
                #expect(try w.config().freeTeamCertFp8() == nil, "no pin from a run that did not renew")
            }
        }
    }

    @Test("more than 24 hours of movement is a renewal; the record is replaced and the old file is kept")
    func renewed() async throws {
        for old in [daysFromNow(7 - 1.001), daysFromNow(2), daysFromNow(-3)] {
            try await withProvisionWorld { (w: ProvisionWorld) async throws in
                try await previous(w, expires: old)
                let out = await w.run()
                #expect(out.ok, "old \(old): \(out.errors)")
                let ledger = try w.ledger()
                #expect(ledger.freeProfiles.map(\.profileUuid) == ["0F0F0F0F-1111-2222-3333-444444444444"])
                #expect(ledger.freeProfiles.count == 1)
            }
        }
    }

    @Test("sameProfile says whether Xcode handed back the same UUID; --renew changes the advice")
    func sameProfile() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await previous(w, uuid: "0F0F0F0F-1111-2222-3333-444444444444", expires: daysFromNow(7))
            let out = await w.run()
            #expect(out.data["sameProfile"] == true)
            let again = await w.run(renew: true)
            #expect(again.errors.first?.code == "PROFILE_NOT_RENEWED")
            #expect(again.errors.first?.fix?.contains("--renew was used") == true)
        }
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await previous(w, expires: daysFromNow(7))
            #expect(await w.run().data["sameProfile"] == false)
        }
    }

    @Test("another device's or app's record is not compared")
    func otherKey() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try await previous(w, expires: daysFromNow(7), id: "iphone/apollo")
            #expect(await w.run().ok)
        }
    }

    @Test("a refresh stores a second file and leaves the first")
    func filesAccumulate() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let dir = w.paths.home + "/profiles/free/stremio-ios/iphone"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: URL(fileURLWithPath: dir + "/AAAAAAAA-0000-0000-0000-000000000001.mobileprovision"))
            try await previous(w, expires: daysFromNow(1))
            #expect(await w.run().ok)
            #expect(listing(dir).sorted() == [
                "0F0F0F0F-1111-2222-3333-444444444444.mobileprovision", "AAAAAAAA-0000-0000-0000-000000000001.mobileprovision",
            ])
        }
    }
}

// MARK: --renew

@Suite("provision: --renew")
struct ProvisionRenewTests {
    /// The profile Xcode would have cached for `bundleId`.
    private func cached(
        _ bundleId: String = stremioId, uuid: String, team: String = Team.free, appId: String? = nil,
        platform: [String] = ["iOS"]
    ) throws -> String {
        try freeProfileXML(
            bundleId: bundleId, uuid: uuid, team: team, applicationIdentifier: appId ?? team + "." + bundleId,
            platform: platform)
    }

    @Test("it moves only sideload's own cached profile; decoys of other teams, apps, platforms and kinds stay")
    func movesOnlyOurs() async throws {
        let mine1 = try cached(uuid: "11111111-1111-1111-1111-111111111111")
        let mine2 = try cached(uuid: "22222222-2222-2222-2222-222222222222")
        let decoys: [String: String] = [
            "paid.mobileprovision": try cached(uuid: "33333333-3333-3333-3333-333333333333", team: Team.paid),
            "lab.mobileprovision": try cached("com.lab.WebDriverAgentRunner", uuid: "44444444-4444-4444-4444-444444444444"),
            "atv.mobileprovision": try cached("com.atvloadly.app", uuid: "55555555-5555-5555-5555-555555555555"),
            "apollo.mobileprovision": try cached(apolloId, uuid: "66666666-6666-6666-6666-666666666666"),
            "tv.mobileprovision": try cached(uuid: "77777777-7777-7777-7777-777777777777", platform: ["tvOS"]),
            "wild.mobileprovision": try cached(uuid: "88888888-8888-8888-8888-888888888888", appId: Team.free + ".*"),
            "prefix.mobileprovision": try cached(uuid: "99999999-9999-9999-9999-999999999999", appId: Team.paid + "." + stremioId),
            "garbage.mobileprovision": "not a plist",
            "notes.txt": mine1,
        ]
        var files: [String: String] = [
            "xcode-cache-1/mine1.mobileprovision": mine1, "xcode-cache-2/mine2.mobileprovision": mine2,
        ]
        for (name, content) in decoys { files["xcode-cache-1/" + name] = content }
        try await withProvisionWorld(cache: files) { (w: ProvisionWorld) async throws in
            // A symlink named like a profile, pointing at a matching one: never followed, never moved.
            try FileManager.default.createSymbolicLink(
                atPath: w.cacheDirs[1] + "/link.mobileprovision", withDestinationPath: w.cacheDirs[0] + "/mine1.mobileprovision")
            let out = await w.run(renew: true)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["cachedProfilesMoved"] == 2)
            #expect(out.data["cachedProfilesSkipped"] == 1, "the symlink was skipped and counted")

            // Gone from Xcode's folders, kept in tmp (0600), and gone before the build ran.
            #expect(!FileManager.default.fileExists(atPath: w.cacheDirs[1] + "/mine2.mobileprovision"))
            let seenAtBuild = try #require(w.cacheAtBuild.files)
            #expect(!seenAtBuild.contains { $0.hasSuffix("/mine2.mobileprovision") })
            let moved = listing(w.paths.tmp).filter { $0.hasPrefix("renewed-profile-") }.sorted()
            #expect(moved.count == 2)
            let contents = try moved.map { try String(contentsOfFile: w.paths.tmp + "/" + $0, encoding: .utf8) }
            #expect(Set(contents) == [mine1, mine2])
            for name in moved { #expect(modeOf(w.paths.tmp + "/" + name) == 0o600) }

            // Everything else is exactly where it was, byte for byte.
            for (name, content) in decoys {
                let path = w.cacheDirs[0] + "/" + name
                #expect(try String(contentsOfFile: path, encoding: .utf8) == content, "\(name) was left alone")
                #expect(seenAtBuild.contains(path), "\(name) was there at build time")
            }
            #expect(!FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/mine1.mobileprovision"), "mine1 moved")
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: w.cacheDirs[1] + "/link.mobileprovision")
            #expect(link.hasSuffix("mine1.mobileprovision"), "the symlink is untouched")
            #expect(seenAtBuild.contains(w.cacheDirs[1] + "/link.mobileprovision"))
        }
    }

    @Test("on a tvOS device it moves the tvOS profile of the shared App ID and not the iOS one")
    func tvosOnly() async throws {
        let ios = try cached(uuid: "11111111-1111-1111-1111-111111111111")
        let tv = try cached(uuid: "22222222-2222-2222-2222-222222222222", platform: ["tvOS"])
        try await withProvisionWorld(
            build: try tvScript(),
            cache: ["xcode-cache-1/ios.mobileprovision": ios, "xcode-cache-1/tv.mobileprovision": tv]
        ) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "stremio-tvos", device: "appletv", renew: true)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["cachedProfilesMoved"] == 1)
            #expect(FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/ios.mobileprovision"))
            #expect(!FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/tv.mobileprovision"))
        }
    }

    @Test("without --renew nothing in Xcode's folders is touched, and the output has no count")
    func notWithoutFlag() async throws {
        let mine = try cached(uuid: "11111111-1111-1111-1111-111111111111")
        try await withProvisionWorld(cache: ["xcode-cache-1/mine.mobileprovision": mine]) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.ok)
            #expect(out.data["cachedProfilesMoved"] == nil)
            #expect(try String(contentsOfFile: w.cacheDirs[0] + "/mine.mobileprovision", encoding: .utf8) == mine)
            #expect(w.cacheAtBuild.files == [w.cacheDirs[0] + "/mine.mobileprovision"])
            #expect(listing(w.paths.tmp).isEmpty)
            #expect(w.securityCalls.count == 1, "only the embedded profile was decoded")
        }
    }

    @Test("--renew without --yes moves nothing")
    func needsYes() async throws {
        let mine = try cached(uuid: "11111111-1111-1111-1111-111111111111")
        try await withProvisionWorld(cache: ["xcode-cache-1/mine.mobileprovision": mine]) { (w: ProvisionWorld) async throws in
            #expect(await w.run(renew: true, yes: false).errors.first?.code == "CONFIRM_REQUIRED")
            #expect(FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/mine.mobileprovision"))
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("a missing cache folder is fine, and with nothing to move the count is 0")
    func nothingToMove() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try FileManager.default.removeItem(atPath: w.cacheDirs[1])
            let out = await w.run(renew: true)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["cachedProfilesMoved"] == 0)
            #expect(out.data["cachedProfilesSkipped"] == 0)
        }
    }

    @Test("the default Services has no Xcode folders, so a test that forgets to set them cannot reach the real ones")
    func inertDefault() throws {
        let services = Services(
            runner: FakeRunner(), fs: FakeFileSystem.free(gb: 1), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: Paths(home: "/nonexistent"))
        #expect(services.xcodeProfileDirectories.isEmpty)
        #expect(
            Services.live(environment: ["SIDELOAD_HOME": "/nonexistent"]).xcodeProfileDirectories
                == XcodeManagedProfileSource.defaultDirectories(homeDirectory: NSHomeDirectory()))
    }

    @Test("running again straight away gets the same profile, which is not a renewal")
    func endToEnd() async throws {
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(uuid: "0F0F0F0F-1111-2222-3333-444444444444"))) { (w: ProvisionWorld) async throws in
            #expect(await w.run().ok)
            // Same profile again: not renewed.
            #expect(await w.run().errors.first?.code == "PROFILE_NOT_RENEWED")
        }
    }
}

// MARK: xcodebuild failures

@Suite("provision: build failures")
struct ProvisionFailureTests {
    /// No profile, no suspension, no pin and no marker left. `appIds` are the App IDs counted: xcodebuild ran, so
    /// the App ID is counted (conservatively high) unless it never started.
    private func assertNothingRecorded(_ w: ProvisionWorld, appIds: [String] = [stremioId]) throws {
        let ledger = try w.ledger()
        #expect(ledger.freeProfiles.isEmpty && ledger.freeSuspended == nil && ledger.freeProvisionInFlight == nil)
        #expect(ledger.freeAppIds.map(\.bundleId) == appIds)
        #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/profiles"))
        #expect(try w.config().freeTeamCertFp8() == nil)
    }

    @Test("the failures the owner can act on get their own code", arguments: [
        ("error: No Account for Team \"6ZU5Z6ZKK7\". Add a new account in Accounts settings.", "ACCOUNT_NOT_SIGNED_IN"),
        ("error: Your session has expired. Sign in again.", "ACCOUNT_NOT_SIGNED_IN"),
        ("error: Your team has no devices from which to generate a provisioning profile.", "DEVICE_NOT_REGISTERED"),
        ("error: Provisioning profile \"iOS Team Provisioning Profile\" doesn't include the currently selected device", "DEVICE_NOT_REGISTERED"),
        ("error: You have reached the maximum number of App IDs for this period.", "FREE_APP_ID_LIMIT"),
        ("error: Failed Registering Bundle Identifier: you cannot register more than 10 App IDs.", "FREE_APP_ID_LIMIT"),
        ("error: The device is locked. Unlock the device and try again.", "DEVICE_LOCKED"),
        ("error: No signing certificate \"Apple Development\" found", "FREE_IDENTITY_MISSING"),
    ])
    func classified(log: String, code: String) async throws {
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: log))) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == code)
            #expect(out.errors.first?.fix?.isEmpty == false)
            #expect(out.data["logTail"] == nil, "only an unknown failure carries a tail")
            #expect(out.data["identityChanged"] == nil)
            try assertNothingRecorded(w)
        }
    }

    @Test("a stdout-only message is read too")
    func stdoutRead() async throws {
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stdout: "error: No Account for Team"))) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "ACCOUNT_NOT_SIGNED_IN")
        }
    }

    @Test("an unregistered device points at --register-device unless it was already given")
    func registerAdvice() async throws {
        let failing = BuildScript(result: RunResult(code: 65, stderr: "error: Your team has no devices from which to generate a provisioning profile."))
        try await withProvisionWorld(build: failing) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.fix?.contains("--register-device --yes") == true)
            #expect(await w.run(register: true).errors.first?.fix?.contains("--register-device") == false)
        }
    }

    @Test("an App ID limit reported by Xcode shows the count we believe")
    func appIdLimitData() async throws {
        let failing = BuildScript(result: RunResult(code: 65, stderr: "error: maximum number of App IDs"))
        try await withProvisionWorld(build: failing) { (w: ProvisionWorld) async throws in
            try await seed(w) { $0.freeAppIds = [LedgerFreeAppId(bundleId: "io.github.dividedby.free.x", epochStart: daysFromNow(-1))] }
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_APP_ID_LIMIT")
            #expect(out.data["appIdsLast7Days"] == 1)
        }
    }

    @Test("timeout, output overflow and a spawn failure")
    func hardFailures() async throws {
        let cases: [(RunResult, String)] = [
            (RunResult(code: nil, timedOut: true), "BUILD_TIMEOUT"), (RunResult(code: nil, overflow: true), "OUTPUT_LIMIT"),
            (RunResult(code: nil, spawnError: "ENOENT"), "PROVISION_FAILED"),
        ]
        for (result, code) in cases {
            try await withProvisionWorld(build: BuildScript(result: result)) { (w: ProvisionWorld) async throws in
                #expect(await w.run().errors.first?.code == code)
                try assertNothingRecorded(w, appIds: [stremioId])
            }
        }
    }

    @Test("an unrecognised failure is PROVISION_FAILED with a redacted tail of the log")
    func unknown() async throws {
        let free = try freeKeychainCert()
        var lines = (1...30).map { "line \($0) of noise" }
        lines.append("error: build for \(udid1) and \(savedCoreId("1")) failed on Test iPhone")
        lines.append("signing with Apple Development: Test (TEST000002) for a@b.example in /Users/someone/x")
        lines.append(String(repeating: "x", count: 500))
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: lines.joined(separator: "\n")))) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            #expect(out.errors.first?.code == "PROVISION_FAILED")
            #expect(out.errors.first?.message.contains("65") == true)
            let tail = try #require(out.data["logTail"]?.string)
            let tailLines = tail.split(separator: "\n")
            #expect(tailLines.count == 20, "the last 20 lines")
            #expect(tailLines.allSatisfy { $0.count <= 300 })
            #expect(tail.contains("line 30 of noise") && !tail.contains("line 5 of noise"))
            for secret in [udid1, savedCoreId("1"), "Test iPhone", "TEST000002", free.commonName ?? "?", "a@b.example", "someone"] {
                #expect(!tail.contains(secret), "\(secret)")
            }
            try assertNothingRecorded(w)
        }
    }

    @Test("an App ID is counted from the moment the build is about to start, whatever happens to it")
    func appIdRecording() async throws {
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: "error: x"))) { (w: ProvisionWorld) async throws in
            _ = await w.run()
            #expect(try w.ledger().freeAppIds.map(\.bundleId) == [stremioId])
        }
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: nil, spawnError: "ENOENT"))) { (w: ProvisionWorld) async throws in
            _ = await w.run()
            #expect(try w.ledger().freeAppIds.map(\.bundleId) == [stremioId], "counted with the marker, before the build starts")
        }
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(getTaskAllow: false))) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "PROFILE_INVALID")
            #expect(try w.ledger().freeAppIds.map(\.bundleId) == [stremioId])
        }
    }
}

// MARK: ledger, config and CLI wiring

@Suite("provision: ledger, config and CLI")
struct ProvisionWiringTests {
    @Test("a ledger that never used the free team encodes exactly as before, and unknown keys survive")
    func ledgerCompat() throws {
        let plain = String(decoding: try LedgerStore.encode(Ledger()), as: UTF8.self)
        for key in ["freeAppIds", "freeProfiles", "freeSuspended"] { #expect(!plain.contains(key)) }
        let withFree = Ledger(
            freeAppIds: [LedgerFreeAppId(bundleId: stremioId, epochStart: testNow)],
            freeSuspended: LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: testNow, addedFp8: ["abcdef01"]),
            extra: ["future": "kept"])
        let round = try LedgerStore.parse(try LedgerStore.encode(withFree))
        #expect(round == withFree)
        #expect(round.extra["future"] == "kept")
        // An old ledger file (no free keys) loads with empty free state.
        let old = try LedgerStore.parse(Data(#"{"schema":1,"certificates":[],"profiles":[],"exports":[]}"#.utf8))
        #expect(old.freeAppIds.isEmpty && old.freeProfiles.isEmpty && old.freeSuspended == nil)
    }

    @Test("the budget arithmetic")
    func budgetMath() {
        let now = testNow
        func entries(_ ages: [Double]) -> [LedgerFreeAppId] {
            ages.enumerated().map { LedgerFreeAppId(bundleId: "b\($0.offset)", epochStart: now.addingTimeInterval(-$0.element * 86_400)) }
        }
        #expect(FreeAppIdBudget.live(entries([0, 6.999, 7, 7.001, 30]), now: now).count == 2, "under 7 days only")
        let none = FreeAppIdBudget.evaluate([], bundleId: "new", reserved: 4, now: now)
        #expect(none == .init(isNew: true, recent: 0, allowed: true))
        for (recent, allowed) in [(0, true), (4, true), (5, true), (6, false), (9, false)] {
            let e = entries(Array(repeating: 1, count: recent))
            #expect(FreeAppIdBudget.evaluate(e, bundleId: "new", reserved: 4, now: now).allowed == allowed, "recent \(recent)")
        }
        for (reserved, allowed) in [(0, true), (4, true), (5, false), (10, false)] {
            let e = entries(Array(repeating: 1, count: 5))
            #expect(FreeAppIdBudget.evaluate(e, bundleId: "new", reserved: reserved, now: now).allowed == allowed, "reserved \(reserved)")
        }
        let live = FreeAppIdBudget.evaluate(entries(Array(repeating: 1, count: 10)) + [LedgerFreeAppId(bundleId: "mine", epochStart: now)], bundleId: "mine", reserved: 4, now: now)
        #expect(!live.isNew && live.allowed && live.recent == 11)
        let expired = FreeAppIdBudget.evaluate([LedgerFreeAppId(bundleId: "mine", epochStart: now.addingTimeInterval(-7 * 86_400))], bundleId: "mine", reserved: 4, now: now)
        #expect(expired.isNew && expired.recent == 0)
        // Recording: a new epoch replaces an expired one; a live one is kept; old entries are dropped.
        let recorded = FreeAppIdBudget.recording(
            [LedgerFreeAppId(bundleId: "mine", epochStart: now.addingTimeInterval(-8 * 86_400)),
             LedgerFreeAppId(bundleId: "other", epochStart: now.addingTimeInterval(-86_400))],
            bundleId: "mine", now: now)
        #expect(recorded.map(\.bundleId) == ["other", "mine"])
        #expect(recorded.last?.epochStart == now)
        #expect(FreeAppIdBudget.recording(recorded, bundleId: "mine", now: now.addingTimeInterval(3600)) == recorded)
    }

    @Test("freeTeam config: defaults, validation and a pin that cannot be silently replaced")
    func freeTeamConfig() throws {
        var config = Config()
        #expect(try config.freeTeamCertFp8() == nil)
        #expect(try config.freeTeamReservedAppIds() == 4)
        try config.pinFreeTeamCert(fp8: "abcdef01")
        try config.pinFreeTeamCert(fp8: "abcdef01")
        #expect(try config.freeTeamCertFp8() == "abcdef01")
        #expect(throws: SideloadError.self) { try config.pinFreeTeamCert(fp8: "12345678") }
        #expect(try config.freeTeamCertFp8() == "abcdef01")
        // It survives the config file round trip.
        let reloaded = try Config.parse(try config.encoded())
        #expect(try reloaded.freeTeamCertFp8() == "abcdef01")
    }

    @Test("the CLI dispatches provision: usage, confirmation and flags")
    func cli() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            func invoke(_ argv: [String]) async -> Envelope { await run(argv: argv, services: w.services) }
            #expect(await invoke(["provision"]).errors.first?.code == "USAGE")
            #expect(await invoke(["provision", "--bogus"]).errors.first?.code == "USAGE")
            #expect(await invoke(["provision", "--app", "apollo", "--device", "iphone", "extra"]).errors.first?.code == "USAGE")
            #expect(await invoke(["provision", "--app", "apollo", "--device", "iphone"]).errors.first?.code == "CONFIRM_REQUIRED")
            #expect(await invoke(["provision", "--app", "apollo", "--device", "iphone", "--register-device"]).errors.first?.code == "CONFIRM_REQUIRED")
            #expect(await invoke(["provision", "--app=apollo", "--device=iphone", "--renew"]).errors.first?.code == "CONFIRM_REQUIRED")
            #expect(w.runner.calls.isEmpty)
            let help = await invoke(["help"])
            #expect(help.data["built"]?.array?.contains("provision") == true)
            #expect(help.data["usage"]?.array?.contains { $0.string?.hasPrefix("provision --app") == true } == true)
            let done = await invoke(["provision", "--app", "stremio-ios", "--device", "iphone", "--yes"])
            #expect(done.command == "provision")
        }
    }

    @Test("the CLI passes --register-device and --renew through")
    func cliFlags() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            _ = await run(argv: ["provision", "--app", "stremio-ios", "--device", "iphone", "--register-device", "--yes"], services: w.services)
            #expect(try #require(w.builds.first).args.contains("-allowProvisioningDeviceRegistration"))
        }
    }
}
