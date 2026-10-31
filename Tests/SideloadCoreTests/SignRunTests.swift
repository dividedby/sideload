import Foundation
import Testing

@testable import SideloadCore

// The whole `sign` pipeline over synthetic IPAs that mirror the three real apps: the real `ditto`, `lipo`, `vtool` and
// ad hoc `codesign` do the work (the pinned identity's SHA-1 is carried out ad hoc), so the signed result can be
// read back with the same tools. See SignTestSupport.swift for what is scripted.

private func code(_ envelope: Envelope) -> String? { envelope.errors.first?.code }

private func strings(_ value: JSONValue?) -> [String] { value?.array?.compactMap(\.string) ?? [] }

private func warningCodes(_ envelope: Envelope) -> [String] {
    (envelope.data["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
}

/// Nothing may have been placed or recorded.
private func expectNothingKept(_ w: SignWorld, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(!FileManager.default.fileExists(atPath: w.signedApp), sourceLocation: sourceLocation)
    #expect(try w.ledger().freeSigned.isEmpty, sourceLocation: sourceLocation)
    #expect(w.leftovers.isEmpty, "scratch folders left: \(w.leftovers)", sourceLocation: sourceLocation)
}

@Suite("sign: Stremio iOS (one WidgetKit appex)")
struct SignStremioIOSTests {
    @Test("signs, strips the widget, rewrites the bundle ID and reduces the entitlements")
    func success() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.command == "sign" && out.errorCodes.isEmpty)
            #expect(out.data["app"] == "stremio-ios" && out.data["device"] == "iphone" && out.data["bundleId"] == .string(stremioId))
            #expect(out.data["version"] == "1.9.6b142")
            #expect(out.data["signed"] == .string(w.relativeSigned))
            #expect(out.data["profile"]?["uuid"] == .string(signProfileUUID) && out.data["profile"]?["daysLeft"] == 5)
            #expect(out.data["deviceOS"]?["source"] == "devicectl list devices" && out.data["deviceOS"]?["version"] == "26.0")

            // The one widget, with what it declared.
            let stripped = try #require(out.data["stripped"]?.array)
            #expect(stripped.count == 1)
            #expect(stripped[0]["path"] == "PlugIns/StremioDownloadsWidget.appex")
            #expect(stripped[0]["bundleId"] == "com.stremio.pal.downloads-widget")
            #expect(stripped[0]["extensionPoint"] == "com.apple.widgetkit-extension")
            #expect(strings(stripped[0]["entitlementKeys"]) == ["com.apple.security.application-groups"])
            #expect(strings(stripped[0]["appGroups"]) == ["group.com.stremio.pal"])

            // A group only the stripped extension used is information, not a warning.
            #expect(strings(out.data["appGroups"]?["declaredByApp"]) == [])
            #expect(strings(out.data["appGroups"]?["onlyInStrippedExtensions"]) == ["group.com.stremio.pal"])
            #expect(!warningCodes(out).contains("APP_GROUP_DROPPED"))
            #expect(strings(out.data["droppedEntitlements"]) == ["aps-environment", "com.apple.developer.associated-domains"])

            // The bundle on disk.
            let app = w.signedApp
            #expect(try plistDictionary(app + "/Info.plist")["CFBundleIdentifier"] as? String == stremioId)
            let names = tree(app)
            #expect(!names.contains { $0.lowercased().hasSuffix(".appex") } && !names.contains("PlugIns"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: app + "/embedded.mobileprovision")) == Data(contentsOf: URL(fileURLWithPath: profileFile(w, uuid: signProfileUUID))))
            #expect(names.contains("_CodeSignature"))

            // Signed with the entitlements the free profile grants and nothing else.
            let ent = try await signedEntitlements(app)
            #expect(Set(ent.keys) == ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"])
            #expect(ent["application-identifier"] as? String == Team.free + "." + stremioId)
            #expect(ent["com.apple.developer.team-identifier"] as? String == Team.free)
            #expect(ent["get-task-allow"] as? Bool == true, "the profile's value; the original's false is not copied")
            #expect(ent["keychain-access-groups"] as? [String] == [Team.free + "." + stremioId])

            // Independently verified, and nothing left behind.
            let verify = await PosixSpawnRunner().run(
                CommandSpec(executable: "/usr/bin/codesign", args: ["--verify", "--strict", "--deep", app], timeout: .seconds(60)))
            #expect(verify.code == 0, "\(verify.stderr)")
            #expect(w.leftovers.isEmpty)
        }
    }

    @Test("the signing order: nested code innermost first, the app with its entitlements, then verify; only the pinned SHA-1")
    func order() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            #expect(await w.run().ok)
            let calls = w.runner.codesignCalls.map(\.args)
            let signing = calls.filter { $0.contains("-s") }
            #expect(signing.count == 3)
            for args in signing {
                #expect(args.starts(with: ["-f", "-s", w.pinnedSha1, "--timestamp=none"]), "\(args)")
            }
            // The two nested items, then the app.
            #expect(signing[0].count == 5 && signing[0][4].hasSuffix("/Frameworks/Core.framework"))
            #expect(signing[1].count == 5 && signing[1][4].hasSuffix("/Frameworks/libhelper.dylib"))
            #expect(signing[2].count == 8 && signing[2][4] == "--entitlements" && signing[2][5].hasSuffix("/entitlements.plist"))
            #expect(signing[2][6] == "--generate-entitlement-der" && signing[2][7].hasSuffix("/Stremio.app"))
            // Verification follows the last signature; the guard's reads follow that.
            let verify = try #require(calls.firstIndex { $0.first == "--verify" })
            #expect(calls[verify].dropLast() == ["--verify", "--strict", "--deep"])
            let lastSign = try #require(calls.lastIndex { $0.contains("-s") })
            #expect(verify == lastSign + 1)
            #expect(calls.firstIndex { $0.first == "-dvv" }.map { $0 > verify } == true)
        }
    }

    @Test("the guard runs on the result and its reads are in the log; no identity name is ever passed to codesign")
    func guardAndNames() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            #expect(await w.run().ok)
            let codesign = w.runner.codesignCalls.map(\.args)
            #expect(codesign.contains { $0.first == "-dvv" })
            #expect(codesign.contains { $0.contains { $0.hasPrefix("--extract-certificates=") } })
            #expect(w.runner.calls.contains { $0.executable == "/usr/bin/security" && $0.args.prefix(3) == ["cms", "-D", "-i"] })
            for args in w.runner.signingArgs {
                let value = try #require(args.firstIndex(of: "-s").map { args[$0 + 1] })
                #expect(value == w.pinnedSha1 && value.count == 40)
            }
            // Every call is an argument array with a timeout (CommandSpec cannot be built without one).
            #expect(w.runner.calls.allSatisfy { !$0.args.joined().contains("Apple Development") })
        }
    }

    @Test("the ledger records the signed app; the file is placed under 0700 folders")
    func recorded() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            #expect(await w.run().ok)
            let ledger = try w.ledger()
            #expect(ledger.freeSigned.count == 1)
            let entry = try #require(ledger.freeSigned.first)
            #expect(entry.id == "iphone/stremio-ios" && entry.device == "iphone" && entry.app == "stremio-ios")
            #expect(entry.bundleId == stremioId && entry.version == "1.9.6b142")
            #expect(entry.sha256Prefix == String(w.sha256.prefix(8)))
            #expect(entry.profileUuid == signProfileUUID && entry.certFp8 == LedgerSync.fp8(w.pinnedSha1))
            #expect(entry.signedAt == testNow && entry.profileExpires == daysFromNow(5))
            #expect(entry.path == w.relativeSigned)
            #expect(entry.strippedExtensions == [LedgerStrippedExtension(path: "PlugIns/StremioDownloadsWidget.appex", bundleId: "com.stremio.pal.downloads-widget")])
            #expect(entry.droppedEntitlements == ["aps-environment", "com.apple.developer.associated-domains"])
            // The provision records are untouched.
            #expect(ledger.freeProfiles.count == 1)
            for part in ["builds/signed", "builds/signed/stremio-ios", "builds/signed/stremio-ios/iphone"] {
                #expect(modeOf(w.paths.home + "/" + part) == 0o700, "\(part)")
            }
            // The ledger holds neither a device ID nor a name.
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: w.paths.ledger)), as: UTF8.self)
            let signedPart = try #require(text.range(of: "freeSigned"))
            let tail = String(text[signedPart.lowerBound...])
            #expect(!tail.contains(savedUdid("1")) && !tail.contains("Test iPhone") && !tail.contains("Apple Development"))
        }
    }

    @Test("the printed object carries no UDID, CoreDevice ID, device or identity name, and no profile content")
    func hygiene() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            let out = await w.run()
            #expect(out.ok)
            let text = try out.printed().text
            for forbidden in [
                savedUdid("1"), savedCoreId("1"), "Test iPhone", "Test Apple TV", "Apple Development", "TEST000002",
                "ProvisionedDevices", "DeveloperCertificates", w.pinnedSha1, "/Users/",
            ] {
                #expect(!text.contains(forbidden), "printed output contains \(forbidden)")
            }
            #expect(!text.contains(w.paths.home), "no absolute path")
            // One object only.
            #expect(text.filter { $0 == "\n" }.count == 1)
        }
    }

    @Test("signing again replaces the signed app in one swap: one ledger entry, the old bundle gone, no scratch left")
    func resign() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            #expect(await w.run().ok)
            let marker = w.signedApp + "/from-the-first-run"
            #expect(FileManager.default.createFile(atPath: marker, contents: Data()))
            let second = await w.run()
            #expect(second.ok, "\(second.errors)")
            #expect(!FileManager.default.fileExists(atPath: marker))
            let signed = try w.ledger().freeSigned
            #expect(signed.count == 1)
            #expect(listing(w.paths.home + "/builds/signed/stremio-ios/iphone") == ["Stremio.app"])
            #expect(w.leftovers.isEmpty)
        }
    }
}

@Suite("sign: Stremio tvOS (no appex)")
struct SignStremioTVOSTests {
    @Test("signs for the Apple TV with the shared free ID and the tvOS profile; nothing to strip")
    func success() async throws {
        try await withSignWorld(app: .stremioTVOS) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["device"] == "appletv" && out.data["bundleId"] == .string(stremioId))
            #expect(out.data["stripped"] == [])
            #expect(out.data["signed"] == "builds/signed/stremio-tvos/appletv/Stremio.app")
            #expect(try plistDictionary(w.signedApp + "/Info.plist")["CFBundleIdentifier"] as? String == stremioId)
            #expect(strings(out.data["droppedEntitlements"]) == [])
            let ent = try await signedEntitlements(w.signedApp)
            #expect(Set(ent.keys) == ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"])
            #expect(!warningCodes(out).contains("APP_GROUP_DROPPED"))
        }
    }

    @Test("the iOS and tvOS builds of the shared ID are kept apart by app and device")
    func apart() async throws {
        try await withSignWorld(app: .stremioTVOS) { w in
            #expect(await w.run().ok)
            let ids = try w.ledger().freeSigned.map(\.id)
            #expect(ids == ["appletv/stremio-tvos"])
            #expect(!FileManager.default.fileExists(atPath: w.paths.signedBuilds + "/stremio-ios"))
        }
    }
}

@Suite("sign: Apollo (an app group, no appex)")
struct SignApolloTests {
    @Test("the app group is dropped with the APP_GROUP_DROPPED warning, which is not a stop")
    func appGroup() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerUnapproved) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            let warnings = out.data["warnings"]?.array ?? []
            let group = try #require(warnings.first { $0["code"] == "APP_GROUP_DROPPED" })
            #expect(group["message"]?.string?.contains("group.com.christianselig.apollo") == true)
            #expect(strings(out.data["appGroups"]?["declaredByApp"]) == ["group.com.christianselig.apollo"])
            #expect(out.data["stripped"] == [])
            #expect(strings(out.data["droppedEntitlements"]) == ["com.apple.developer.associated-domains", "com.apple.security.application-groups"])
            #expect(out.data["bundleId"] == .string(apolloId))
            #expect(out.data["signed"] == "builds/signed/apollo/iphone/Apollo.app")

            let ent = try await signedEntitlements(w.signedApp)
            #expect(ent["com.apple.security.application-groups"] == nil)
            #expect(ent["keychain-access-groups"] as? [String] == [Team.free + "." + apolloId])
            #expect(ent["get-task-allow"] as? Bool == true, "written from the profile although the original had none")

            // The newest approved version was signed, and a newer unapproved one is mentioned.
            #expect(out.data["version"] == "1.0.0")
            #expect(warningCodes(out).contains("NEWER_VERSION_NOT_APPROVED"))
        }
    }
}

@Suite("sign: a chosen version")
struct SignVersionTests {
    @Test("SignOptions.version signs exactly that version even when a newer one is approved; nil keeps the newest")
    func chosenVersion() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerApproved) { w in
            let newest = await w.run()
            #expect(newest.ok, "\(newest.errors)")
            #expect(newest.data["version"] == .string(w.app.version))

            let chosen = await w.run(version: "1.0.0")
            #expect(chosen.ok, "\(chosen.errors)")
            #expect(chosen.data["version"] == "1.0.0")
            let signed = try w.ledger().freeSigned.first { $0.id == w.key }
            #expect(signed?.version == "1.0.0")
            // A version that was asked for is not the "newest approved" one, so there is nothing to warn about.
            #expect(!warningCodes(chosen).contains("NEWER_VERSION_NOT_APPROVED"))
        }
    }

    @Test("a version that is not approved, or not fetched, is NOT_APPROVED and nothing is signed")
    func notApproved() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerUnapproved) { w in
            for version in [w.app.version, "9.9.9"] {
                let out = await w.run(version: version)
                #expect(out.errors.first?.code == "NOT_APPROVED", "\(version)")
            }
            #expect(w.runner.signingArgs.isEmpty)
            let signed = try w.ledger().freeSigned
            #expect(signed.isEmpty)
        }
    }

    @Test("an approved version whose file `clean` pruned is IPA_PRUNED and nothing is signed")
    func pruned() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerApproved) { w in
            let store = ManifestStore(paths: w.paths)
            var manifest = try store.load()
            let index = try #require(manifest.entries.firstIndex { $0.version == "1.0.0" })
            manifest.entries[index].prunedAt = testNow
            try store.save(manifest)
            let out = await w.run(version: "1.0.0")
            #expect(out.errors.first?.code == "IPA_PRUNED")
            #expect(w.runner.signingArgs.isEmpty)
        }
    }

    @Test("an empty --version is USAGE, before anything is read")
    func empty() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerApproved) { w in
            let out = await w.run(version: "")
            #expect(out.errors.first?.code == "USAGE" && out.errors.first?.message == "--version needs a version.")
            #expect(w.runner.signingArgs.isEmpty)
        }
    }

    private func installed(_ version: String) -> (inout Ledger) -> Void {
        { ledger in
            var record = menuInstall("iphone", "apollo", days: 5)
            record.version = version
            ledger.installs = [record]
        }
    }

    @Test("a version older than the installed one signs with the OLDER_THAN_INSTALLED warning; it is never a block")
    func olderWarning() async throws {
        try await withSignWorld(app: .apollo, manifest: .newerApproved, ledger: installed("3.9.0")) { w in
            let out = await w.run(version: "1.0.0")
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["version"] == "1.0.0")
            let warnings = out.data["warnings"]?.array ?? []
            let older = try #require(warnings.first { $0["code"]?.string == "OLDER_THAN_INSTALLED" })
            let message = try #require(older["message"]?.string)
            #expect(message.hasPrefix("Signing 1.0.0, older than the installed 3.9.0;"))
            #expect(message.contains("`install` goes over it and keeps the app's data") && message.contains("iOS may refuse an older build"))
            #expect(older["fix"]?.string?.isEmpty == false)
            let signed = try w.ledger().freeSigned.first { $0.id == w.key }
            #expect(signed?.version == "1.0.0")
        }
    }

    @Test("the same or a newer version: no warning")
    func noWarning() async throws {
        for (installed, version) in [("3.9.0", "3.9.0"), ("1.0.0", "3.9.0")] {
            try await withSignWorld(app: .apollo, manifest: .newerApproved, ledger: self.installed(installed)) { w in
                let out = await w.run(version: version)
                #expect(out.ok, "\(out.errors)")
                #expect(!warningCodes(out).contains("OLDER_THAN_INSTALLED"), "\(installed) -> \(version)")
            }
        }
    }
}

@Suite("sign: every kind of extension")
struct SignStripEverythingTests {
    @Test("a nested appex, Extensions/ and a Watch app with its own appex are all removed and the result verifies")
    func everything() async throws {
        try await withSignWorld(app: .stremioIOS, variant: .everything) { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            let paths = (out.data["stripped"]?.array ?? []).compactMap { $0["path"]?.string }
            #expect(paths == [
                "Extensions/Kit.appex", "Frameworks/Core.framework/PlugIns/Deep.appex", "PlugIns/StremioDownloadsWidget.appex",
                "Watch/Watch.app",
            ])
            let names = tree(w.signedApp)
            #expect(!names.contains { $0.lowercased().hasSuffix(".appex") })
            #expect(!names.contains("Watch") && !names.contains("Extensions") && !names.contains("PlugIns"))
            let entry = try #require(try w.ledger().freeSigned.first)
            #expect(entry.strippedExtensions.map(\.path) == paths)
            #expect(entry.strippedExtensions.first { $0.path == "Watch/Watch.app" }?.bundleId == "com.stremio.pal.watchkitapp")
        }
    }
}

@Suite("sign: disk and ledger agree")
struct SignRollbackTests {
    private let failingLedger = SignHooks(beforeLedgerWrite: {
        throw SideloadError("LEDGER_WRITE_FAILED", "ledger.json could not be written.")
    })

    @Test("a new placement whose ledger write fails is taken back out: nothing on disk, nothing recorded, placed:false")
    func newPlacement() async throws {
        try await withSignWorld(app: .apollo) { w in
            let out = await w.run(hooks: failingLedger)
            #expect(code(out) == "LEDGER_WRITE_FAILED")
            #expect(out.data["placed"] == false && out.data["recorded"] == nil && out.data["signedPath"] == nil)
            #expect(out.errors.first?.fix?.contains("sign") == true)
            try expectNothingKept(w)
            // Nothing was lost: the same run, with a working ledger, succeeds.
            #expect(await w.run().ok)
            #expect(FileManager.default.fileExists(atPath: w.signedApp))
        }
    }

    @Test("a swap whose ledger write fails is swapped back: the previous signed app is in place and its record untouched")
    func swapRestored() async throws {
        try await withSignWorld(app: .apollo) { w in
            #expect(await w.run().ok)
            let marker = w.signedApp + "/from-the-first-run"
            #expect(FileManager.default.createFile(atPath: marker, contents: Data()))
            let before = try w.ledger().freeSigned

            let out = await w.run(hooks: failingLedger)
            #expect(code(out) == "LEDGER_WRITE_FAILED" && out.data["placed"] == false)
            #expect(FileManager.default.fileExists(atPath: marker), "the old bundle is back")
            #expect(try w.ledger().freeSigned == before)
            #expect(w.leftovers.isEmpty)
            #expect(listing(w.paths.home + "/builds/signed/apollo/iphone") == ["Apollo.app"])
        }
    }

    @Test("when the undo itself fails the app stays in place and the error says so: signedPath relative, recorded:false")
    func restoreFails() async throws {
        try await withSignWorld(app: .apollo) { w in
            var hooks = failingLedger
            hooks.restore = { _, _, _ in false }
            let out = await w.run(hooks: hooks)
            #expect(code(out) == "LEDGER_WRITE_FAILED")
            #expect(out.data["recorded"] == false && out.data["placed"] == true)
            #expect(out.data["signedPath"] == .string(w.relativeSigned))
            #expect(FileManager.default.fileExists(atPath: w.signedApp))
            #expect(try w.ledger().freeSigned.isEmpty)
            let text = try out.printed().text
            #expect(!text.contains(w.paths.home), "relative path only")
            // Running again records it.
            #expect(await w.run().ok)
            #expect(try w.ledger().freeSigned.count == 1)
        }
    }

    @Test("the real undo, both ways, on plain directories")
    func realRestore() throws {
        let dir = try makeTempDir().path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        for name in ["scratch", "dest"] { try fm.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true) }
        // A new placement: dest holds the new app, scratch has no app.
        try fm.createDirectory(atPath: dir + "/dest/App.app", withIntermediateDirectories: true)
        #expect(SignCommand.restore(swapped: false, scratchApp: dir + "/scratch/App.app", destination: dir + "/dest/App.app"))
        #expect(listing(dir + "/dest").isEmpty && listing(dir + "/scratch") == ["App.app"])
        // A swap: scratch holds the old app, dest the new one.
        try fm.createDirectory(atPath: dir + "/dest/App.app", withIntermediateDirectories: true)
        fm.createFile(atPath: dir + "/dest/App.app/new", contents: nil)
        fm.createFile(atPath: dir + "/scratch/App.app/old", contents: nil)
        #expect(SignCommand.restore(swapped: true, scratchApp: dir + "/scratch/App.app", destination: dir + "/dest/App.app"))
        #expect(listing(dir + "/dest/App.app") == ["old"] && listing(dir + "/scratch/App.app") == ["new"])
        // Nothing to restore from fails rather than pretending.
        #expect(!SignCommand.restore(swapped: true, scratchApp: dir + "/missing", destination: dir + "/dest/App.app"))
    }
}

@Suite("sign: failures after the archive is open")
struct SignWorkFailureTests {
    @Test("a watch app the stripper does not look for is found by the re-walk -> EXTENSION_REMAINS, nothing signed")
    func extensionRemains() async throws {
        try await withSignWorld(app: .stremioIOS, variant: .hiddenWatch) { w in
            let out = await w.run()
            #expect(code(out) == "EXTENSION_REMAINS")
            #expect(strings(out.data["remaining"]) == ["Frameworks/Core.framework/Hidden.app"])
            #expect(w.runner.signingArgs.isEmpty)
            try expectNothingKept(w)
        }
    }

    @Test("nested code sign does not handle (an XPC service) is refused by its relative path, before anything is signed")
    func nestedCodeRefused() async throws {
        try await withSignWorld(app: .stremioIOS, variant: .xpc) { w in
            let out = await w.run()
            #expect(code(out) == "NESTED_CODE_UNSUPPORTED")
            #expect(strings(out.data["nestedCode"]) == ["XPCServices/Helper.xpc"])
            #expect(out.errors.first?.message.contains("XPCServices/Helper.xpc") == true)
            #expect(w.runner.signingArgs.isEmpty)
            try expectNothingKept(w)
        }
    }

    @Test("an app that gives no minimum OS anywhere fails closed -> MIN_OS_UNKNOWN, nothing signed")
    func minOSUnknown() async throws {
        try await withSignWorld(app: .apollo, variant: .noMinOS, minOS: nil) { w in
            let out = await w.run()
            #expect(code(out) == "MIN_OS_UNKNOWN")
            #expect(w.runner.signingArgs.isEmpty)
            try expectNothingKept(w)
        }
    }

    @Test("codesign failing on the nested items, the app or the verification is CODESIGN_FAILED and nothing is kept")
    func codesignFails() async throws {
        let cases: [(SignScript, String)] = [
            (SignScript(signingFailure: RunResult(code: 1, stderr: "boom /Users/someone/x")), "nested"),
            (SignScript(failAfterSigningCalls: 2), "app"),
        ]
        for (script, step) in cases {
            try await withSignWorld(app: .apollo, script: script) { w in
                let out = await w.run()
                #expect(code(out) == "CODESIGN_FAILED")
                #expect(out.data["step"] == .string(step))
                #expect(!(out.errors.first?.message.contains("someone") ?? false), "tool output is not echoed")
                try expectNothingKept(w)
            }
        }
    }

    @Test("a locked keychain at signing time is KEYCHAIN_LOCKED, and a missing identity FREE_IDENTITY_MISSING")
    func keyProblems() async throws {
        let cases = [
            (RunResult(code: 1, stderr: "x: errSecInternalComponent"), "KEYCHAIN_LOCKED"),
            (RunResult(code: 1, stderr: "error: no identity found"), "FREE_IDENTITY_MISSING"),
        ]
        for (result, expected) in cases {
            try await withSignWorld(app: .apollo, script: SignScript(signingFailure: result)) { w in
                #expect(code(await w.run()) == expected)
                try expectNothingKept(w)
            }
        }
    }

    @Test("the guard must pass: a team that is not the free team -> WRONG_TEAM, and the result is not placed")
    func guardTeam() async throws {
        try await withSignWorld(app: .apollo, script: SignScript(reportedTeam: Team.paid)) { w in
            let out = await w.run()
            #expect(code(out) == "WRONG_TEAM")
            #expect(!w.runner.signingArgs.isEmpty, "it was signed, then refused")
            try expectNothingKept(w)
        }
    }

    @Test("the guard proves the app was signed with the pinned certificate: another leaf -> GUARD_FAILED")
    func guardLeaf() async throws {
        let other = try certDER(TestCerts.other)
        try await withSignWorld(app: .apollo, script: SignScript(leaf: other)) { w in
            #expect(code(await w.run()) == "GUARD_FAILED")
            try expectNothingKept(w)
        }
    }

    @Test("a refused re-sign keeps the signed app that was already there")
    func keepsPrevious() async throws {
        try await withSignWorld(app: .apollo) { w in
            #expect(await w.run().ok)
            let before = tree(w.signedApp)
            // The same world, now with a runner whose guard sees the wrong team.
            let refusing = SignRunner(
                pinnedSha1: w.pinnedSha1, script: SignScript(reportedTeam: Team.paid, leaf: try certDER(TestCerts.free)),
                devices: deviceListJSON(
                    deviceEntryJSON(name: "Test iPhone", udid: savedUdid("1"), coreId: savedCoreId("1"), osVersion: "26.0")))
            var services = w.services
            services.runner = refusing
            let out = await SignCommand.run(services, SignOptions(app: "apollo", device: "iphone", yes: true), registry: ScratchRegistry())
            #expect(code(out) == "WRONG_TEAM")
            #expect(tree(w.signedApp) == before)
            let signed = try w.ledger().freeSigned
            #expect(signed.count == 1)
        }
    }
}
