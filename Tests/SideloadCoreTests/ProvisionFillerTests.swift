import CryptoKit
import Foundation
import Testing

@testable import SideloadCore

// The `filler` app: `provision --app filler` stages the Xcode-signed carrier as the `freeSigned` build, so `install` and
// `slot` run without a fetched IPA. Fakes only (the xcodebuild, ditto and codesign of `withProvisionWorld`).

private let fillerSigned = "builds/signed/filler/iphone/Carrier.app"

private func fillerScript(_ tweak: (inout BuildScript) -> Void = { _ in }) throws -> BuildScript {
    var script = BuildScript(profile: try freeProfileXML(bundleId: fillerId))
    tweak(&script)
    return script
}

private func tmpEntries(_ w: ProvisionWorld) -> [String] { listing(w.paths.tmp) }

@Suite("provision: the filler app")
struct ProvisionFillerTests {
    @Test("provision stages the signed carrier, records freeProfiles and freeSigned, and counts one App ID")
    func stages() async throws {
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "filler")
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["bundleId"] == .string(fillerId))
            #expect(out.data["signed"] == .string(fillerSigned))
            #expect(out.data["appIdNew"] == true)

            let app = w.paths.home + "/" + fillerSigned
            #expect(FileManager.default.fileExists(atPath: app + "/Info.plist"))
            #expect(FileManager.default.fileExists(atPath: app + "/embedded.mobileprovision"))
            for dir in ["builds/signed", "builds/signed/filler", "builds/signed/filler/iphone"] {
                #expect(modeOf(w.paths.home + "/" + dir) == 0o700, "\(dir)")
            }

            let ledger = try w.ledger()
            let profile = try #require(ledger.freeProfiles.first { $0.id == "iphone/filler" })
            let signed = try #require(ledger.freeSigned.first { $0.id == "iphone/filler" })
            #expect(ledger.freeProfiles.count == 1 && ledger.freeSigned.count == 1)
            #expect(signed.bundleId == fillerId && signed.path == fillerSigned && signed.version == "1.0")
            #expect(signed.profileUuid == profile.profileUuid && signed.profileExpires == profile.expires)
            #expect(signed.certFp8 == profile.certFp8 && signed.signedAt == testNow)
            #expect(signed.strippedExtensions.isEmpty && signed.droppedEntitlements.isEmpty)
            let expected = SHA256.hash(data: Data("carrier executable".utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(signed.sha256Prefix == String(expected.prefix(8)))

            // One new App ID, for the filler's own bundle ID.
            #expect(ledger.freeAppIds.count == 1 && ledger.freeAppIds.first?.bundleId == fillerId)

            // The copy is made with ditto (it keeps the signature), through the runner, with a timeout.
            let ditto = try #require(w.runner.calls.first { $0.executable == "/usr/bin/ditto" })
            #expect(ditto.args.count == 2 && ditto.args[0].hasSuffix("/Debug-iphoneos/Carrier.app"))
            #expect(ditto.timeout > .zero)
            #expect(tmpEntries(w).filter { $0.hasPrefix("provision-") }.isEmpty, "the scratch folder is removed")
            let text = try out.printed().text
            #expect(!text.contains(savedUdid("1")) && !text.contains("Test iPhone"))
        }
    }

    @Test("a re-run replaces the staged app and keeps one entry of each kind")
    func rerun() async throws {
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            let old = LedgerFreeProfile(
                id: "iphone/filler", device: "iphone", deviceTail: Redactor.tail4(savedUdid("1")), app: "filler",
                bundleId: fillerId, profileUuid: "AAAAAAAA-1111-2222-3333-444444444444", created: daysFromNow(-5),
                expires: daysFromNow(2), certFp8: "00000000", file: "profiles/free/filler/iphone/x.mobileprovision")
            let oldSigned = LedgerFreeSigned(
                id: "iphone/filler", device: "iphone", app: "filler", bundleId: fillerId, version: "1.0",
                sha256Prefix: "deadbeef", profileUuid: old.profileUuid, profileExpires: old.expires, certFp8: "00000000",
                signedAt: daysFromNow(-5), path: fillerSigned, strippedExtensions: [], droppedEntitlements: [])
            try await w.services.ledgerStore.update {
                $0.freeProfiles = [old]
                $0.freeSigned = [oldSigned]
            }
            let previous = w.paths.home + "/" + fillerSigned
            try makeDirectories(previous, mode: 0o700)
            try Data("old".utf8).write(to: URL(fileURLWithPath: previous + "/Carrier"))

            let out = await w.run(app: "filler")
            #expect(out.ok, "\(out.errors)")
            let ledger = try w.ledger()
            #expect(ledger.freeProfiles.count == 1 && ledger.freeSigned.count == 1)
            #expect(ledger.freeSigned.first?.sha256Prefix != "deadbeef")
            #expect(ledger.freeSigned.first?.profileUuid == ledger.freeProfiles.first?.profileUuid)
            #expect(try String(contentsOfFile: previous + "/Carrier", encoding: .utf8) == "carrier executable")
            #expect(tmpEntries(w).filter { $0.hasPrefix("provision-") }.isEmpty)
        }
    }

    @Test("a failed free guard on the copy records and places nothing", arguments: [
        ("unsigned", "GUARD_FAILED"), ("paid team", "WRONG_TEAM"), ("other leaf", "GUARD_FAILED"),
    ])
    func guardFailure(fault: String, code: String) async throws {
        let script = try fillerScript { s in
            switch fault {
            case "unsigned": s.signedTeam = nil
            case "paid team": s.signedTeam = Team.id
            default: s.leaf = Data("not the pinned certificate".utf8)
            }
        }
        try await withProvisionWorld(build: script) { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "filler")
            #expect(out.errorCodes == [code], "\(fault): \(out.errors)")
            try expectNothingStaged(w)
        }
    }

    @Test("a copy that fails or a build with no executable records and places nothing")
    func copyFailures() async throws {
        try await withProvisionWorld(build: try fillerScript { $0.dittoCode = 1 }) { (w: ProvisionWorld) async throws in
            #expect((await w.run(app: "filler")).errorCodes == ["BUILD_PRODUCT_MISSING"])
            try expectNothingStaged(w)
        }
        try await withProvisionWorld(build: try fillerScript { $0.omitExecutable = true }) { (w: ProvisionWorld) async throws in
            #expect((await w.run(app: "filler")).errorCodes == ["BUILD_PRODUCT_MISSING"])
            try expectNothingStaged(w)
        }
    }

    @Test("a failed final ledger write puts the previous staged app back")
    func ledgerFailureRestores() async throws {
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            let previous = w.paths.home + "/" + fillerSigned
            try makeDirectories(previous, mode: 0o700)
            try Data("old".utf8).write(to: URL(fileURLWithPath: previous + "/Carrier"))
            var hooks = ProvisionHooks()
            hooks.checkpoint = { point in
                if point == .finalLedgerWrite { throw SideloadError("LEDGER_WRITE_FAILED", "simulated") }
            }
            let out = await ProvisionCommand.run(
                w.services, ProvisionOptions(app: "filler", device: "iphone", yes: true), hooks: hooks)
            #expect(out.errorCodes == ["LEDGER_WRITE_FAILED"])
            #expect(try String(contentsOfFile: previous + "/Carrier", encoding: .utf8) == "old")
            #expect(try w.ledger().freeSigned.isEmpty && w.ledger().freeProfiles.isEmpty)
            #expect(tmpEntries(w).filter { $0.hasPrefix("provision-") }.isEmpty)
        }
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            var hooks = ProvisionHooks()
            hooks.checkpoint = { point in
                if point == .finalLedgerWrite { throw SideloadError("LEDGER_WRITE_FAILED", "simulated") }
            }
            _ = await ProvisionCommand.run(
                w.services, ProvisionOptions(app: "filler", device: "iphone", yes: true), hooks: hooks)
            #expect(!FileManager.default.fileExists(atPath: w.paths.home + "/" + fillerSigned), "a fresh placement is taken back")
        }
    }

    @Test("the other apps stage nothing and print no signed key")
    func othersUnchanged() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let out = await w.run(app: "stremio-ios")
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["signed"] == nil)
            #expect(!w.runner.calls.contains { $0.executable == "/usr/bin/ditto" })
            #expect(try w.ledger().freeSigned.isEmpty)
        }
    }

    @Test("the filler needs an iOS device, and its bundle ID is under the allowlisted namespace")
    func platformAndNamespace() async throws {
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            #expect((await w.run(app: "filler", device: "appletv")).errorCodes == ["PLATFORM_MISMATCH"])
            #expect(w.runner.calls.isEmpty)
            #expect(Config.isFreeBundleId(fillerId, prefix: carrierPrefix))
        }
    }

    @Test("the filler and the Stremio apps use separate App IDs")
    func appIdBudget() async throws {
        try await withProvisionWorld(build: try fillerScript()) { (w: ProvisionWorld) async throws in
            _ = await w.run(app: "filler")
            let ids = try w.ledger().freeAppIds.map(\.bundleId)
            #expect(ids == [fillerId])
            #expect(ProvisionApp.filler.suffix != ProvisionApp.stremioIOS.suffix)
            #expect(ProvisionApp.stremioIOS.suffix == ProvisionApp.stremioTVOS.suffix, "the two Stremio apps still share one App ID")
        }
    }

    private func expectNothingStaged(_ w: ProvisionWorld, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let ledger = try w.ledger()
        #expect(ledger.freeSigned.isEmpty && ledger.freeProfiles.isEmpty, sourceLocation: sourceLocation)
        #expect(
            !FileManager.default.fileExists(atPath: w.paths.home + "/builds/signed/filler"), sourceLocation: sourceLocation)
        #expect(listing(w.paths.freeProfiles).isEmpty, "no profile file is stored", sourceLocation: sourceLocation)
        #expect(tmpEntries(w).filter { $0.hasPrefix("provision-") }.isEmpty, sourceLocation: sourceLocation)
    }
}

@Suite("the filler through install, sign and device lendable")
struct FillerCommandTests {
    @Test("install treats the provision-signed filler like any signed app and counts it as a managed slot")
    func installs() async throws {
        try await withInstallWorld(app: .filler) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(w.installs.map(\.app) == ["filler"])
            #expect(w.runner.deviceApps[carrierPrefix + ".free.filler"] != nil)
            try w.expectClean(out)
        }
    }

    @Test("a full device refuses the filler with FREE_APP_LIMIT before the install runs")
    func fullDevice() async throws {
        try await withInstallWorld(app: .filler, script: DeviceScript(initial: [apolloId: true]), reserved: 2) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(w.runner.installCalls.isEmpty)
            #expect(w.installs.isEmpty)
        }
    }

    @Test("an installed filler uses a slot: a second app is refused when the rest are taken")
    func fillerUsesSlot() async throws {
        try await withInstallWorld(
            app: .stremioIOS, alsoSigned: [.filler], script: DeviceScript(initial: [apolloId: true]), reserved: 1
        ) { w in
            #expect(await w.install(app: "filler").ok)
            let out = await w.install(app: "stremio-ios")
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
        }
    }

    @Test("an unsigned filler points the owner to provision, not sign")
    func notSignedFix() async throws {
        try await withInstallWorld(app: .filler, signed: false) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["NOT_SIGNED"])
            let fix = try #require(out.errors.first?.fix)
            #expect(fix.contains("provision --app filler") && !fix.contains("sideload sign"))
        }
    }

    @Test("no failure fix for the filler mentions `sideload sign`: install says provision only", arguments: [
        "not signed", "expired", "wrong team",
    ])
    func installFixes(fault: String) async throws {
        try await withInstallWorld(
            app: .filler, signed: fault != "not signed", profileDays: fault == "expired" ? -1 : 5,
            embeddedTeam: fault == "wrong team" ? "ZZZZZZZZZZ" : Team.free
        ) { w in
            let out = await w.install()
            #expect(!out.ok && !out.errorCodes.isEmpty, "\(fault)")
            let fix = try #require(out.errors.first?.fix)
            #expect(fix.contains("sideload provision --app filler --device iphone --yes"), "\(fault): \(fix)")
            #expect(!fix.contains("sideload sign"), "\(fault): \(fix)")
        }
    }

    @Test("no failure fix for the filler mentions `sideload sign`: a failed slot return says provision only", arguments: [
        "not signed", "expired", "wrong team",
    ])
    func slotReturnFixes(fault: String) async throws {
        let lent = LedgerLent(app: "filler", device: "iphone", to: "lab", since: daysFromNow(-1))
        try await withInstallWorld(
            app: .filler, lendable: "filler", signed: fault != "not signed", profileDays: fault == "expired" ? -1 : 5,
            embeddedTeam: fault == "wrong team" ? "ZZZZZZZZZZ" : Team.free, ledger: { $0.lent = [lent] }
        ) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"], "\(fault): \(out.errors)")
            let fix = try #require(out.errors.first?.fix)
            #expect(fix.contains("sideload provision --app filler --device iphone --yes"), "\(fault): \(fix)")
            #expect(!fix.contains("sideload sign"), "\(fault): \(fix)")
        }
    }

    @Test("an app that sign handles still gets provision, then sign")
    func otherAppsKeepSign() async throws {
        try await withInstallWorld(signed: false) { w in
            let fix = try #require((await w.install()).errors.first?.fix)
            #expect(fix.contains("sideload sign --app stremio-ios --device iphone --yes"))
        }
        try await withInstallWorld(embeddedTeam: "ZZZZZZZZZZ") { w in
            let fix = try #require((await w.install()).errors.first?.fix)
            #expect(fix.contains("sideload provision --app stremio-ios") && fix.contains("sideload sign --app stremio-ios"))
        }
    }

    @Test("sign usage text does not offer the filler, and sign --app filler is USAGE")
    func signUsage() async throws {
        try await withSignWorld { w in
            let missing = await SignCommand.run(w.services, SignOptions(app: nil, device: "iphone", yes: true))
            #expect(missing.errors.first?.fix?.contains("filler") == false)
            let unknown = await SignCommand.run(w.services, SignOptions(app: "nonsense", device: "iphone", yes: true))
            #expect(unknown.errors.first?.fix?.contains("filler") == false)
        }
    }

    @Test("sign --app filler is USAGE and runs nothing")
    func signRefused() async throws {
        try await withSignWorld { w in
            let out = await w.run(app: "filler")
            #expect(out.errorCodes == ["USAGE"])
            #expect(out.errors.first?.message.contains("provision") == true)
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("device lendable accepts the filler (owner-only) and nothing is lendable by default")
    func lendable() async throws {
        try await withInstallWorld(app: .filler) { w in
            #expect(w.device("iphone")?.lendableApp == nil)
            let noYes = await DeviceCommand.run(
                w.services, DeviceOptions(sub: "lendable", alias: "iphone", app: "filler", yes: false))
            #expect(!noYes.ok && w.device("iphone")?.lendableApp == nil)
            let set = await DeviceCommand.run(
                w.services, DeviceOptions(sub: "lendable", alias: "iphone", app: "filler", yes: true))
            #expect(set.ok, "\(set.errors)")
            #expect(w.device("iphone")?.lendableApp == "filler")
        }
    }

    @Test("slot lend and return work for the filler")
    func slotRoundTrip() async throws {
        let script = DeviceScript(initial: [carrierPrefix + ".free.filler": true])
        try await withInstallWorld(app: .filler, script: script, lendable: "filler") { w in
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.ok && json(lend)["app"] == "filler" && json(lend)["freed"] == 1, "\(lend.errors)")
            let back = await w.slot("return", device: "iphone")
            #expect(back.ok && json(back)["reinstalled"] == true, "\(back.errors)")
        }
    }
}
