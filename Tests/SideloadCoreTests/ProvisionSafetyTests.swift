import Foundation
import Testing

@testable import SideloadCore

// Rework round 1: the crash-safe in-flight marker (a signal during xcodebuild must not let a new free certificate
// be absorbed into the next run's "before" snapshot) and the `--renew` read/move race.

private func fp8(_ cert: KeychainCertificate) -> String { LedgerSync.fp8(cert.reference) }

private func marker(_ fp8s: [String], app: String = "stremio-ios") -> LedgerFreeInFlight {
    LedgerFreeInFlight(beforeFp8: fp8s, startedAt: daysFromNow(-1), app: app, device: "iphone")
}

private func plant(_ w: ProvisionWorld, _ fp8s: [String]) async throws {
    try await w.services.ledgerStore.update { $0.freeProvisionInFlight = marker(fp8s) }
}

@Suite("provision: in-flight marker")
struct ProvisionInFlightTests {
    @Test("the marker is in the ledger when xcodebuild starts, holds the before set, and is gone afterwards")
    func writtenBeforeAndCleared() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free, try keychainCert(TestCerts.paid)], [free, try keychainCert(TestCerts.paid)]]) { (w: ProvisionWorld) async throws in
            #expect(try w.ledger().freeProvisionInFlight == nil)
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            let during = try #require(w.cacheAtBuild.ledgerAtBuild?.freeProvisionInFlight, "written before the build")
            #expect(during.beforeFp8 == [fp8(free)], "the free-OU set only, by 8-hex fingerprint")
            #expect(during.app == "stremio-ios" && during.device == "iphone" && during.startedAt == testNow)
            #expect(try w.ledger().freeProvisionInFlight == nil, "cleared with the after-comparison")
            let raw = try String(contentsOfFile: w.paths.ledger, encoding: .utf8)
            #expect(!raw.contains("freeProvisionInFlight"))
            #expect(!raw.contains(free.reference), "no full fingerprint in the ledger")
        }
    }

    @Test("it is cleared after a failed build and after FREE_CERT_CHANGED, once the comparison was recorded")
    func clearedOnEveryRecordedPath() async throws {
        let free = try freeKeychainCert()
        let failing = BuildScript(result: RunResult(code: 65, stderr: "error: x"))
        try await withProvisionWorld(reads: [[free], [free]], build: failing) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "PROVISION_FAILED")
            #expect(w.cacheAtBuild.ledgerAtBuild?.freeProvisionInFlight != nil)
            #expect(try w.ledger().freeProvisionInFlight == nil)
        }
        try await withProvisionWorld(reads: [[free], [free, otherFreeCert()]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "FREE_CERT_CHANGED")
            #expect(try w.ledger().freeProvisionInFlight == nil)
            #expect(try w.ledger().freeSuspended != nil)
        }
    }

    @Test("a marker with a changed free set is FREE_CERT_CHANGED before anything else: suspended, cleared, no build")
    func staleChanged() async throws {
        let free = try freeKeychainCert(), extra = otherFreeCert()
        // Added since the dead run began.
        try await withProvisionWorld(reads: [[free, extra]]) { (w: ProvisionWorld) async throws in
            try await plant(w, [fp8(free)])
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.errors.first?.message.contains("earlier run") == true)
            #expect(out.data["addedFp8"] == [.string(fp8(extra))])
            #expect(out.data["removedFp8"] == [])
            #expect(out.data["suspended"] == true)
            #expect(w.builds.isEmpty, "nothing was built")
            #expect(w.keychain.readCount == 1)
            let ledger = try w.ledger()
            #expect(ledger.freeProvisionInFlight == nil)
            #expect(ledger.freeSuspended?.code == "FREE_CERT_CHANGED")
            #expect(ledger.freeSuspended?.addedFp8 == [fp8(extra)])
            #expect(ledger.freeSuspended?.at == testNow)
            #expect(ledger.freeAppIds.isEmpty && ledger.freeProfiles.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: w.paths.builds + "/carrier"), "not even the project was written")
        }
        // Removed.
        try await withProvisionWorld(reads: [[free]]) { (w: ProvisionWorld) async throws in
            try await plant(w, [fp8(free), fp8(extra)])
            let out = await w.run()
            #expect(out.errors.first?.code == "FREE_CERT_CHANGED")
            #expect(out.data["removedFp8"] == [.string(fp8(extra))])
            #expect(try w.ledger().freeSuspended?.removedFp8 == [fp8(extra)])
            #expect(w.builds.isEmpty)
        }
    }

    @Test("a marker with an unchanged set is cleared and the run goes on")
    func staleUnchanged() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [[free], [free]]) { (w: ProvisionWorld) async throws in
            try await plant(w, [fp8(free)])
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(w.builds.count == 1)
            #expect(try w.ledger().freeProvisionInFlight == nil)
            #expect(try w.ledger().freeSuspended == nil)
            // Its own marker, not the stale one, was in place during the build.
            #expect(w.cacheAtBuild.ledgerAtBuild?.freeProvisionInFlight?.startedAt == testNow)
        }
    }

    @Test("a marker is settled before the pinned-identity and budget checks")
    func settledFirst() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(config: provisionConfig(extra: ["freeTeam": ["certFp8": "deadbeef"]]), reads: [[free, otherFreeCert()]]) { (w: ProvisionWorld) async throws in
            try await plant(w, [fp8(free)])
            #expect(await w.run().errors.first?.code == "FREE_CERT_CHANGED", "not FREE_IDENTITY_MISSING")
        }
    }

    @Test("an unreadable keychain cannot settle a marker: KEYCHAIN_LOCKED, and the marker stays")
    func staleLocked() async throws {
        let free = try freeKeychainCert()
        try await withProvisionWorld(reads: [nil]) { (w: ProvisionWorld) async throws in
            try await plant(w, [fp8(free)])
            #expect(await w.run().errors.first?.code == "KEYCHAIN_LOCKED")
            #expect(try w.ledger().freeProvisionInFlight == marker([fp8(free)]))
        }
    }

    @Test("a run whose after-read failed leaves the marker, so the next run catches the new certificate")
    func absorbedNever() async throws {
        let free = try freeKeychainCert(), extra = otherFreeCert()
        // Run 1: before [free]; after unreadable (as if the process died). Run 2: the keychain now has `extra`.
        try await withProvisionWorld(config: provisionConfig(extra: ["freeTeam": ["certFp8": .string(fp8(free))]]), reads: [[free], nil, [free, extra], [free, extra]]) { (w: ProvisionWorld) async throws in
            #expect(await w.run().errors.first?.code == "IDENTITY_CHECK_FAILED")
            #expect(try w.ledger().freeProvisionInFlight?.beforeFp8 == [fp8(free)], "the comparison never ran")
            let second = await w.run()
            #expect(second.errors.first?.code == "FREE_CERT_CHANGED", "the new certificate is not absorbed")
            #expect(second.data["addedFp8"] == [.string(fp8(extra))])
            #expect(w.builds.count == 1, "run 2 built nothing")
            #expect(try w.ledger().freeProvisionInFlight == nil)
            // Run 3 is the owner's manual re-run: the set is now stable and it succeeds, lifting the suspension.
            let third = await w.run()
            #expect(third.ok, "\(third.errors)")
            #expect(third.data["suspensionCleared"] == true)
        }
    }

    @Test("FreeIdentityGuard does nothing and writes nothing without a marker")
    func noMarker() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let change = try await FreeIdentityGuard.settleInFlight(
                ledgerStore: w.services.ledgerStore, current: [try freeKeychainCert()], now: testNow)
            #expect(change == nil)
            #expect(!FileManager.default.fileExists(atPath: w.paths.ledger), "no ledger write")
        }
    }

    @Test("the marker round-trips through the ledger file")
    func roundTrip() throws {
        let ledger = Ledger(freeProvisionInFlight: marker(["abcdef01"]))
        #expect(try LedgerStore.parse(try LedgerStore.encode(ledger)) == ledger)
    }

    @Test("products that cannot be cleared stop the run before the marker and the build")
    func derivedDataNotCleared() async throws {
        try await withProvisionWorld { (w: ProvisionWorld) async throws in
            let build = w.paths.builds + "/carrier-dd/Build"
            try FileManager.default.createDirectory(atPath: build + "/Products/Debug-iphoneos", withIntermediateDirectories: true)
            _ = chmod(build, 0o500)
            defer { _ = chmod(build, 0o700) }
            let out = await w.run()
            #expect(out.errors.first?.code == "DERIVED_DATA_NOT_CLEARED")
            #expect(w.builds.isEmpty)
            #expect(try w.ledger().freeProvisionInFlight == nil)
            #expect(try w.ledger().freeAppIds.isEmpty)
        }
    }
}

// MARK: --renew race

@Suite("provision: --renew read and move")
struct ProvisionRenewRaceTests {
    private func mine(_ uuid: String = "11111111-1111-1111-1111-111111111111") throws -> String {
        try freeProfileXML(uuid: uuid)
    }

    private func runner() -> FakeRunner {
        FakeRunner { spec in
            if spec.args == ["cms", "-D"], let stdin = spec.stdin { return RunResult(stdout: String(decoding: stdin, as: UTF8.self)) }
            return RunResult(code: 1)
        }
    }

    private func move(
        _ dir: String, tmp: String, runner: FakeRunner, beforeMove: (String) -> Void = { _ in }
    ) async -> ProfileCacheRenewal.Outcome {
        await ProfileCacheRenewal.moveOwnProfiles(
            in: [dir], bundleId: stremioId, platform: "iOS", to: tmp, runner: runner, beforeMove: beforeMove, afterCheck: { _ in })
    }

    @Test("the bytes decoded are the bytes read from the opened file, piped on stdin with no path")
    func decodesWhatWasRead() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let xml = try mine()
            try Data(xml.utf8).write(to: URL(fileURLWithPath: dir + "/a.mobileprovision"))
            let r = runner()
            let out = await move(dir, tmp: paths.tmp, runner: r)
            #expect((out.moved, out.skipped) == (1, 0))
            let call = try #require(r.calls.first)
            #expect(call.args == ["cms", "-D"])
            #expect(call.stdin == Data(xml.utf8))
            #expect(!call.args.contains { $0.contains("cache") })
        }
    }

    @Test("a file replaced between the read and the move is skipped and left alone")
    func swapped() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let target = dir + "/a.mobileprovision"
            try Data(try mine().utf8).write(to: URL(fileURLWithPath: target))
            let intruder = try freeProfileXML(bundleId: apolloId, uuid: "99999999-9999-9999-9999-999999999999")
            let out = await move(dir, tmp: paths.tmp, runner: runner()) { path in
                // A different file (new inode) renamed over the path after it was vetted.
                let other = path + ".swap"
                try? Data(intruder.utf8).write(to: URL(fileURLWithPath: other))
                _ = rename(other, path)
            }
            #expect((out.moved, out.skipped) == (0, 1))
            #expect(try String(contentsOfFile: target, encoding: .utf8) == intruder, "the intruder stays where it is")
            #expect(listing(paths.tmp).filter { $0.hasPrefix("renewed-profile-") }.isEmpty)
        }
    }

    @Test("a file rewritten in place (same inode, new size) is skipped too")
    func rewrittenInPlace() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let target = dir + "/a.mobileprovision"
            try Data(try mine().utf8).write(to: URL(fileURLWithPath: target))
            let out = await move(dir, tmp: paths.tmp, runner: runner()) { path in
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data("<!-- changed -->".utf8))
                    try? handle.close()
                }
            }
            #expect((out.moved, out.skipped) == (0, 1))
            #expect(FileManager.default.fileExists(atPath: target))
        }
    }

    @Test("a symlink, a directory, an oversize file and an unreadable file are skipped and counted, never read through")
    func unsafeEntries() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            let elsewhere = paths.home + "/elsewhere"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
            // A matching profile outside the folder, reached only through a symlink in it.
            try Data(try mine().utf8).write(to: URL(fileURLWithPath: elsewhere + "/real.mobileprovision"))
            try FileManager.default.createSymbolicLink(atPath: dir + "/link.mobileprovision", withDestinationPath: elsewhere + "/real.mobileprovision")
            try FileManager.default.createSymbolicLink(atPath: dir + "/dangling.mobileprovision", withDestinationPath: elsewhere + "/nope")
            try FileManager.default.createDirectory(atPath: dir + "/dir.mobileprovision", withIntermediateDirectories: true)
            try Data(count: ProfileCacheRenewal.maxProfileBytes + 1).write(to: URL(fileURLWithPath: dir + "/big.mobileprovision"))
            try Data(try mine().utf8).write(to: URL(fileURLWithPath: dir + "/locked.mobileprovision"))
            _ = chmod(dir + "/locked.mobileprovision", 0o000)
            defer { _ = chmod(dir + "/locked.mobileprovision", 0o600) }
            let r = runner()
            let out = await move(dir, tmp: paths.tmp, runner: r)
            #expect((out.moved, out.skipped) == (0, 5))
            #expect(r.calls.isEmpty, "none of them was decoded")
            #expect(FileManager.default.fileExists(atPath: elsewhere + "/real.mobileprovision"))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir + "/link.mobileprovision")) != nil)
        }
    }

    @Test("a profile that decodes but is not ours is neither moved nor counted as skipped")
    func decoyIsNotSkipped() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(try freeProfileXML(bundleId: apolloId).utf8).write(to: URL(fileURLWithPath: dir + "/other.mobileprovision"))
            try Data("garbage".utf8).write(to: URL(fileURLWithPath: dir + "/junk.mobileprovision"))
            let out = await move(dir, tmp: paths.tmp, runner: runner())
            #expect((out.moved, out.skipped) == (0, 0))
            #expect(listing(dir).sorted() == ["junk.mobileprovision", "other.mobileprovision"])
        }
    }

    @Test("a failed move is PROFILE_MOVE_FAILED in the outcome, with nothing moved")
    func moveFails() async throws {
        try await withTestHome { paths, _ in
            let dir = paths.home + "/cache"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(try mine().utf8).write(to: URL(fileURLWithPath: dir + "/a.mobileprovision"))
            // `tmp` is a regular file, so nothing can be moved into it.
            let blocked = paths.home + "/blocked"
            try Data("x".utf8).write(to: URL(fileURLWithPath: blocked))
            let out = await move(dir, tmp: blocked, runner: runner())
            #expect(out.error?.code == "PROFILE_MOVE_FAILED")
            #expect((out.moved, out.skipped, out.movedTo) == (0, 0, []))
            #expect(FileManager.default.fileExists(atPath: dir + "/a.mobileprovision"), "still in place")
        }
    }
}
