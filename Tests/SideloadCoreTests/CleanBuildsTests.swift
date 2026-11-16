import Darwin
import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// The build-output half of `clean` (issue #49), against the temp homes of `InstallTestSupport`, `SignTestSupport` and
// `ProvisionTestSupport`. Nothing here touches a device, the network or the real `$SIDELOAD_HOME`. A build's age is its ledger
// `signedAt` against the world's clock (`testNow`); folder times play no part.

// MARK: laying files

private func put(_ text: String, to path: String) throws {
    try makeDirectories((path as NSString).deletingLastPathComponent, mode: 0o700)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

/// Every path under `root` (links not followed) with a regular file's bytes; a folder or link is nil.
private func treeOf(_ root: String) -> [String: Data?] {
    var result: [String: Data?] = [:]
    for path in (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? [] {
        var st = stat()
        let isFile = lstat(root + "/" + path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
        result[path] =
            isFile ? (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + path))) : nil
    }
    return result
}

private func bytesUnder(_ root: String) -> Int {
    treeOf(root).values.reduce(0) { $0 + (($1 ?? nil)?.count ?? 0) }
}

private func present(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

private func isLink(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
}

private func buildsJSON(_ out: Envelope) -> JSONValue { json(out)["builds"] ?? .null }

private func count(_ out: Envelope, _ key: String) -> Int {
    if case .number(let n) = buildsJSON(out)[key] ?? .null { return Int(n) }
    return -1
}

private func warningCodes(_ out: Envelope) -> [String] {
    (json(out)["warnings"]?.array ?? []).compactMap { $0["code"]?.string }
}

/// The ledger of a build signed `days` from now and recorded as installed with the same profile, version, hash and time.
private func installed(
    _ ledger: inout Ledger, _ app: AppDefinition = .stremioIOS, alias: String = "iphone",
    days: Double = -20, present: Bool = true, tweak: ((inout LedgerInstall) -> Void)? = nil
) {
    guard let at = ledger.freeSigned.firstIndex(where: { $0.id == "\(alias)/\(app.id)" }) else {
        return
    }
    ledger.freeSigned[at].signedAt = daysFromNow(days)
    var record = installRecord(app, alias: alias, present: present)
    record.signedAt = daysFromNow(days)
    tweak?(&record)
    ledger.installs.removeAll { $0.id == record.id }
    ledger.installs.append(record)
}

extension InstallWorld {
    fileprivate func clean(yes: Bool = false) -> Envelope {
        CleanCommand.run(services, CleanOptions(yes: yes))
    }

    fileprivate var signedRoot: String { paths.signedBuilds }
    fileprivate var iphoneFolder: String { "\(paths.signedBuilds)/stremio-ios/iphone" }
    fileprivate var appletvFolder: String { "\(paths.signedBuilds)/stremio-tvos/appletv" }

    /// Everything outside `builds/` that `clean` must leave alone.
    fileprivate func outside() -> [String: [String: Data?]] {
        [
            "profiles": treeOf(paths.home + "/profiles"), "downloads": treeOf(paths.downloads),
            "backups": treeOf(paths.backups),
            "ledger": ["l": try? Data(contentsOf: URL(fileURLWithPath: paths.ledger))],
            "config": ["c": try? Data(contentsOf: URL(fileURLWithPath: paths.config))],
        ]
    }
}

// MARK: signed builds

@Suite("clean: signed builds")
struct CleanSignedBuildsTests {
    @Test(
        "an installed build signed more than 14 days ago goes, with the app folder it empties; a recent one stays; bytes are counted; preview counts equal what --yes deletes"
    )
    func installedAndOld() async throws {
        try await withInstallWorld(
            alsoSigned: [.stremioTVOS],
            ledger: {
                installed(&$0)  // iphone: 20 days
                installed(&$0, .stremioTVOS, alias: "appletv", days: -3)  // appletv: recent
            }
        ) { w in
            let size = bytesUnder(w.iphoneFolder)
            #expect(size > 0)
            let before = treeOf(w.paths.builds)
            let preview = w.clean()
            #expect(preview.ok && json(preview)["dryRun"] == true, "\(preview.errors)")
            #expect(treeOf(w.paths.builds) == before, "a preview deletes nothing")
            #expect(count(preview, "signedDeleted") == 1 && count(preview, "signedKept") == 1)
            #expect(count(preview, "orphansDeleted") == 1, "the emptied stremio-ios folder")
            #expect(count(preview, "bytesFreed") == size)

            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(buildsJSON(out) == buildsJSON(preview), "what the preview said is what went")
            #expect(!present(w.paths.signedBuilds + "/stremio-ios"))
            #expect(present(w.appletvFolder))
            #expect(warningCodes(out).isEmpty && w.runner.calls.isEmpty)
        }
    }

    @Test("a build at exactly 14 days, and one a second past it")
    func boundary() async throws {
        for (days, gone) in [(-14.0, false), (-14.0 - 1.0 / 86_400, true)] {
            try await withInstallWorld(ledger: { installed(&$0, days: days) }) { w in
                let out = w.clean(yes: true)
                #expect(out.ok, "\(out.errors)")
                #expect(present(w.iphoneFolder) == !gone, "\(days)")
            }
        }
    }

    @Test("a build that cannot be proven to be the installed one is kept")
    func unprovable() async throws {
        let cases: [(String, (inout Ledger) -> Void)] = [
            ("no install record", { $0.installs.removeAll() }),
            ("install not present", { installed(&$0, present: false) }),
            ("other profile", { installed(&$0) { $0.profileUuid = "OTHER" } }),
            ("other version", { installed(&$0) { $0.version = "9.9" } }),
            ("other hash", { installed(&$0) { $0.sha256Prefix = "ffffffff" } }),
            (
                "other signing time",
                { installed(&$0) { $0.signedAt = daysFromNow(-21) } }
            ),
            (
                "no signed record",
                {
                    installed(&$0)
                    $0.freeSigned.removeAll()
                }
            ),
            (
                "signed record names another folder",
                {
                    installed(&$0)
                    $0.freeSigned[0].path = "builds/signed/stremio-ios/appletv/Stremio.app"
                }
            ),
            (
                "signed record climbs out of the folder",
                {
                    installed(&$0)
                    $0.freeSigned[0].path =
                        "builds/signed/stremio-ios/iphone/../appletv/Stremio.app"
                }
            ),
        ]
        for (name, edit) in cases {
            try await withInstallWorld(ledger: {
                installed(&$0)
                edit(&$0)
            }) { w in
                let before = treeOf(w.paths.builds)
                let out = w.clean(yes: true)
                #expect(out.ok, "\(name): \(out.errors)")
                #expect(treeOf(w.paths.builds) == before, "\(name)")
                #expect(count(out, "signedKept") == 1 && count(out, "signedDeleted") == 0, "\(name)")
            }
        }
    }

    @Test(
        "a device the lab holds, or with an operation inside its window, is skipped whole, and cleaned once the window passes"
    )
    func busyDevice() async throws {
        let op = LedgerSlotOp(
            kind: .reinstall, by: .install, startedAt: testNow,
            window: SlotRule.window(.reinstall))
        let busy: [(String, LedgerSlot)] = [
            (
                "lent",
                LedgerSlot(
                    device: "iphone", app: "apollo", presence: .absent, lentTo: "lab",
                    since: testNow)
            ),
            ("in window", LedgerSlot(device: "iphone", app: "apollo", presence: .unknown, op: op)),
        ]
        for (name, slot) in busy {
            try await withInstallWorld(
                alsoSigned: [.stremioTVOS],
                ledger: {
                    installed(&$0)
                    installed(&$0, .stremioTVOS, alias: "appletv")
                    $0.slots = [slot]
                    SlotRule.project(&$0)
                }
            ) { w in
                let out = w.clean(yes: true)
                #expect(out.ok, "\(name): \(out.errors)")
                #expect(present(w.iphoneFolder), "\(name)")
                #expect(!present(w.appletvFolder), "another device is cleaned")
                #expect(count(out, "devicesSkippedBusy") == 1 && count(out, "signedDeleted") == 1)
                #expect(warningCodes(out) == ["DEVICE_BUSY_SKIPPED"], "\(name)")
                if name == "in window" {
                    w.clock.advance(Double(SlotRule.window(.reinstall)) + 5)
                    let later = w.clean(yes: true)
                    #expect(count(later, "devicesSkippedBusy") == 0 && !present(w.iphoneFolder))
                }
            }
        }
    }

    @Test("profiles, downloads, backups, the ledger and the config are not touched")
    func leavesTheRest() async throws {
        try await withInstallWorld(ledger: { installed(&$0) }) { w in
            try put("profile", to: w.paths.freeProfiles + "/stremio-ios/iphone/p.mobileprovision")
            try put("ipa", to: w.paths.downloads + "/stremio-ios/1.2.3/Stremio.ipa")
            try put("secret", to: w.paths.backups + "/iphone/stremio-ios/20260101T000000Z/x")
            let before = w.outside()
            let out = w.clean(yes: true)
            #expect(out.ok && !present(w.iphoneFolder), "\(out.errors)")
            #expect(w.outside() == before)
        }
    }

    @Test("a folder that cannot be deleted is counted, not deleted, and makes the run incomplete")
    func failure() async throws {
        try await withInstallWorld(ledger: { installed(&$0) }) { w in
            let parent = w.paths.signedBuilds + "/stremio-ios"
            #expect(chmod(parent, 0o500) == 0)
            defer { _ = chmod(parent, 0o700) }
            let out = w.clean(yes: true)
            #expect(!out.ok && out.errorCodes == ["CLEAN_INCOMPLETE"])
            #expect(present(w.iphoneFolder))
            #expect(count(out, "failed") == 1, "the build; the app folder it fills is not a second")
            #expect(count(out, "signedDeleted") == 0 && count(out, "orphansDeleted") == 0)
            #expect(count(out, "bytesFreed") == 0)
        }
    }
}

// MARK: orphans and caches

@Suite("clean: orphans and caches")
struct CleanBuildOrphansTests {
    @Test(
        "an app that nothing knows, a device that nothing knows, and an empty app folder go; a device only the ledger knows stays"
    )
    func orphans() async throws {
        try await withInstallWorld(ledger: {
            // Not signed or installed in any matching way, but the ledger remembers this device.
            $0.installs.append(installRecord(.stremioIOS, alias: "retired"))
        }) { w in
            let root = w.paths.signedBuilds
            try put("x", to: root + "/oldapp/iphone/Old.app/file")
            try put("yy", to: root + "/oldapp/appletv/Old.app/file")
            try put("zzz", to: root + "/stremio-ios/oldphone/Stremio.app/file")
            try put("k", to: root + "/stremio-ios/retired/Stremio.app/file")
            try makeDirectories(root + "/apollo", mode: 0o700)
            let outside = w.outside()
            let preview = w.clean()
            #expect(
                treeOf(root).keys.contains("oldapp/iphone/Old.app/file") && preview.ok,
                "a preview deletes nothing")
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(buildsJSON(out) == buildsJSON(preview))
            #expect(!present(root + "/oldapp"), "the whole unknown app")
            #expect(!present(root + "/stremio-ios/oldphone"))
            #expect(!present(root + "/apollo"), "an empty app folder")
            #expect(present(root + "/stremio-ios/retired"), "unprovable, kept")
            #expect(present(w.iphoneFolder), "the recent build of a saved device")
            #expect(count(out, "orphansDeleted") == 3 && count(out, "bytesFreed") == 6)
            #expect(count(out, "signedDeleted") == 0 && count(out, "signedKept") == 2)
            #expect(w.outside() == outside)
        }
    }

    @Test("an orphan folder of a busy device or with a link inside is kept")
    func orphanGuards() async throws {
        let slot = LedgerSlot(
            device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)
        try await withInstallWorld(ledger: {
            $0.slots = [slot]
            SlotRule.project(&$0)
        }) { w in
            let root = w.paths.signedBuilds
            try put("x", to: root + "/oldapp/iphone/Old.app/file")
            let elsewhere = w.paths.home + "/elsewhere"
            try put("keep", to: elsewhere + "/file")
            try put("y", to: root + "/otherapp/oldphone/Old.app/file")
            try FileManager.default.createSymbolicLink(
                atPath: root + "/otherapp/oldphone/Old.app/link", withDestinationPath: elsewhere)
            let outsideTree = treeOf(elsewhere)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(present(root + "/oldapp/iphone/Old.app/file"), "iphone is busy")
            #expect(present(root + "/otherapp/oldphone/Old.app/file"))
            #expect(treeOf(elsewhere) == outsideTree)
            #expect(count(out, "orphansDeleted") == 0 && count(out, "devicesSkippedBusy") == 1)
            #expect(count(out, "linksSkipped") == 1)
        }
    }

    @Test(
        "carrier-dd and canary go at any age, whole, with their bytes; carrier stays"
    )
    func caches() async throws {
        try await withInstallWorld { w in
            let builds = w.paths.builds
            try put("aaaa", to: w.paths.carrierDerivedData + "/Build/Products/Carrier.app/x")
            try put("bb", to: w.paths.canaryDerivedData + "/Build/y")
            try put("project", to: w.paths.carrierProject + "/Carrier.xcodeproj/project.pbxproj")
            let stamp = timeval(tv_sec: Int(testNow.timeIntervalSince1970), tv_usec: 0)
            var times = [stamp, stamp]
            #expect(utimes(w.paths.carrierDerivedData, &times) == 0, "brand new")
            let carrier = treeOf(w.paths.carrierProject)
            let before = treeOf(builds)
            let preview = w.clean()
            #expect(treeOf(builds) == before)
            let out = w.clean(yes: true)
            #expect(out.ok && buildsJSON(out) == buildsJSON(preview), "\(out.errors)")
            #expect(count(out, "cachesDeleted") == 2 && count(out, "bytesFreed") == 6)
            #expect(!present(w.paths.carrierDerivedData) && !present(w.paths.canaryDerivedData))
            #expect(treeOf(w.paths.carrierProject) == carrier)
            #expect(present(w.iphoneFolder), "signed is not a cache")
        }
    }

    @Test(
        "links are never followed: a linked app, alias or cache folder, or a link inside a build, is kept with what it points at"
    )
    func symlinks() async throws {
        try await withInstallWorld(ledger: { installed(&$0) }) { w in
            let elsewhere = w.paths.home + "/elsewhere"
            try put("keep", to: elsewhere + "/Stremio.app/file")
            let root = w.paths.signedBuilds
            try FileManager.default.createSymbolicLink(
                atPath: root + "/linkedapp", withDestinationPath: elsewhere)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/stremio-ios/ghost", withDestinationPath: elsewhere)
            try FileManager.default.createSymbolicLink(
                atPath: w.paths.carrierDerivedData, withDestinationPath: elsewhere)
            // The old installed build itself holds a link: it is kept, whole.
            try FileManager.default.createSymbolicLink(
                atPath: w.iphoneFolder + "/Stremio.app/inside", withDestinationPath: elsewhere)
            let outsideTree = treeOf(elsewhere)
            let before = treeOf(w.paths.builds)
            for yes in [false, true] {
                let out = w.clean(yes: yes)
                #expect(out.ok, "\(out.errors)")
                #expect(count(out, "linksSkipped") == 4 && count(out, "signedDeleted") == 0)
                #expect(count(out, "cachesDeleted") == 0 && count(out, "orphansDeleted") == 0)
                #expect(warningCodes(out) == ["LINKS_SKIPPED"])
                #expect(treeOf(elsewhere) == outsideTree)
                #expect(treeOf(w.paths.builds) == before)
                for link in [
                    root + "/linkedapp", root + "/stremio-ios/ghost", w.paths.carrierDerivedData,
                    w.iphoneFolder + "/Stremio.app/inside",
                ] {
                    #expect(isLink(link), "the link itself stays")
                }
            }
        }
    }

    @Test("a linked builds folder is not entered")
    func linkedRoot() async throws {
        try await withInstallWorld { w in
            let elsewhere = w.paths.home + "/elsewhere"
            try put("keep", to: elsewhere + "/carrier-dd/file")
            try put("keep", to: elsewhere + "/signed/oldapp/iphone/file")
            try FileManager.default.removeItem(atPath: w.paths.builds)
            try FileManager.default.createSymbolicLink(
                atPath: w.paths.builds, withDestinationPath: elsewhere)
            let before = treeOf(elsewhere)
            let out = w.clean(yes: true)
            #expect(out.ok && treeOf(elsewhere) == before, "\(out.errors)")
            #expect(count(out, "cachesDeleted") == 0 && count(out, "orphansDeleted") == 0)
        }
    }

    @Test("a home with no builds folder cleans nothing and reports zeros")
    func noBuilds() async throws {
        try await withInstallWorld(signed: false) { w in
            try FileManager.default.removeItem(atPath: w.paths.builds)
            let out = w.clean(yes: true)
            #expect(out.ok, "\(out.errors)")
            #expect(
                buildsJSON(out) == [
                    "signedDeleted": 0, "signedKept": 0, "orphansDeleted": 0, "cachesDeleted": 0,
                    "bytesFreed": 0, "failed": 0, "devicesSkippedBusy": 0, "linksSkipped": 0,
                ])
        }
    }
}

// MARK: after a clean

@Suite("clean: after a full clean")
struct CleanBuildsAfterTests {
    @Test(
        "install of a deleted build says NOT_SIGNED and changes nothing on the device; once the build is back it installs"
    )
    func installAfter() async throws {
        try await withInstallWorld(ledger: { installed(&$0) }) { w in
            let kept = w.paths.home + "/kept-copy"
            try FileManager.default.copyItem(atPath: w.iphoneFolder, toPath: kept)
            let out = w.clean(yes: true)
            #expect(out.ok && !present(w.iphoneFolder), "\(out.errors)")
            let refused = await w.install()
            #expect(refused.errorCodes == ["NOT_SIGNED"], "\(refused.errors)")
            #expect(w.runner.installCalls.isEmpty)

            // What `sign` leaves again.
            try makeDirectories(w.paths.signedBuilds + "/stremio-ios", mode: 0o700)
            try FileManager.default.moveItem(atPath: kept, toPath: w.iphoneFolder)
            let again = await w.install()
            #expect(again.ok, "\(again.errors)")
            #expect(w.runner.installCalls.count == 1)
        }
    }

    @Test("sign works again for a deleted build: the IPA is kept and the folder comes back")
    func signAfter() async throws {
        try await withSignWorld(app: .stremioIOS) { w in
            let first = await w.run()
            #expect(first.ok, "\(first.errors)")
            try await w.services.ledgerStore.update { ledger in
                let signed = ledger.freeSigned[0]
                installed(&ledger, .stremioIOS, days: -20) { record in
                    record.profileUuid = signed.profileUuid
                    record.version = signed.version
                    record.sha256Prefix = signed.sha256Prefix
                }
            }
            let out = CleanCommand.run(w.services, CleanOptions(yes: true))
            #expect(out.ok && count(out, "signedDeleted") == 1, "\(out.errors)")
            #expect(!present(w.signedApp) && !present(w.paths.signedBuilds + "/stremio-ios"))
            #expect(!listing(w.paths.downloads).isEmpty, "the IPA stays")

            let second = await w.run()
            #expect(second.ok && present(w.signedApp), "\(second.errors)")
            #expect(try w.ledger().freeSigned.first?.signedAt == testNow)
        }
    }

    @Test("provision works with carrier-dd and canary gone: it builds into a fresh carrier-dd")
    func provisionAfter() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            try put("stale", to: w.paths.carrierDerivedData + "/Build/Products/stale")
            try put("canary", to: w.paths.canaryDerivedData + "/Build/x")
            let out = CleanCommand.run(w.services, CleanOptions(yes: true))
            #expect(out.ok && count(out, "cachesDeleted") == 2, "\(out.errors)")
            #expect(!present(w.paths.carrierDerivedData) && !present(w.paths.canaryDerivedData))

            let provisioned = await w.run()
            #expect(provisioned.ok, "\(provisioned.errors)")
            #expect(present(w.paths.carrierDerivedData + "/Build/Products"))
            #expect(!present(w.paths.carrierDerivedData + "/Build/Products/stale"))
        }
    }
}
