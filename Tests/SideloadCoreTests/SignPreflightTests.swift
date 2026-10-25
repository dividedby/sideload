import Foundation
import Testing

@testable import SideloadCore

// `sign` stops before it unpacks anything unless every precondition holds (design section 18): usage, config, the
// saved device and its platform, confirmation, the operation lock, the crash-safe marker, the pinned identity, the
// approved and intact IPA, the device's OS and the stored profile. None of these tests extracts an archive.

private func extracted(_ w: SignWorld) -> Bool {
    w.runner.calls.contains { $0.executable == "/usr/bin/ditto" }
}

private func code(_ envelope: Envelope) -> String? { envelope.errors.first?.code }

@Suite("sign: usage, config, device, confirmation and lock")
struct SignEntryTests {
    @Test("a missing --app or --device, or an unknown app, is USAGE and runs nothing")
    func usage() async throws {
        try await withSignWorld { w in
            for (app, device) in [(nil, "iphone"), ("stremio-ios", nil), ("", "iphone"), ("nonsense", "iphone")] {
                let out = await SignCommand.run(w.services, SignOptions(app: app, device: device, yes: true))
                #expect(code(out) == "USAGE", "\(app ?? "-") \(device ?? "-")")
            }
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("bundleIdPrefix missing -> CONFIG_MISSING")
    func configMissing() async throws {
        try await withSignWorld(prefix: nil) { w in
            #expect(code(await w.run()) == "CONFIG_MISSING")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("an alias that is not saved -> DEVICE_NOT_SAVED")
    func deviceNotSaved() async throws {
        try await withSignWorld { w in
            #expect(code(await w.run(device: "nope")) == "DEVICE_NOT_SAVED")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("the saved device's platform must match the app")
    func platform() async throws {
        try await withSignWorld { w in
            let tvOnPhone = await w.run(app: "stremio-tvos", device: "iphone")
            #expect(code(tvOnPhone) == "PLATFORM_MISMATCH")
            let phoneOnTV = await w.run(app: "apollo", device: "appletv")
            #expect(code(phoneOnTV) == "PLATFORM_MISMATCH")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("without --yes: CONFIRM_REQUIRED, nothing run, nothing locked")
    func confirm() async throws {
        try await withSignWorld { w in
            let out = await w.run(yes: false)
            #expect(code(out) == "CONFIRM_REQUIRED")
            #expect(out.errors.first?.fix?.contains("Agents must not pass --yes") == true)
            #expect(w.runner.calls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: w.paths.opLock))
        }
    }

    @Test("a busy .op.lock -> OPERATION_IN_PROGRESS, before the keychain or any tool")
    func busyLock() async throws {
        try await withSignWorld { w in
            let held = try OperationLock.acquire(paths: w.paths)
            defer { held.release() }
            #expect(code(await w.run()) == "OPERATION_IN_PROGRESS")
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("the lock is released afterwards, success or not")
    func lockReleased() async throws {
        try await withSignWorld(manifest: .none) { w in
            #expect(code(await w.run()) == "NOT_APPROVED")
            let again = try OperationLock.acquire(paths: w.paths)
            again.release()
        }
    }

    @Test("a sign-* folder a killed run left in tmp/ is swept under the lock; other folders are left alone")
    func sweepsStale() async throws {
        try await withSignWorld(manifest: .none) { w in
            try FileManager.default.createDirectory(atPath: w.paths.tmp + "/sign-stale/x/locked", withIntermediateDirectories: true)
            chmod(w.paths.tmp + "/sign-stale/x/locked", 0)
            try FileManager.default.createDirectory(atPath: w.paths.tmp + "/inspect-other", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: w.paths.tmp + "/fetch-other", withIntermediateDirectories: true)
            #expect(code(await w.run()) == "NOT_APPROVED")
            #expect(listing(w.paths.tmp).sorted() == ["fetch-other", "inspect-other"])
        }
    }

    @Test("the sweep comes after the marker is settled: a changed identity set stops the run before any folder is touched")
    func sweepAfterSettle() async throws {
        try await withSignWorld(
            manifest: .none,
            ledger: { $0.freeProvisionInFlight = LedgerFreeInFlight(beforeFp8: ["deadbeef"], startedAt: testNow, app: "x", device: "y") }
        ) { w in
            try FileManager.default.createDirectory(atPath: w.paths.tmp + "/sign-stale", withIntermediateDirectories: true)
            #expect(code(await w.run()) == "FREE_CERT_CHANGED")
            #expect(listing(w.paths.tmp) == ["sign-stale"])
        }
        try await withSignWorld(manifest: .none) { w in
            var services = w.services
            services.keychain = FakeKeychain(failure: KeychainError("locked"))
            try FileManager.default.createDirectory(atPath: w.paths.tmp + "/sign-stale", withIntermediateDirectories: true)
            #expect(code(await SignCommand.run(services, SignOptions(app: "stremio-ios", device: "iphone", yes: true))) == "KEYCHAIN_LOCKED")
            #expect(listing(w.paths.tmp) == ["sign-stale"])
        }
    }

    @Test("an interrupted run (registry closed) is CANCELLED and leaves no scratch folder")
    func cancelled() async throws {
        try await withSignWorld { w in
            let registry = ScratchRegistry()
            registry.removeAllAndClose()
            #expect(code(await w.run(registry: registry)) == "CANCELLED")
            #expect(w.leftovers.isEmpty)
        }
    }
}

@Suite("sign: the pinned identity and the crash-safe marker")
struct SignIdentityTests {
    @Test("the keychain cannot be read -> KEYCHAIN_LOCKED")
    func locked() async throws {
        try await withSignWorld { w in
            var services = w.services
            services.keychain = FakeKeychain(failure: KeychainError("locked"))
            let out = await SignCommand.run(services, SignOptions(app: "stremio-ios", device: "iphone", yes: true))
            #expect(code(out) == "KEYCHAIN_LOCKED")
            #expect(!extracted(w))
        }
    }

    @Test("no pin yet -> FREE_IDENTITY_NOT_PINNED with a fix that names provision")
    func notPinned() async throws {
        try await withSignWorld(pin: false) { w in
            let out = await w.run()
            #expect(code(out) == "FREE_IDENTITY_NOT_PINNED")
            #expect(out.errors.first?.fix?.contains("provision") == true)
            #expect(!extracted(w))
        }
    }

    @Test("the pinned identity missing, expired, or another free identity in its place -> FREE_IDENTITY_MISSING")
    func missing() async throws {
        let free = try freeKeychainCert()
        let pinnedPrefix = LedgerSync.fp8(free.reference)
        let others: [[KeychainCertificate]] = [
            [],
            [otherFreeCert("AB")],
            [otherFreeCert("CD", fp8: pinnedPrefix, notAfter: daysFromNow(-1))],
        ]
        for keychain in others {
            try await withSignWorld(keychain: keychain) { w in
                let out = await w.run()
                #expect(code(out) == "FREE_IDENTITY_MISSING")
                #expect(!extracted(w))
                #expect(w.runner.signingArgs.isEmpty)
            }
        }
    }

    @Test("two valid identities with the pinned prefix -> FREE_IDENTITY_AMBIGUOUS")
    func ambiguous() async throws {
        let free = try freeKeychainCert()
        let twin = otherFreeCert("EF", fp8: LedgerSync.fp8(free.reference))
        try await withSignWorld(keychain: [free, twin]) { w in
            #expect(code(await w.run()) == "FREE_IDENTITY_AMBIGUOUS")
            #expect(!extracted(w))
        }
    }

    @Test("a marker left by a dead run is settled first: a changed identity set is FREE_CERT_CHANGED, suspended, marker cleared")
    func markerChanged() async throws {
        // No pin and no manifest: if anything but the marker were checked first, a different code would win.
        try await withSignWorld(
            manifest: .none, pin: false,
            ledger: { $0.freeProvisionInFlight = LedgerFreeInFlight(beforeFp8: ["deadbeef"], startedAt: testNow, app: "stremio-ios", device: "iphone") }
        ) { w in
            let out = await w.run()
            #expect(code(out) == "FREE_CERT_CHANGED")
            #expect(out.data["suspended"] == true)
            let ledger = try w.ledger()
            #expect(ledger.freeProvisionInFlight == nil)
            #expect(ledger.freeSuspended?.code == "FREE_CERT_CHANGED")
            #expect(ledger.freeSuspended?.addedFp8 == [LedgerSync.fp8(try freeKeychainCert().reference)])
            #expect(ledger.freeSuspended?.removedFp8 == ["deadbeef"])
            #expect(!extracted(w))
        }
    }

    @Test("a marker whose identity set is unchanged is cleared and the run goes on")
    func markerUnchanged() async throws {
        let free = try freeKeychainCert()
        try await withSignWorld(
            manifest: .none,
            ledger: {
                $0.freeProvisionInFlight = LedgerFreeInFlight(
                    beforeFp8: [LedgerSync.fp8(free.reference)], startedAt: testNow, app: "stremio-ios", device: "iphone")
            }
        ) { w in
            #expect(code(await w.run()) == "NOT_APPROVED", "it got past the marker")
            let ledger = try w.ledger()
            #expect(ledger.freeProvisionInFlight == nil)
            #expect(ledger.freeSuspended == nil)
        }
    }

    @Test("an unreadable keychain leaves the marker in place")
    func markerKept() async throws {
        try await withSignWorld(
            ledger: { $0.freeProvisionInFlight = LedgerFreeInFlight(beforeFp8: ["deadbeef"], startedAt: testNow, app: "x", device: "y") }
        ) { w in
            var services = w.services
            services.keychain = FakeKeychain(failure: KeychainError("locked"))
            _ = await SignCommand.run(services, SignOptions(app: "stremio-ios", device: "iphone", yes: true))
            let kept = try w.ledger().freeProvisionInFlight
            #expect(kept != nil)
        }
    }
}

@Suite("sign: the approved, intact IPA")
struct SignManifestTests {
    @Test("nothing fetched, or nothing approved -> NOT_APPROVED, each with its own fix")
    func notApproved() async throws {
        try await withSignWorld(manifest: .none) { w in
            let out = await w.run()
            #expect(code(out) == "NOT_APPROVED")
            #expect(out.errors.first?.fix?.contains("sideload fetch --app stremio-ios") == true)
            #expect(!extracted(w))
        }
        try await withSignWorld(manifest: .unapproved) { w in
            let out = await w.run()
            #expect(code(out) == "NOT_APPROVED")
            #expect(out.errors.first?.fix?.contains("--approve --version") == true)
            #expect(!extracted(w))
        }
    }

    @Test("another app's approved entry does not count")
    func otherApp() async throws {
        try await withSignWorld(app: .apollo) { w in
            // Only apollo is in the manifest.
            let out = await w.run(app: "stremio-ios", device: "iphone")
            #expect(code(out) == "NOT_APPROVED")
        }
    }

    @Test("a file that no longer hashes to the manifest's sha256 -> DIGEST_MISMATCH, never unpacked")
    func tampered() async throws {
        try await withSignWorld(manifest: .tampered) { w in
            let out = await w.run()
            #expect(code(out) == "DIGEST_MISMATCH")
            #expect(out.data["expected"] == .string(w.sha256))
            #expect(!extracted(w))
        }
    }

    @Test("a file that is gone -> IPA_MISSING")
    func missingFile() async throws {
        try await withSignWorld(manifest: .missingFile) { w in
            #expect(code(await w.run()) == "IPA_MISSING")
            #expect(!extracted(w))
        }
    }

    @Test("a symlink in place of the file is not followed -> IPA_MISSING")
    func symlinked() async throws {
        try await withSignWorld { w in
            let manifest = try ManifestStore(paths: w.paths).load()
            let path = try ManifestStore(paths: w.paths).path(of: manifest.entries[0])
            let target = w.paths.home + "/real.ipa"
            try FileManager.default.moveItem(atPath: path, toPath: target)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            #expect(code(await w.run()) == "IPA_MISSING")
        }
    }

    @Test("a manifest entry whose file leaves downloads/<app>/<version>/ -> MANIFEST_INVALID")
    func escapingPath() async throws {
        try await withSignWorld { w in
            let store = ManifestStore(paths: w.paths)
            var manifest = try store.load()
            manifest.entries[0].file = "../../config.json"
            try store.save(manifest)
            #expect(code(await w.run()) == "MANIFEST_INVALID")
            #expect(!extracted(w))
        }
    }
}

@Suite("sign: the device's OS")
struct SignDeviceOSTests {
    @Test("an OS older than inspectMinOS -> DEVICE_OS_TOO_OLD, before any unpacking")
    func tooOld() async throws {
        try await withSignWorld(script: SignScript(deviceOS: "14.8")) { w in
            let out = await w.run()
            #expect(code(out) == "DEVICE_OS_TOO_OLD")
            #expect(out.data["deviceOS"] == "14.8" && out.data["minimumOS"] == "15.0")
            #expect(out.data["deviceOSSource"] == "devicectl list devices")
            #expect(!extracted(w))
        }
    }

    @Test("an OS equal to the minimum passes the check (the next stop is the missing profile)")
    func equalPasses() async throws {
        try await withSignWorld(profile: .noRecord, script: SignScript(deviceOS: "15.0")) { w in
            #expect(code(await w.run()) == "PROFILE_MISSING")
        }
    }

    @Test("the stricter of the declared minimum and the binary's decides: declared higher than inspect's is refused, before unpacking")
    func declaredStricter() async throws {
        try await withSignWorld(script: SignScript(deviceOS: "15.5"), declaredMinOS: "16.0") { w in
            let out = await w.run()
            #expect(code(out) == "DEVICE_OS_TOO_OLD")
            #expect(out.data["minimumOS"] == "16.0")
            #expect(!extracted(w))
        }
        // The other way round: the binary's 15.0 is the stricter, so a declared 14.0 does not let 14.5 through.
        try await withSignWorld(script: SignScript(deviceOS: "14.5"), declaredMinOS: "14.0") { w in
            let out = await w.run()
            #expect(code(out) == "DEVICE_OS_TOO_OLD" && out.data["minimumOS"] == "15.0")
        }
    }

    @Test("a declared minimum counts as known; a declared minimum of 15.0 with the device at 15.0 passes the check")
    func declaredOnly() async throws {
        try await withSignWorld(app: .apollo, variant: .noMinOS, minOS: nil, declaredMinOS: "15.0") { w in
            let out = await w.run()
            #expect(out.ok, "\(out.errors)")
            #expect(out.data["deviceOS"]?["minimum"] == "15.0")
        }
        try await withSignWorld(app: .apollo, variant: .noMinOS, minOS: nil, declaredMinOS: "30.0") { w in
            #expect(code(await w.run()) == "DEVICE_OS_TOO_OLD", "a declared minimum alone is enforced")
        }
    }

    @Test("versions compare number by number: 15.10 is newer than 15.9, 15 equals 15.0.0")
    func numeric() {
        #expect(OSVersion.strictest(["15.0", "16.1", nil, "9.0"]) == "16.1")
        #expect(OSVersion.strictest([nil, nil]) == nil)
        #expect(OSVersion.strictest(["15.0", "beta"]) == "beta", "an unparsable value stays and fails the comparison")
        #expect(OSVersion.strictest(["beta", "99.0"]) == "beta")
        #expect(OSVersion.isAtLeast("15.10", "15.9") == true)
        #expect(OSVersion.isAtLeast("15.9", "15.10") == false)
        #expect(OSVersion.isAtLeast("15", "15.0.0") == true)
        #expect(OSVersion.isAtLeast("14.9.9", "15.0") == false)
        #expect(OSVersion.isAtLeast("26.0.1", "26.0") == true)
        #expect(OSVersion.isAtLeast("beta", "15.0") == nil)
        #expect(OSVersion.isAtLeast("15.0", "") == nil)
    }

    @Test("the OS comes from devicectl list devices, read once, and the saved config holds none")
    func source() async throws {
        try await withSignWorld(profile: .noRecord) { w in
            _ = await w.run()
            let listed = w.runner.calls.filter { $0.executable == "xcrun" }
            #expect(listed.count == 1)
            #expect(listed[0].args.prefix(3) == ["devicectl", "list", "devices"])
            let saved = try w.store.load().devices["iphone"]
            #expect(saved?.extra["osVersion"] == nil)
        }
    }

    @Test("no OS in the listing, or devicectl failing -> DEVICE_OS_UNKNOWN (the minimum cannot be checked)")
    func unknown() async throws {
        for script in [SignScript(deviceOS: nil), SignScript(devicectlFails: true)] {
            try await withSignWorld(script: script) { w in
                let out = await w.run()
                #expect(code(out) == "DEVICE_OS_UNKNOWN")
                #expect(!extracted(w))
            }
        }
    }

    @Test("a manifest entry with no inspectMinOS falls back to the unpacked app's own minimum")
    func fallback() async throws {
        try await withSignWorld(script: SignScript(deviceOS: "14.0"), minOS: nil) { w in
            let out = await w.run()
            #expect(code(out) == "DEVICE_OS_TOO_OLD")
            #expect(extracted(w), "the minimum came from the unpacked app")
            #expect(w.runner.signingArgs.isEmpty)
            #expect(w.leftovers.isEmpty)
        }
    }
}

@Suite("sign: the stored free profile")
struct SignProfileTests {
    @Test("a missing record or file -> PROFILE_MISSING with a fix that names provision")
    func missing() async throws {
        for mode in [ProfileMode.noRecord, .missingFile] {
            try await withSignWorld(profile: mode) { w in
                let out = await w.run()
                #expect(code(out) == "PROFILE_MISSING", "\(mode)")
                #expect(out.errors.first?.fix?.contains("sideload provision --app stremio-ios --device iphone --yes") == true)
                #expect(!extracted(w))
            }
        }
    }

    @Test("an expired profile -> PROFILE_EXPIRED, telling the owner to provision")
    func expired() async throws {
        try await withSignWorld(profile: .expired) { w in
            let out = await w.run()
            #expect(code(out) == "PROFILE_EXPIRED")
            #expect(out.errors.first?.fix?.contains("provision") == true)
            #expect(out.data["check"] == "expiry")
            #expect(!extracted(w))
        }
    }

    @Test("every other defect is PROFILE_INVALID naming the check, never profile content", arguments: [
        (ProfileMode.wrongTeam, "team"), (.wrongAppId, "application-identifier"), (.wrongPlatform, "platform"),
        (.noGetTaskAllow, "get-task-allow"), (.wrongDevice, "device"), (.wrongCertificate, "certificate"),
        (.farFuture, "expiry"), (.undecodable, "decode"), (.otherUUID, "uuid"), (.symlink, "stored-file"),
        (.foreignFile, "ledger-record"),
    ])
    func invalid(mode: ProfileMode, check: String) async throws {
        try await withSignWorld(profile: mode) { w in
            let out = await w.run()
            #expect(code(out) == "PROFILE_INVALID", "\(mode)")
            #expect(out.data["check"] == .string(check), "\(mode)")
            #expect(!extracted(w), "\(mode)")
            let text = try out.printed().text
            #expect(!text.contains(savedUdid("1")) && !text.contains(savedUdid("9")))
        }
    }

    @Test("the tvOS app checks the tvOS profile on the Apple TV")
    func tvos() async throws {
        try await withSignWorld(app: .stremioTVOS, profile: .wrongPlatform) { w in
            let out = await w.run()
            #expect(code(out) == "PROFILE_INVALID" && out.data["check"] == "platform")
        }
    }

    @Test("the manifest outranks the profile, and the OS outranks both")
    func order() async throws {
        try await withSignWorld(manifest: .none, profile: .noRecord) { w in
            #expect(code(await w.run()) == "NOT_APPROVED")
        }
        try await withSignWorld(profile: .noRecord, script: SignScript(deviceOS: "10.0")) { w in
            #expect(code(await w.run()) == "DEVICE_OS_TOO_OLD")
        }
    }
}
