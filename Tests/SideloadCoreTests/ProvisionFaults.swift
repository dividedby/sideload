import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// The failure points of `provision`, shared by the golden envelopes (`--renew` off; recorded before the result and
// error model was reworked, so they prove nothing changed without `--renew`) and the matrix (`--renew` on). A new
// case joins both through `CaseIterable`.

let faultUuid1 = "11111111-1111-1111-1111-111111111111"
let faultUuid2 = "22222222-2222-2222-2222-222222222222"

enum Fault: String, CaseIterable, Sendable {
    // Arguments, before anything runs.
    case usage, confirmRequired, deviceNotSaved, platformMismatch
    // Preflight.
    case keychainLocked, identityMissing, identityAmbiguous, appIdLimitBudget, staleMarkerChanged, staleMarkerClear
    // Before the renewal.
    case derivedDataNotCleared
    // The marker write (step 4); the renewal has run by now.
    case markerWriteFails
    // The build.
    case buildAccount, buildDeviceNotRegistered, buildAppIdLimit, buildDeviceLocked, buildNoCertificate, buildUnknown,
        buildTimeout, buildOverflow, buildSpawn
    // After the build.
    case afterKeychainUnreadable, freeCertChanged, freeCertChangedAfterFailedBuild
    case productMissing, profileUndecodable, embeddedDirectory
    case verifyTeam, verifyApplicationIdentifier, verifyPlatform, verifyGetTaskAllow, verifyDevice, verifyCertificate,
        verifyExpiry
    case pinAmbiguous, profileNotRenewed, successPinned, successSuspensionCleared, success
    // A write fails at a `ProvisionCheckpoint` (the hook throws in place of the write).
    case throwMarker, throwSuspension, throwMarkerClear, throwPin, throwStoreProfile, throwFinalLedger
    // The renewal itself (`--renew` only; without it these runs are plain successes). The two cached profiles are in two
    // folders, so "file 2" is the one in the second folder.
    case listDir2Fails, mkdirTmpFails, crossVolumeDev
    case forwardEACCES, forwardENOENT, forwardEXDEV, forwardEEXIST
    case lstatAfterRenameFails
    case moveBackEEXIST, moveBackENOENT, moveBackEACCES, moveBackEXDEV, moveBackEIO
    case sealedBeforeFile2, intentWriteFails

    /// Only meaningful with `--renew`: no golden envelope without it.
    var renewOnly: Bool {
        switch self {
        case .listDir2Fails, .mkdirTmpFails, .crossVolumeDev, .forwardEACCES, .forwardENOENT, .forwardEXDEV, .forwardEEXIST,
            .lstatAfterRenameFails, .moveBackEEXIST, .moveBackENOENT, .moveBackEACCES, .moveBackEXDEV, .moveBackEIO,
            .sealedBeforeFile2, .intentWriteFails:
            true
        default: false
        }
    }

    /// The checkpoint this fault throws at, if it is one of the `throw*` cases.
    var checkpoint: ProvisionCheckpoint? { (try? scenario())?.throwAt }
}

/// Counts calls; the injected failures are keyed on the call number.
final class CallCount: Sendable {
    private let n = Mutex(0)

    func next() -> Int { n.withLock { value in
        value += 1
        return value
    } }
}

/// The renewal's syscalls and journal, made to fail for one fault.
struct RenewFaults {
    var fs: @Sendable (RenewFS, ProvisionWorld) -> RenewFS = { fs, _ in fs }
    var journal: @Sendable (RenewJournal, RenewProgress) -> RenewJournal = { journal, _ in journal }
}

/// How to build the world for one fault and what to expect of it.
struct FaultScenario {
    var config = provisionConfig()
    var reads: [[KeychainCertificate]?]?
    var build: BuildScript?
    var options = ProvisionOptions(app: "stremio-ios", device: "iphone", yes: true)
    /// The error code of the envelope; nil for a success.
    var code: String?
    /// Whether the run gets as far as the `--renew` step (after the derived-data clear).
    var reachesRenew = true
    /// What fails inside the renewal.
    var renew = RenewFaults()
    /// The code when run with `--renew`, if it differs (nil: the same as `code`).
    var codeWithRenew: String??
    /// The checkpoint that throws in this scenario.
    var throwAt: ProvisionCheckpoint?
    /// Runs after the world exists, before the command (seeds the ledger, plants files).
    var prepare: @Sendable (ProvisionWorld) async throws -> Void = { _ in }
    /// Undoes what `prepare` changed that the temp-folder removal cannot (permissions).
    var cleanup: @Sendable (ProvisionWorld) -> Void = { _ in }
}

private func fp8(_ cert: KeychainCertificate) -> String { LedgerSync.fp8(cert.reference) }

extension Fault {
    /// Two of our cached profiles, one in each of Xcode's two folders (the world creates both).
    static func cache() throws -> [String: String] {
        [
            "xcode-cache-1/mine1.mobileprovision": try freeProfileXML(uuid: faultUuid1),
            "xcode-cache-2/mine2.mobileprovision": try freeProfileXML(uuid: faultUuid2),
        ]
    }

    func scenario() throws -> FaultScenario {
        let free = try freeKeychainCert()
        var s = FaultScenario()
        func failing(_ log: String) -> BuildScript {
            BuildScript(result: RunResult(code: 65, stderr: log))
        }
        func bad(_ xml: String) -> BuildScript { BuildScript(profile: xml) }
        switch self {
        case .usage:
            s.options = ProvisionOptions(device: "iphone", yes: true)
            (s.code, s.reachesRenew) = ("USAGE", false)
        case .confirmRequired:
            s.options.yes = false
            (s.code, s.reachesRenew) = ("CONFIRM_REQUIRED", false)
        case .deviceNotSaved:
            s.options.device = "nope"
            (s.code, s.reachesRenew) = ("DEVICE_NOT_SAVED", false)
        case .platformMismatch:
            s.options.app = "stremio-tvos"
            (s.code, s.reachesRenew) = ("PLATFORM_MISMATCH", false)
        case .keychainLocked:
            s.reads = [nil]
            (s.code, s.reachesRenew) = ("KEYCHAIN_LOCKED", false)
        case .identityMissing:
            s.reads = [[]]
            (s.code, s.reachesRenew) = ("FREE_IDENTITY_MISSING", false)
        case .identityAmbiguous:
            s.reads = [[free, otherFreeCert()]]
            (s.code, s.reachesRenew) = ("FREE_IDENTITY_AMBIGUOUS", false)
        case .appIdLimitBudget:
            s.prepare = { w in
                try await w.services.ledgerStore.update {
                    $0.freeAppIds = (0..<9).map { LedgerFreeAppId(bundleId: "io.github.dividedby.free.x\($0)", epochStart: daysFromNow(-1)) }
                }
            }
            (s.code, s.reachesRenew) = ("FREE_APP_ID_LIMIT", false)
        case .staleMarkerChanged:
            s.reads = [[free, otherFreeCert()]]
            s.prepare = { w in
                try await w.services.ledgerStore.update {
                    $0.freeProvisionInFlight = LedgerFreeInFlight(
                        beforeFp8: [fp8(free)], startedAt: daysFromNow(-1), app: "stremio-ios", device: "iphone")
                }
            }
            (s.code, s.reachesRenew) = ("FREE_CERT_CHANGED", false)
        case .staleMarkerClear:
            s.prepare = { w in
                try await w.services.ledgerStore.update {
                    $0.freeProvisionInFlight = LedgerFreeInFlight(
                        beforeFp8: [fp8(free)], startedAt: daysFromNow(-1), app: "stremio-ios", device: "iphone")
                }
            }
        case .derivedDataNotCleared:
            s.prepare = { w in
                let build = w.paths.builds + "/carrier-dd/Build"
                try FileManager.default.createDirectory(atPath: build + "/Products/Debug-iphoneos", withIntermediateDirectories: true)
                _ = chmod(build, 0o500)
            }
            s.cleanup = { w in _ = chmod(w.paths.builds + "/carrier-dd/Build", 0o700) }
            (s.code, s.reachesRenew) = ("DERIVED_DATA_NOT_CLEARED", false)
        case .markerWriteFails:
            // A directory where the ledger lock file belongs: every ledger update fails.
            s.prepare = { w in
                try? FileManager.default.removeItem(atPath: w.paths.ledgerLock)
                try FileManager.default.createDirectory(atPath: w.paths.ledgerLock, withIntermediateDirectories: true)
            }
            // With --renew the first thing to need the ledger is the record of the first move.
            (s.code, s.codeWithRenew) = ("IO_ERROR", "PROFILE_MOVE_FAILED")
        case .buildAccount:
            (s.build, s.code) = (failing("error: No Account for Team \"6ZU5Z6ZKK7\"."), "ACCOUNT_NOT_SIGNED_IN")
        case .buildDeviceNotRegistered:
            (s.build, s.code) = (failing("error: Your team has no devices from which to generate a provisioning profile."), "DEVICE_NOT_REGISTERED")
        case .buildAppIdLimit:
            (s.build, s.code) = (failing("error: You have reached the maximum number of App IDs for this period."), "FREE_APP_ID_LIMIT")
        case .buildDeviceLocked:
            (s.build, s.code) = (failing("error: The device is locked. Unlock the device and try again."), "DEVICE_LOCKED")
        case .buildNoCertificate:
            (s.build, s.code) = (failing("error: No signing certificate \"Apple Development\" found"), "FREE_IDENTITY_MISSING")
        case .buildUnknown:
            (s.build, s.code) = (failing("noise\nerror: something odd happened\n"), "PROVISION_FAILED")
        case .buildTimeout:
            (s.build, s.code) = (BuildScript(result: RunResult(code: nil, timedOut: true)), "BUILD_TIMEOUT")
        case .buildOverflow:
            (s.build, s.code) = (BuildScript(result: RunResult(code: nil, overflow: true)), "OUTPUT_LIMIT")
        case .buildSpawn:
            (s.build, s.code) = (BuildScript(result: RunResult(code: nil, spawnError: "ENOENT")), "PROVISION_FAILED")
        case .afterKeychainUnreadable:
            (s.reads, s.code) = ([[free], nil], "IDENTITY_CHECK_FAILED")
        case .freeCertChanged:
            (s.reads, s.code) = ([[free], [free, otherFreeCert()]], "FREE_CERT_CHANGED")
        case .freeCertChangedAfterFailedBuild:
            (s.reads, s.build, s.code) = ([[free], [free, otherFreeCert()]], failing("error: odd"), "FREE_CERT_CHANGED")
        case .productMissing:
            var build = BuildScript(profile: try freeProfileXML())
            build.createApp = false
            (s.build, s.code) = (build, "BUILD_PRODUCT_MISSING")
        case .profileUndecodable:
            (s.build, s.code) = (BuildScript(profile: "not a plist"), "PROFILE_INVALID")
        case .embeddedDirectory:
            var build = BuildScript(profile: nil)
            build.embedAsDirectory = true
            (s.build, s.code) = (build, "PROFILE_INVALID")
        case .verifyTeam:
            (s.build, s.code) = (bad(try freeProfileXML(team: Team.paid, applicationIdentifier: Team.paid + "." + stremioId)), "PROFILE_INVALID")
        case .verifyApplicationIdentifier:
            (s.build, s.code) = (bad(try freeProfileXML(applicationIdentifier: Team.free + ".*")), "PROFILE_INVALID")
        case .verifyPlatform:
            (s.build, s.code) = (bad(try freeProfileXML(platform: ["tvOS"])), "PROFILE_INVALID")
        case .verifyGetTaskAllow:
            (s.build, s.code) = (bad(try freeProfileXML(getTaskAllow: false)), "PROFILE_INVALID")
        case .verifyDevice:
            (s.build, s.code) = (bad(try freeProfileXML(devices: [savedUdid("9")])), "PROFILE_INVALID")
        case .verifyCertificate:
            (s.build, s.code) = (bad(try freeProfileXML(certs: [try certDER(TestCerts.paid)])), "PROFILE_INVALID")
        case .verifyExpiry:
            (s.build, s.code) = (bad(try freeProfileXML(expires: daysFromNow(-1))), "PROFILE_INVALID")
        case .pinAmbiguous:
            var expired = free
            expired.info.notAfter = daysFromNow(-1)
            (s.reads, s.code) = ([[free], [expired]], "FREE_IDENTITY_AMBIGUOUS")
        case .profileNotRenewed:
            s.prepare = { w in
                try await w.services.ledgerStore.update {
                    $0.freeProfiles = [
                        LedgerFreeProfile(
                            id: "iphone/stremio-ios", device: "iphone", deviceTail: "…0001", app: "stremio-ios", bundleId: stremioId,
                            profileUuid: "AAAAAAAA-0000-0000-0000-000000000001", created: daysFromNow(0), expires: daysFromNow(7),
                            certFp8: "00000000", file: "profiles/free/old")
                    ]
                }
            }
            s.code = "PROFILE_NOT_RENEWED"
        case .successPinned:
            s.config = provisionConfig(extra: ["freeTeam": ["certFp8": .string(fp8(free))]])
        case .successSuspensionCleared:
            s.prepare = { w in
                try await w.services.ledgerStore.update {
                    $0.freeSuspended = LedgerFreeSuspension(code: "FREE_CERT_CHANGED", at: daysFromNow(-1))
                }
            }
        case .success: break
        case .listDir2Fails:
            s.renew.fs = { fs, w in
                var fs = fs
                let (base, dir2) = (fs.list, w.cacheDirs[1])
                fs.list = { path in
                    if path == dir2 { throw POSIXError(.EACCES) }
                    return try base(path)
                }
                return fs
            }
            (s.code, s.codeWithRenew) = (nil, "PROFILES_UNREADABLE")
        case .mkdirTmpFails:
            s.renew.fs = { fs, _ in
                var fs = fs
                fs.mkdir = { _ in throw POSIXError(.EACCES) }
                return fs
            }
            (s.code, s.codeWithRenew) = (nil, "PROFILE_MOVE_FAILED")
        case .crossVolumeDev:
            s.renew.fs = { fs, w in
                var fs = fs
                let (base, dir2) = (fs.stat, w.cacheDirs[1])
                fs.stat = { path in
                    var st = base(path)
                    if path == dir2 { st?.st_dev += 1 }
                    return st
                }
                return fs
            }
            (s.code, s.codeWithRenew) = (nil, "RENEW_CROSS_VOLUME")
        case .forwardEACCES, .forwardENOENT, .forwardEXDEV, .forwardEEXIST:
            let errnoValue: Int32 = self == .forwardEACCES ? EACCES : self == .forwardENOENT ? ENOENT : self == .forwardEXDEV ? EXDEV : EEXIST
            // File 2's forward rename fails (every try, for EEXIST); the file stays where it is.
            s.renew.fs = { fs, _ in
                var fs = fs
                let (base, calls) = (fs.renameExcl, CallCount())
                fs.renameExcl = { from, to in
                    let call = calls.next()
                    return call >= 2 ? errnoValue : base(from, to)
                }
                return fs
            }
            (s.code, s.codeWithRenew) = (nil, self == .forwardEXDEV ? "RENEW_CROSS_VOLUME" : "PROFILE_MOVE_FAILED")
        case .lstatAfterRenameFails, .moveBackEEXIST, .moveBackENOENT, .moveBackEACCES, .moveBackEXDEV, .moveBackEIO:
            // File 2 lands in tmp/ but its check fails, so it is moved back; with a move-back errno it stays as a stray.
            let back: Int32? =
                switch self {
                case .moveBackEEXIST: EEXIST
                case .moveBackENOENT: ENOENT
                case .moveBackEACCES: EACCES
                case .moveBackEXDEV: EXDEV
                case .moveBackEIO: EIO
                default: nil
                }
            s.renew.fs = { fs, w in
                var fs = fs
                let tmpPrefix = w.paths.tmp + "/"
                let (baseLstat, baseRename, lstats, renames) = (fs.lstat, fs.renameExcl, CallCount(), CallCount())
                fs.lstat = { path in
                    if path.hasPrefix(tmpPrefix), lstats.next() == 2 { return nil }
                    return baseLstat(path)
                }
                fs.renameExcl = { from, to in
                    if renames.next() == 3, let back { return back }
                    return baseRename(from, to)
                }
                return fs
            }
        case .sealedBeforeFile2:
            s.renew.journal = { journal, progress in
                var journal = journal
                let (base, calls) = (journal.intent, CallCount())
                journal.intent = { entry in
                    if calls.next() == 2 { _ = progress.seal() }
                    return await base(entry)
                }
                return journal
            }
            (s.code, s.codeWithRenew) = (nil, "INTERRUPTED")
        case .intentWriteFails:
            s.renew.journal = { journal, _ in
                var journal = journal
                let (base, calls) = (journal.intent, CallCount())
                journal.intent = { entry in
                    if calls.next() == 2 { return false }
                    return await base(entry)
                }
                return journal
            }
            (s.code, s.codeWithRenew) = (nil, "PROFILE_MOVE_FAILED")
        case .throwMarker: (s.throwAt, s.code) = (.markerWrite, "IO_ERROR")
        case .throwSuspension:
            (s.reads, s.throwAt, s.code) = ([[free], [free, otherFreeCert()]], .afterBuildWrite, "FREE_CERT_CHANGED")
        case .throwMarkerClear: (s.throwAt, s.code) = (.afterBuildWrite, "IO_ERROR")
        case .throwPin: (s.throwAt, s.code) = (.pinWrite, "IO_ERROR")
        case .throwStoreProfile: (s.throwAt, s.code) = (.storeProfile, "IO_ERROR")
        case .throwFinalLedger: (s.throwAt, s.code) = (.finalLedgerWrite, "IO_ERROR")
        }
        return s
    }
}

/// Builds the world for `fault` (two of our profiles cached), prepares it and calls `body`; `cleanup` runs after.
func withFaultWorld(
    _ fault: Fault, leftover: Bool = false, _ body: (ProvisionWorld, FaultScenario) async throws -> Void
) async throws {
    let scenario = try fault.scenario()
    try await withProvisionWorld(
        config: scenario.config, reads: scenario.reads, build: scenario.build, cache: try Fault.cache()
    ) { (w: ProvisionWorld) async throws in
        defer { scenario.cleanup(w) }
        // An entry an earlier --renew run left, planted before the scenario can break the ledger.
        if leftover {
            try await w.services.ledgerStore.update {
                $0.freeRenewMoves = [
                    LedgerFreeRenewMove(
                        from: "old.mobileprovision", to: "tmp/renewed-profile-0123456789ab.mobileprovision", at: testNow,
                        state: .done, folder: "xcode-userdata")
                ]
            }
        }
        try await scenario.prepare(w)
        try await body(w, scenario)
    }
}

/// Runs the command in `w` with the scenario's failures injected, with or without `--renew`.
func runFault(_ w: ProvisionWorld, _ scenario: FaultScenario, renew: Bool = false) async -> Envelope {
    var hooks = ProvisionHooks()
    if let target = scenario.throwAt {
        hooks.checkpoint = { point in
            if point == target { throw SideloadError("IO_ERROR", "injected fault at \(point.rawValue)") }
        }
    }
    hooks.renewFS = scenario.renew.fs(.live, w)
    let (progress, wrap) = (hooks.renewProgress, scenario.renew.journal)
    hooks.renewJournal = { wrap($0, progress) }
    var options = scenario.options
    options.renew = renew
    return await ProvisionCommand.run(w.services, options, hooks: hooks)
}

extension FaultScenario {
    /// The error code of the envelope when run with `--renew`.
    var expectedCode: String? {
        if let override = codeWithRenew { return override }
        return code
    }
}
