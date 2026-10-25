import Foundation

// Shared front and device calls of the free-team commands that act on a device: `install`, `app remove`,
// `slot lend` and `slot return` (design section 18). Each takes `.op.lock` first, settles the crash-safe marker
// before anything else, and reaches the device only through `DeviceCtl` in the free scope.

/// A saved device and a free-team app, validated: the app is ours (`<prefix>.free.*`), the device is saved, has an ID
/// and its platform fits the app.
struct FreeTarget: Sendable {
    let app: ProvisionApp
    let alias: String
    let config: Config
    let prefix: String
    let bundleId: String
    let device: ResolvedDevice
    let udid: String

    var key: String { "\(alias)/\(app.rawValue)" }

    /// Usage, config, then the saved device and its platform, in that order. Throws a `SideloadError`.
    static func resolve(app appName: String?, device alias: String?, services: Services, usageFix: String) throws -> FreeTarget {
        guard let appName, !appName.isEmpty, let alias, !alias.isEmpty else {
            throw SideloadError("USAGE", "This command needs --app and --device <alias>.", fix: usageFix)
        }
        let app = try parseApp(appName)
        let config = try services.store.load()
        return try resolve(app: app, alias: alias, config: config)
    }

    static func parseApp(_ appName: String) throws -> ProvisionApp {
        guard let app = ProvisionApp(rawValue: appName) else {
            throw SideloadError(
                "USAGE", "Unknown app \"\(printableCut(appName))\".", fix: "Use one of: \(ProvisionApp.names.joined(separator: ", ")).")
        }
        return app
    }

    static func resolve(app: ProvisionApp, alias: String, config: Config) throws -> FreeTarget {
        guard let prefix = config.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix) else {
            throw SideloadError(
                "CONFIG_MISSING", "bundleIdPrefix is missing or invalid in config.json.",
                fix: "Add \"bundleIdPrefix\": \"com.yourname\" to $SIDELOAD_HOME/config.json.")
        }
        let bundleId = prefix + ".free." + app.suffix
        guard Config.isFreeBundleId(bundleId, prefix: prefix) else {
            throw SideloadError(
                "BUNDLE_ID_NOT_ALLOWED", "The free team may only be used for the configured <prefix>.free. namespace.",
                fix: "Check bundleIdPrefix in config.json.")
        }
        guard config.devices[alias] != nil else {
            throw SideloadError(
                "DEVICE_NOT_SAVED", "No saved device with alias \"\(printableAlias(alias))\".",
                fix: "sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        let device = try config.requireDevice(alias)
        guard DeviceCommand.isValidAlias(alias), let udid = device.udid, !udid.isEmpty else {
            throw SideloadError(
                "DEVICE_NOT_SAVED", "The saved device has no UDID, which the profile check needs.",
                fix: "Re-save it: sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        guard device.platform == app.devicePlatform else {
            throw SideloadError(
                "PLATFORM_MISMATCH",
                "\(app.rawValue) needs a \(app.devicePlatform) device; the saved device is \(device.platform ?? "of unknown platform").",
                fix: app == .stremioTVOS
                    ? "Use --device with a saved Apple TV (tvos)." : "Use --device with a saved iPhone or iPad (ios).")
        }
        return FreeTarget(
            app: app, alias: alias, config: config, prefix: prefix, bundleId: bundleId, device: device, udid: udid)
    }

    /// The target's identifying fields, merged into every envelope the command prints. Aliases only.
    var identity: [String: JSONValue] {
        ["app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId)]
    }

    /// The device's owner-set reserve (`CONFIG_INVALID` when out of range).
    func reserved() throws -> Int {
        guard let saved = config.devices[alias] else {
            throw SideloadError("DEVICE_NOT_SAVED", "No saved device with alias \"\(alias)\".")
        }
        return try saved.requireFreeSlotsReserved(alias: alias)
    }
}

extension FreeInstallFailure {
    var error: SideloadError {
        var data: [String: JSONValue] = [:]
        if let deviceCode { data["deviceCode"] = .string(deviceCode) }
        return SideloadError(code, reason, fix: fix, data: data)
    }
}

/// A user-typed alias for a message. A value that looks like a device ID (a UDID or CoreDevice ID passed to `--device` by
/// mistake) is shown as its last four characters only.
func printableAlias(_ value: String) -> String {
    if value.wholeMatch(of: /[0-9A-Fa-f][0-9A-Fa-f-]{15,}/) != nil { return Redactor.tail4(value) }
    return printableCut(value)
}

/// Whole seconds, so what is recorded survives the ledger's ISO 8601 round trip unchanged.
func wholeSeconds(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

enum FreeSession {
    /// The keychain read and `FreeIdentityGuard.settleInFlight`, before anything else. A locked keychain is
    /// `KEYCHAIN_LOCKED`; a marker whose identity set changed is `FREE_CERT_CHANGED` (the ledger then carries
    /// `freeSuspended`). Call it under `.op.lock`.
    static func settle(_ services: Services, now: Date) async throws -> [KeychainCertificate] {
        let identities: [KeychainCertificate]
        do {
            identities = try services.keychain.developmentIdentities()
        } catch {
            throw SideloadError(
                "KEYCHAIN_LOCKED", "The keychain could not be read; it is probably locked.",
                fix: "Unlock the login keychain (open Keychain Access, or log in again) and retry.")
        }
        if let change = try await FreeIdentityGuard.settleInFlight(
            ledgerStore: services.ledgerStore, current: identities, now: now)
        {
            throw SideloadError(
                "FREE_CERT_CHANGED",
                "The free team's signing identities changed during an earlier run that did not finish (\(change.addedFp8.count) added, \(change.removedFp8.count) removed). Nothing was changed on the device.",
                fix: "Auto-refresh is suspended. The owner checks Xcode > Settings > Accounts > Manage Certificates, atvloadly and the lab (something created or revoked a free certificate). Run provision by hand once satisfied.",
                data: [
                    "identityChanged": true, "suspended": true,
                    "addedFp8": .array(change.addedFp8.map { .string($0) }),
                    "removedFp8": .array(change.removedFp8.map { .string($0) }),
                ])
        }
        return identities
    }

    /// The pinned free identity, as `sign` resolves it.
    static func pinned(_ identities: [KeychainCertificate], config: Config, app: String, alias: String, now: Date) throws
        -> (identity: FreeIdentity, reference: CertReference)
    {
        guard let pinnedFp8 = try config.freeTeamCertFp8() else {
            throw SideloadError(
                "FREE_IDENTITY_NOT_PINNED", "No free-team identity is pinned yet, so the signed app cannot be checked.",
                fix: "The owner runs `sideload provision --app \(app) --device \(alias) --yes` first; its first success pins the identity.")
        }
        let identity: FreeIdentity
        switch CertCheck.pinnedFree(identities, fp8: pinnedFp8, now: now) {
        case .found(let found): identity = found
        case .notFound:
            throw SideloadError(
                "FREE_IDENTITY_MISSING",
                "The pinned free-team identity (\(pinnedFp8)) is not in the keychain, or is expired or untrusted.",
                fix: "Check Xcode > Settings > Accounts > Manage Certificates and the login keychain (owner action). sideload never creates a certificate.",
                data: ["pinnedFp8": .string(pinnedFp8)])
        case .ambiguous:
            throw SideloadError(
                "FREE_IDENTITY_AMBIGUOUS", "More than one valid free-team identity has the pinned fingerprint prefix.",
                fix: "The owner removes the duplicate in Keychain Access; sideload does not delete keychain items.",
                data: ["pinnedFp8": .string(pinnedFp8)])
        }
        guard let reference = CertReference(identity.sha1) else {
            throw SideloadError(
                "FREE_IDENTITY_MISSING", "The pinned free-team identity has no usable fingerprint.",
                fix: "Check the login keychain (owner action).")
        }
        return (identity, reference)
    }
}

/// `devicectl` calls for one free app on one saved device, always in the free scope.
struct FreeDeviceCalls: Sendable {
    let services: Services
    let alias: String
    let bundleId: String

    struct Outcome: Sendable {
        var code: Int32?
        var json: JSONValue?
        var stderr = ""
        var timedOut = false
        var overflow = false
        var spawnError: String?
    }

    func call(_ args: [String], timeoutSec: Int, positional: [String] = []) async throws -> Outcome {
        do {
            let res = try await services.deviceCtl.run(
                args, deviceAlias: alias, timeoutSec: timeoutSec, positional: positional, scope: .free(bundleId: bundleId))
            return Outcome(
                code: res.code, json: res.json, stderr: res.stderr, timedOut: res.timedOut, spawnError: res.spawnError)
        } catch let error as SideloadError where error.code == "OUTPUT_LIMIT" {
            // A device outcome, like the canary's: the caller classifies it.
            return Outcome(overflow: true)
        }
    }

    /// Whether the device may still finish (or may already have finished) an install or uninstall this call did not see
    /// complete: the Runner's timeout, devicectl's own `--timeout` (exit non-zero, classified `TIMEOUT`, with `timedOut`
    /// false), an output overflow, or a child killed by a signal (no exit code, no spawn error); a call that threw counts
    /// too (see `uninstall` and `FreeInstallRun.perform`). Every such result is `unknown` in `SlotRule`: settled only by
    /// the table's target state or by a snapshot taken after the op's window. A spawn error never ran anything, so it is not.
    func uncertain(_ out: Outcome, _ failure: FreeInstallFailure?) -> Bool {
        out.timedOut || out.overflow || (out.code == nil && out.spawnError == nil) || failure?.code == "TIMEOUT"
    }

    func classify(_ operation: FreeInstallClassifier.Operation, _ out: Outcome) -> FreeInstallFailure? {
        FreeInstallClassifier.failure(
            operation, exitCode: out.code, json: out.json, stderr: out.stderr, timedOut: out.timedOut,
            overflow: out.overflow, spawnError: out.spawnError, bundleId: bundleId)
    }

    /// `devicectl device info apps`, parsed. A failure is classified (`DEVICE_LOCKED`, ...), else `SNAPSHOT_FAILED`.
    func snapshot() async throws -> AppSnapshot {
        let out = try await call(["device", "info", "apps"], timeoutSec: 60)
        if let failure = classify(.snapshot, out) { throw failure.error }
        guard let snapshot = AppSnapshot.parse(out.json) else {
            throw SideloadError(
                "SNAPSHOT_FAILED", "devicectl did not return a readable list of the device's apps.",
                fix: "Unlock the device, keep it awake and retry.")
        }
        return snapshot
    }

    /// The read-only `devicectl device profile list --type provisioning`, reduced to the bundle IDs with a free-team profile.
    /// Never throws and never stops a command: a failed, timed-out, overflowing or malformed read is nil, and the slot count
    /// then falls back to the reserve (installd's refusal stays the backstop). Run once per command, near the snapshot.
    func freeProfiles() async -> FreeTeamProfiles? {
        guard
            let out = try? await call(["device", "profile", "list", "--type", "provisioning"], timeoutSec: 60),
            out.code == 0, !out.timedOut, !out.overflow, out.spawnError == nil
        else { return nil }
        return FreeTeamProfiles.parse(out.json)
    }

    // MARK: app data (backup and restore; `AppDataBackup` is the only caller)

    /// A device call that never throws: a refusal or any other failure comes back as an outcome with no exit code and a
    /// spawn error, so the caller (backup, restore) counts it and goes on.
    private func quietCall(_ args: [String], timeoutSec: Int) async -> Outcome {
        do {
            return try await call(args, timeoutSec: timeoutSec)
        } catch {
            return Outcome(spawnError: "CALL_FAILED")
        }
    }

    private var appDataFlags: [String] {
        ["--domain-type", DeviceCtl.appDataDomain, "--domain-identifier", bundleId]
    }

    /// `devicectl device info files --domain-type appDataContainer --domain-identifier <id> --recurse`.
    func listFiles(timeoutSec: Int) async -> Outcome {
        await quietCall(["device", "info", "files"] + appDataFlags + ["--recurse"], timeoutSec: timeoutSec)
    }

    /// `devicectl device copy from ...`: one file out of the app's data container into `destination` (under `backups/`).
    func copyFrom(source: String, destination: String, timeoutSec: Int) async -> Outcome {
        await copy("from", source: source, destination: destination, timeoutSec: timeoutSec)
    }

    /// `devicectl device copy to ...`: one file from `source` (under `backups/`) into the app's data container.
    func copyTo(source: String, destination: String, timeoutSec: Int) async -> Outcome {
        await copy("to", source: source, destination: destination, timeoutSec: timeoutSec)
    }

    private func copy(_ direction: String, source: String, destination: String, timeoutSec: Int) async -> Outcome {
        await quietCall(
            ["device", "copy", direction] + appDataFlags + ["--source", source, "--destination", destination], timeoutSec: timeoutSec)
    }

    /// One snapshot read as data: the callers that already changed (or may have changed) the device need the failure as data,
    /// not as a throw that skips their durable bookkeeping. `takenAt` is the clock read BEFORE `device info apps` starts
    /// (the evidence rule of `SlotRule` compares it with an op's window).
    struct SnapshotRead: Sendable {
        let snapshot: AppSnapshot?
        let error: SideloadError?
        let takenAt: Date
    }

    func trySnapshot() async -> SnapshotRead {
        let takenAt = services.clock.now()
        do {
            return SnapshotRead(snapshot: try await snapshot(), error: nil, takenAt: takenAt)
        } catch {
            return SnapshotRead(
                snapshot: nil,
                error: (error as? SideloadError) ?? SideloadError("SNAPSHOT_FAILED", "The device's app list could not be read."),
                takenAt: takenAt)
        }
    }

    /// What a device call reported, as the table of `SlotRule` reads it.
    func result<Failure>(_ failure: Failure?, uncertain: Bool) -> SlotRule.Result {
        uncertain ? .unknown : (failure == nil ? .success : .failure)
    }

    /// One uninstall. A device outcome never throws: the failure (classified) and the result come back as data, and a fresh
    /// snapshot, not this result, decides what happened. `unknown` covers every shape `uncertain` names; a call that threw
    /// (cancelled, or failed in a way that may have reached the device) counts too.
    func uninstall() async -> (failure: SideloadError?, result: SlotRule.Result) {
        do {
            let out = try await call(["device", "uninstall", "app"], timeoutSec: SlotState.uninstallTimeoutSec, positional: [bundleId])
            let failure = classify(.uninstall, out)
            return (failure?.error, result(failure, uncertain: uncertain(out, failure)))
        } catch {
            return ((error as? SideloadError) ?? SideloadError("UNINSTALL_FAILED", "The uninstall did not finish."), .unknown)
        }
    }
}

/// An `UNEXPECTED_APP_DELTA` stop: counts only, never the other apps' IDs.
func unexpectedDelta(_ delta: AppSnapshot.Delta, expectation: String, extra: [String: JSONValue] = [:]) -> SideloadError {
    var data: [String: JSONValue] = [
        "addedCount": .number(Double(delta.added.count)), "removedCount": .number(Double(delta.removed.count)),
    ]
    data.merge(extra) { _, new in new }
    return SideloadError(
        "UNEXPECTED_APP_DELTA", "The device's app list changed in a way this command does not explain (\(expectation)).",
        fix: "A hard stop: check the device by hand. If our app landed wrongly, the owner can `sideload app remove` it.",
        data: data)
}
