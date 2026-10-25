import Foundation
import Testing

@testable import SideloadCore

// Rework round 2: `--renew` reporting in every envelope, the App ID epoch written with the marker, and the
// post-move identity check.

@Suite("provision: renew reporting and the marker write")
struct ProvisionRenewReportingTests {
    private static let uuid = "11111111-1111-1111-1111-111111111111"

    private func cache() throws -> [String: String] {
        ["xcode-cache-1/mine.mobileprovision": try freeProfileXML(uuid: Self.uuid)]
    }

    private func expectReported(_ out: Envelope, _ w: ProvisionWorld, moved: Int = 1, skipped: Int = 0) throws {
        #expect(out.data["cachedProfilesMoved"] == .number(Double(moved)))
        #expect(out.data["cachedProfilesSkipped"] == .number(Double(skipped)))
        let to = try #require(out.data["cachedProfilesMovedTo"]?.array)
        #expect(to.count == moved)
        for name in to.compactMap(\.string) {
            #expect(name.hasPrefix("tmp/renewed-profile-") && name.hasSuffix(".mobileprovision"), "a relative name")
            #expect(FileManager.default.fileExists(atPath: w.paths.home + "/" + name))
        }
        #expect(!(try out.printed().text.contains(w.paths.home)), "no absolute path")
    }

    @Test("PROFILE_NOT_RENEWED after a move still says what was moved")
    func notRenewedAfterMove() async throws {
        try await withProvisionWorld(cache: try cache()) { (w: ProvisionWorld) async throws in
            try await w.services.ledgerStore.update {
                $0.freeProfiles = [
                    LedgerFreeProfile(
                        id: "iphone/stremio-ios", device: "iphone", deviceTail: "…0001", app: "stremio-ios", bundleId: stremioId,
                        profileUuid: "AAAAAAAA-0000-0000-0000-000000000001", created: daysFromNow(0), expires: daysFromNow(7),
                        certFp8: "00000000", file: "profiles/free/old")
                ]
            }
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "PROFILE_NOT_RENEWED")
            try expectReported(out, w)
        }
    }

    @Test("a build failure after a move says what was moved")
    func buildFailureAfterMove() async throws {
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: "error: odd")), cache: try cache()) { (w: ProvisionWorld) async throws in
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "PROVISION_FAILED")
            try expectReported(out, w)
        }
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: "error: No Account for Team")), cache: try cache()) { (w: ProvisionWorld) async throws in
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "ACCOUNT_NOT_SIGNED_IN")
            try expectReported(out, w)
        }
    }

    @Test("FREE_CERT_CHANGED and PROFILE_INVALID after a move say what was moved")
    func otherStopsAfterMove() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free], [free, otherFreeCert()]], cache: try cache()) { (w: ProvisionWorld) async throws in
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            try expectReported(out, w)
        }
        try await withProvisionWorld(build: BuildScript(profile: try freeProfileXML(getTaskAllow: false)), cache: try cache()) { (w: ProvisionWorld) async throws in
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "PROFILE_INVALID")
            try expectReported(out, w)
        }
    }

    @Test("without --renew no envelope carries renewal data")
    func absentWithoutRenew() async throws {
        try await withProvisionWorld(build: BuildScript(result: RunResult(code: 65, stderr: "error: odd")), cache: try cache()) { (w: ProvisionWorld) async throws in
            let out = await w.run()
            for key in ["cachedProfilesMoved", "cachedProfilesSkipped", "cachedProfilesMovedTo", "renewScanTruncated"] {
                #expect(out.data[key] == nil, "\(key)")
            }
        }
    }

    @Test("the renewal runs after the derived-data clear, so a stuck clear moves nothing")
    func renewalAfterClear() async throws {
        try await withProvisionWorld(cache: try cache()) { (w: ProvisionWorld) async throws in
            let build = w.paths.builds + "/carrier-dd/Build"
            try FileManager.default.createDirectory(atPath: build + "/Products/Debug-iphoneos", withIntermediateDirectories: true)
            _ = chmod(build, 0o500)
            defer { _ = chmod(build, 0o700) }
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "DERIVED_DATA_NOT_CLEARED")
            #expect(FileManager.default.fileExists(atPath: w.cacheDirs[0] + "/mine.mobileprovision"), "not moved")
            #expect(out.data["cachedProfilesMoved"] == nil)
        }
    }

    @Test("more profiles than the scan cap is reported as renewScanTruncated")
    func truncated() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            for i in 0..<(XcodeManagedProfileSource.maxFiles + 3) {
                try Data("x".utf8).write(to: URL(fileURLWithPath: w.cacheDirs[0] + String(format: "/f%04d.mobileprovision", i)))
            }
            let out = await w.run(renew: true)
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["renewScanTruncated"] == 3)
            #expect(out.data["cachedProfilesMoved"] == 0)
        }
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            #expect(await w.run(renew: true).data["renewScanTruncated"] == 0, "present, and zero, once the renewal ran")
        }
    }

    @Test("the App ID epoch is in the ledger when xcodebuild starts, in the same write as the marker")
    func epochWithMarker() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            #expect(await w.run().ok)
            let during = try #require(w.cacheAtBuild.ledgerAtBuild)
            #expect(during.freeAppIds == [LedgerFreeAppId(bundleId: stremioId, epochStart: testNow)])
            #expect(during.freeProvisionInFlight != nil)
        }
    }

    @Test("a marker that cannot be written stops the run before xcodebuild")
    func markerWriteFails() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            // A directory where the ledger lock file belongs: every ledger update fails.
            try FileManager.default.createDirectory(atPath: w.paths.ledgerLock, withIntermediateDirectories: true)
            let out = await w.run()
            #expect(!out.ok)
            #expect(out.errors.first?.code == "IO_ERROR")
            #expect(w.builds.isEmpty, "xcodebuild never ran")
            #expect(!FileManager.default.fileExists(atPath: w.paths.ledger), "no ledger was written")
        }
    }

    @Test("a thrown error after a move (the marker write failing) still says what was moved")
    func thrownAfterMove() async throws {
        try await withProvisionWorld(cache: try cache()) { (w: ProvisionWorld) async throws in
            var hooks = ProvisionHooks()
            hooks.checkpoint = { point in
                if point == .markerWrite { throw SideloadError("IO_ERROR", "injected") }
            }
            let out = await ProvisionCommand.run(
                w.services, ProvisionOptions(app: "stremio-ios", device: "iphone", renew: true, yes: true), hooks: hooks)
            #expect(out.errors.first?.code == "IO_ERROR")
            #expect(w.builds.isEmpty, "xcodebuild never ran")
            #expect(out.data["app"] == "stremio-ios")
            try expectReported(out, w)
        }
    }

    @Test("a folder that cannot be listed after an earlier folder's move still says what was moved")
    func unreadableFolderAfterMove() async throws {
        try await withProvisionWorld(cache: try cache()) { (w: ProvisionWorld) async throws in
            _ = chmod(w.cacheDirs[1], 0o000)
            defer { _ = chmod(w.cacheDirs[1], 0o700) }
            let out = await w.run(renew: true)
            #expect(out.errors.first?.code == "PROFILES_UNREADABLE")
            #expect(out.data["cachedProfilesMoved"] == 1)
            #expect(out.data["movedSoFar"] == nil)
            let to = try #require(out.data["cachedProfilesMovedTo"]?.array).compactMap(\.string)
            #expect(to.count == 1)
            for name in to { #expect(FileManager.default.fileExists(atPath: w.paths.home + "/" + name)) }
            #expect(w.builds.isEmpty)
        }
    }

    @Test("a file swapped in after the check but before the rename is put back and counted as skipped")
    func swappedAtRename() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let target = dir + "/a.mobileprovision"
            try Data(try freeProfileXML(uuid: Self.uuid).utf8).write(to: URL(fileURLWithPath: target))
            let intruder = try freeProfileXML(bundleId: apolloId, uuid: "99999999-9999-9999-9999-999999999999")
            let runner = FakeRunner { spec in
                spec.stdin.map { RunResult(stdout: String(decoding: $0, as: UTF8.self)) } ?? RunResult(code: 1)
            }
            let out = await ProfileCacheRenewal.moveOwnProfiles(
                in: [dir], bundleId: stremioId, platform: "iOS", to: paths.tmp, runner: runner, beforeMove: { _ in },
                afterCheck: { path in
                    let other = path + ".swap"
                    try? Data(intruder.utf8).write(to: URL(fileURLWithPath: other))
                    _ = rename(other, path)
                })
            #expect((out.moved, out.skipped) == (0, 1))
            #expect(out.movedTo.isEmpty)
            #expect(try String(contentsOfFile: target, encoding: .utf8) == intruder, "put back where it was")
            #expect(listing(paths.tmp).filter { $0.hasPrefix("renewed-profile-") }.isEmpty)
        }
    }
}
