import Darwin
import Foundation

public struct SignOptions: Sendable, Equatable {
    public var app: String?
    public var device: String?
    /// Owner confirmation; agents must not pass it (signing uses the free certificate's private key).
    public var yes: Bool
    /// `--version <v>`: sign exactly this fetched, approved version instead of the newest approved one. The menu's Add app,
    /// Update and Reinstall previous version set it so a different approved version never replaces the one the owner
    /// confirmed. Nil signs the newest approved version.
    public var version: String?

    public init(app: String? = nil, device: String? = nil, yes: Bool = false, version: String? = nil) {
        self.app = app
        self.device = device
        self.yes = yes
        self.version = version
    }
}

/// `sign --app <a> --device <d>`: turns the newest approved, fetched IPA and the stored free-team profile into a signed
/// `.app` for one saved device (design section 18, "`sign` (free)"). Nothing is installed and no device is contacted
/// beyond one `devicectl list devices` (for the device's OS).
///
/// Free-team narrow use: only `<prefix>.free.*`, only the pinned identity (`codesign -s <sha1>`, never a name), the
/// shared `.op.lock` held throughout, and `FreeIdentityGuard.settleInFlight` before anything else. Every extension and
/// watch app is stripped (one App ID per app), the bundle ID is rewritten, the entitlements are reduced to what the
/// free profile grants, and `Guard.run(context: .free)` must pass before the result is moved to
/// `builds/signed/<app>/<device>/<Name>.app` and recorded in the ledger's `freeSigned`.
public enum SignCommand {
    static let command = "sign"
    static let toolTimeout = Duration.seconds(30)

    public static func run(_ services: Services, _ options: SignOptions) async -> Envelope {
        await run(services, options, registry: .shared)
    }

    static func run(
        _ services: Services, _ options: SignOptions, registry: ScratchRegistry, hooks: SignHooks = SignHooks()
    ) async -> Envelope {
        do {
            return try await execute(services, options, registry: registry, hooks: hooks)
        } catch {
            return .from(error, command: command)
        }
    }

    private static func execute(
        _ services: Services, _ options: SignOptions, registry: ScratchRegistry, hooks: SignHooks
    ) async throws -> Envelope {
        guard let appName = options.app, !appName.isEmpty, let alias = options.device, !alias.isEmpty else {
            return .fail(
                command, code: "USAGE", message: "sign needs --app and --device <alias>.",
                fix: "sideload sign --app <\(ProvisionApp.signedBySign.map(\.rawValue).joined(separator: "|"))> --device iphone [--version <v>] --yes")
        }
        if options.version?.isEmpty == true {
            return .fail(
                command, code: "USAGE", message: "--version needs a version.",
                fix: "sideload sign --app <app> --device <alias> --version <v> --yes")
        }
        guard let app = ProvisionApp(rawValue: appName) else {
            return .fail(
                command, code: "USAGE", message: "Unknown app \"\(printableCut(appName))\".",
                fix: "Use one of: \(ProvisionApp.signedBySign.map(\.rawValue).joined(separator: ", ")).")
        }
        guard !app.signedByProvision else {
            return .fail(
                command, code: "USAGE", message: "\(app.rawValue) is signed by provision, not by sign.",
                fix: "sideload provision --app \(app.rawValue) --device <alias> --yes")
        }
        let config = try services.store.load()
        guard let prefix = config.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix) else {
            return .fail(
                command, code: "CONFIG_MISSING", message: "bundleIdPrefix is missing or invalid in config.json.",
                fix: "Add \"bundleIdPrefix\": \"com.yourname\" to $SIDELOAD_HOME/config.json.")
        }
        let bundleId = prefix + ".free." + app.suffix
        guard Config.isFreeBundleId(bundleId, prefix: prefix) else {
            return .fail(
                command, code: "BUNDLE_ID_NOT_ALLOWED",
                message: "The free team may only be used for the configured <prefix>.free. namespace.",
                fix: "Check bundleIdPrefix in config.json.")
        }
        let device = try config.requireDevice(alias)
        guard DeviceCommand.isValidAlias(alias), let udid = device.udid, !udid.isEmpty else {
            return .fail(
                command, code: "DEVICE_NOT_SAVED", message: "The saved device has no UDID, which the profile check needs.",
                fix: "Re-save it: sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        guard device.platform == app.devicePlatform else {
            return .fail(
                command, code: "PLATFORM_MISMATCH",
                message:
                    "\(app.rawValue) needs a \(app.devicePlatform) device; the saved device is \(device.platform ?? "of unknown platform").",
                fix: app == .stremioTVOS
                    ? "Use --device with a saved Apple TV (tvos)." : "Use --device with a saved iPhone or iPad (ios).",
                data: ["app": .string(app.rawValue), "device": .string(alias)])
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message:
                    "sign uses the free team's signing key (the login keychain may ask) and writes a signed copy of \(app.rawValue) for this device.",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: ["app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId)])
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        let run = SignRun(
            services: services, registry: registry, config: config, prefix: prefix, app: app, alias: alias, device: device,
            udid: udid, bundleId: bundleId, version: options.version, hooks: hooks)
        return await run.execute()
    }
}

/// Test seams. The defaults do nothing, so production behaviour is the same with and without them.
struct SignHooks: Sendable {
    /// Runs right before the ledger write; throwing makes that write fail.
    var beforeLedgerWrite: @Sendable () throws -> Void = {}
    /// Replaces the undo of a placement after a failed ledger write (true: restored); nil does the real rename.
    var restore: (@Sendable (_ swapped: Bool, _ scratchApp: String, _ destination: String) -> Bool)?
}

/// What a step produced, or the envelope that ends the run. No optional-with-`!` pairs.
private enum Step<Value> {
    case value(Value)
    case stop(Envelope)
}

extension SignCommand {
    /// Undoes `place`: after a swap, swaps back (the old app returns, the new one lands in the scratch folder); after a
    /// plain placement, moves the new app back out into the scratch folder. True when the destination is as it was.
    static func restore(swapped: Bool, scratchApp: String, destination: String) -> Bool {
        if swapped { return renamex_np(scratchApp, destination, UInt32(RENAME_SWAP)) == 0 }
        return rename(destination, scratchApp) == 0
    }

    /// Puts the signed app at `destination` in one rename: `RENAME_EXCL` when nothing is there, else `RENAME_SWAP`,
    /// which exchanges the two atomically (the previous signed app ends up at `source`, inside the scratch folder that
    /// is removed afterwards). The destination is complete or it is the old one; never half of each.
    /// Returns true when it swapped with an app that was already there.
    static func place(_ source: String, at destination: String) throws -> Bool {
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return false }
        guard errno == EEXIST else { throw ioError("rename") }
        guard renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else { throw ioError("rename") }
        return true
    }

    /// A `sign-*` scratch folder left by a run that was killed (SIGKILL or a crash skips the registry's cleanup). Safe to
    /// remove: the operation lock means no other sign is running.
    fileprivate static func sweepStaleScratch(in tmp: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("sign-") {
            _ = ScratchDirectory.removeTree(tmp + "/" + name)
        }
    }
}

/// Dotted OS versions (`15.0`, `26.0.1`).
enum OSVersion {
    static func parse(_ text: String) -> [Int]? {
        guard text.wholeMatch(of: /[0-9]{1,5}(\.[0-9]{1,5}){0,3}/) != nil else { return nil }
        return text.split(separator: ".").compactMap { Int($0) }
    }

    /// The stricter (higher) of the minimum OS versions that are known. A value that is not a version number wins, so
    /// the comparison against it fails closed (`DEVICE_OS_UNKNOWN`). Nil when none is known.
    static func strictest(_ values: [String?]) -> String? {
        var best: String?
        for value in values.compactMap({ $0 }) {
            guard let current = best else {
                best = value
                continue
            }
            if OSVersion.parse(current) == nil { continue }
            if OSVersion.parse(value) == nil || OSVersion.isAtLeast(value, current) == true { best = value }
        }
        return best
    }

    /// Whether `have` is at least `need`; nil when either does not parse. Missing components count as 0.
    static func isAtLeast(_ have: String, _ need: String) -> Bool? {
        guard let h = parse(have), let n = parse(need) else { return nil }
        for i in 0..<max(h.count, n.count) {
            let (a, b) = (i < h.count ? h[i] : 0, i < n.count ? n[i] : 0)
            if a != b { return a > b }
        }
        return true
    }
}

/// One `sign` run: the state shared by its steps.
private struct SignRun {
    let services: Services
    let registry: ScratchRegistry
    let config: Config
    let prefix: String
    let app: ProvisionApp
    let alias: String
    let device: ResolvedDevice
    let udid: String
    let bundleId: String
    let now: Date
    /// The one version to sign; nil signs the newest approved one.
    let version: String?
    let hooks: SignHooks

    init(
        services: Services, registry: ScratchRegistry, config: Config, prefix: String, app: ProvisionApp, alias: String,
        device: ResolvedDevice, udid: String, bundleId: String, version: String?, hooks: SignHooks
    ) {
        self.version = version
        self.hooks = hooks
        self.services = services
        self.registry = registry
        self.config = config
        self.prefix = prefix
        self.app = app
        self.alias = alias
        self.device = device
        self.udid = udid
        self.bundleId = bundleId
        // Whole seconds, so what is recorded survives the ledger's ISO 8601 round trip unchanged.
        now = Date(timeIntervalSince1970: services.clock.now().timeIntervalSince1970.rounded(.down))
    }

    var key: String { "\(alias)/\(app.rawValue)" }

    private func log(_ message: String) { services.log(message) }

    private func fail(
        _ code: String, _ message: String, _ fix: String, _ extra: [String: JSONValue] = [:]
    ) -> Envelope {
        var data: [String: JSONValue] = [
            "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId),
        ]
        data.merge(extra) { _, new in new }
        return .fail(SignCommand.command, code: code, message: message, fix: fix, data: data)
    }

    /// The single exit: a thrown `SideloadError` keeps its code and gains the app, device and bundle ID.
    func execute() async -> Envelope {
        do {
            return try await steps()
        } catch let error as SideloadError {
            var data: [String: JSONValue] = [
                "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId),
            ]
            data.merge(error.data) { _, new in new }
            return .fail(SignCommand.command, code: error.code, message: error.message, fix: error.fix, data: data)
        } catch {
            return .from(error, command: SignCommand.command)
        }
    }

    private func steps() async throws -> Envelope {
        // 1. The pinned identity, after the crash-safe marker is settled (nothing else comes first).
        log("sign: preflight")
        let identities: [KeychainCertificate]
        do {
            identities = try services.keychain.developmentIdentities()
        } catch {
            return fail(
                "KEYCHAIN_LOCKED", "The keychain could not be read; it is probably locked.",
                "Unlock the login keychain (open Keychain Access, or log in again) and retry.")
        }
        if let change = try await FreeIdentityGuard.settleInFlight(
            ledgerStore: services.ledgerStore, current: identities, now: now)
        {
            return fail(
                "FREE_CERT_CHANGED",
                "The free team's signing identities changed during an earlier run that did not finish (\(change.addedFp8.count) added, \(change.removedFp8.count) removed). Nothing was signed.",
                "Auto-refresh is suspended. The owner checks Xcode > Settings > Accounts > Manage Certificates and the lab (something created or revoked a free certificate). Run provision by hand once satisfied.",
                [
                    "identityChanged": true, "suspended": true,
                    "addedFp8": .array(change.addedFp8.map { .string($0) }),
                    "removedFp8": .array(change.removedFp8.map { .string($0) }),
                ])
        }
        // Only now, with the marker settled: a stale folder from a killed run, safe to remove under the lock.
        SignCommand.sweepStaleScratch(in: services.home.tmp)
        guard let pinnedFp8 = try config.freeTeamCertFp8() else {
            return fail(
                "FREE_IDENTITY_NOT_PINNED", "No free-team identity is pinned yet, so there is nothing to sign with.",
                "The owner runs `sideload provision --app \(app.rawValue) --device \(alias) --yes` first; its first success pins the identity.")
        }
        let identity: FreeIdentity
        switch CertCheck.pinnedFree(identities, fp8: pinnedFp8, now: now) {
        case .found(let found): identity = found
        case .notFound:
            return fail(
                "FREE_IDENTITY_MISSING",
                "The pinned free-team identity (\(pinnedFp8)) is not in the keychain, or is expired or untrusted.",
                "Check Xcode > Settings > Accounts > Manage Certificates and the login keychain (owner action). sideload never creates a certificate.",
                ["pinnedFp8": .string(pinnedFp8)])
        case .ambiguous:
            return fail(
                "FREE_IDENTITY_AMBIGUOUS", "More than one valid free-team identity has the pinned fingerprint prefix.",
                "The owner removes the duplicate in Keychain Access; sideload does not delete keychain items.",
                ["pinnedFp8": .string(pinnedFp8)])
        }
        guard let pinned = CertReference(identity.sha1) else {
            return fail(
                "FREE_IDENTITY_MISSING", "The pinned free-team identity has no usable fingerprint.",
                "Check the login keychain (owner action).")
        }

        // 2. The IPA: the newest approved manifest entry, still intact.
        let manifestStore = ManifestStore(paths: services.home)
        let manifest = try manifestStore.load()
        let entries = manifest.entries.filter { $0.app == app.rawValue }
        guard let entry = entries.filter({ $0.approved && (version == nil || $0.version == version) }).max(by: ManifestEntry.older) else {
            if let version {
                return fail(
                    "NOT_APPROVED", "Version \(printableCut(version)) of \(app.rawValue) is not fetched and approved, so it is not signed.",
                    "Fetch it and the owner approves it with --approve --version <v>.")
            }
            return fail(
                "NOT_APPROVED",
                entries.isEmpty
                    ? "No version of \(app.rawValue) has been fetched, so there is nothing approved to sign."
                    : "No fetched version of \(app.rawValue) is approved.",
                entries.isEmpty
                    ? "Run `sideload fetch --app \(app.rawValue)`, review it, and the owner approves it with --approve --version <v>."
                    : "Review `sideload fetch --app \(app.rawValue)`, then the owner runs: sideload fetch --app \(app.rawValue) --approve --version <v>.")
        }
        var warnings: [JSONValue] = []
        if version == nil, entries.contains(where: { !$0.approved && $0.fetchedAt > entry.fetchedAt }) {
            warnings.append(
                CanaryCommand.warning(
                    "NEWER_VERSION_NOT_APPROVED",
                    "A newer fetched version of \(app.rawValue) is not approved; the newest approved version is signed.",
                    "The owner reviews and approves the newer version to sign it."))
        }
        // Never a block: `install` goes over a newer app and keeps its data, and iOS decides whether it takes the older build.
        if let installed = (try? services.ledgerStore.load())?.installs.first(where: { $0.id == key })?.version,
            VersionOrder.compare(installed: installed, upstream: entry.version) == .older
        {
            warnings.append(
                CanaryCommand.warning(
                    "OLDER_THAN_INSTALLED",
                    "Signing \(printableCut(entry.version)), older than the installed \(printableCut(installed)); `install` goes over it and keeps the app's data. iOS may refuse an older build, which leaves the installed app as it is.",
                    "Renew or update to return to the installed or newest version."))
        }
        let ipaPath = try manifestStore.path(of: entry)
        if entry.prunedAt != nil {
            return fail(
                "IPA_PRUNED", "The fetched file for \(entry.app) \(printableCut(entry.version)) was deleted by `sideload clean`.",
                "Run `sideload fetch --app \(entry.app)` to download it again; the same file keeps its approval.")
        }
        guard let stored = try FileDigest.sha256(path: ipaPath) else {
            return fail(
                "IPA_MISSING", "The fetched file for \(entry.app) \(printableCut(entry.version)) is gone.",
                "Remove its manifest entry and run `sideload fetch --app \(entry.app)` again.")
        }
        guard stored.hex == entry.sha256 else { return digestMismatch(expected: entry.sha256, actual: stored.hex) }

        // 3. The device's OS against the app's minimum, before any extraction.
        let deviceOS: DeviceOS
        switch try await readDeviceOS() {
        case .stop(let envelope): return envelope
        case .value(let value): deviceOS = value
        }
        let have = deviceOS.version
        // The stricter of what the source declares (Stremio's index) and what the binary says.
        if let need = OSVersion.strictest([entry.minOS, entry.inspectMinOS]), let stop = osTooOld(have: have, need: need) { return stop }

        // 4. The stored free profile for this device and app, re-read and re-verified.
        let ledger = try services.ledgerStore.load()
        let loaded: LoadedProfile
        switch try await loadProfile(ledger: ledger, identity: identity) {
        case .stop(let envelope): return envelope
        case .value(let value): loaded = value
        }
        let (profile, profileBytes, expires) = (loaded.profile, loaded.bytes, loaded.expires)
        let daysLeft = Int((expires.timeIntervalSince(now) / 86_400).rounded(.down))

        // 5. The work, in a registered 0700 scratch folder that is removed on every path.
        let scratch = try ScratchDirectory.create(under: services.home.tmp, registry: registry, prefix: "sign")
        let outcome: Result<Step<Worked>, any Error>
        do {
            outcome = .success(
                try await work(
                    scratch: scratch, entry: entry, ipaPath: ipaPath, identity: identity, pinned: pinned, profile: profile,
                    profileBytes: profileBytes, expires: expires, deviceOS: deviceOS))
        } catch {
            outcome = .failure(error)
        }
        let removed = scratch.remove()
        if !removed { log("sign: the scratch folder could not be removed") }
        let worked: Worked
        switch outcome {
        case .failure(let error): throw error
        case .success(.stop(let envelope)): return envelope
        case .success(.value(let value)): worked = value
        }
        warnings += worked.warnings
        if !removed {
            warnings.append(
                CanaryCommand.warning(
                    "SCRATCH_NOT_REMOVED", "The scratch folder under $SIDELOAD_HOME/tmp could not be removed.",
                    "Delete the sign-* folders in $SIDELOAD_HOME/tmp."))
        }

        var data: [String: JSONValue] = [
            "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId),
            "version": .string(entry.version), "build": entry.build.map(JSONValue.string) ?? .null,
            "profile": ["uuid": .string(profile.uuid), "daysLeft": .number(Double(daysLeft))],
            "stripped": .array(worked.stripped.map(\.json)),
            "droppedEntitlements": .array(worked.reduction.dropped.map { .string($0) }),
            "appGroups": [
                "declaredByApp": .array(worked.groups.declaredByApp.map { .string($0) }),
                "onlyInStrippedExtensions": .array(worked.groups.extensionsOnly.map { .string($0) }),
            ],
            "deviceOS": [
                "version": .string(have), "minimum": worked.minimumOS.map(JSONValue.string) ?? .null,
                "source": .string(deviceOS.source),
            ],
            "warnings": .array(warnings), "signed": .string(worked.relativePath),
            "sha256Prefix": .string(String(entry.sha256.prefix(8))),
        ]
        data["pinnedFp8"] = .string(identity.fp8)
        return .result(SignCommand.command, data)
    }

    private func digestMismatch(expected: String, actual: String) -> Envelope {
        fail(
            "DIGEST_MISMATCH", "The fetched file no longer matches the manifest's SHA-256. Nothing was signed.",
            "Remove the file and its manifest entry, then fetch and approve it again.",
            ["expected": .string(expected), "actual": .string(actual)])
    }

    // MARK: device OS

    private struct DeviceOS {
        var version: String
        /// Where the version came from, said in the output.
        var source: String
    }

    /// The device's OS from `devicectl list devices` (the saved config does not record it). No version means
    /// `DEVICE_OS_UNKNOWN`: the minimum cannot be checked, so nothing is signed.
    private func readDeviceOS() async throws -> Step<DeviceOS> {
        let source = "devicectl list devices"
        log("sign: reading the device's OS")
        let listed = try await services.deviceCtl.listDevices()
        guard let saved = config.devices[alias],
            let version = DeviceList.findSaved(listed ?? [], matching: saved)?.osVersion
        else {
            return .stop(
                fail(
                    "DEVICE_OS_UNKNOWN",
                    "The device's OS version could not be read from devicectl, so the app's minimum OS cannot be checked.",
                    "Connect and unlock the device (paired, Developer Mode on) and retry. Nothing was signed."))
        }
        return .value(DeviceOS(version: version, source: source))
    }

    private func osTooOld(have: String, need: String) -> Envelope? {
        switch OSVersion.isAtLeast(have, need) {
        case true?: return nil
        case false?:
            return fail(
                "DEVICE_OS_TOO_OLD", "\(app.rawValue) needs OS \(need) or newer; the device runs \(have). Nothing was signed.",
                "Update the device, or fetch and approve an older version of the app.",
                ["deviceOS": .string(have), "minimumOS": .string(need), "deviceOSSource": .string("devicectl list devices")])
        case nil:
            return fail(
                "DEVICE_OS_UNKNOWN", "The device's OS or the app's minimum OS is not a version number, so they cannot be compared.",
                "Run `sideload inspect` on the IPA and `sideload device list`; nothing was signed.")
        }
    }

    // MARK: profile

    private struct LoadedProfile {
        var profile: ProvisioningProfile
        var bytes: Data
        var expires: Date
    }

    private func profileStop(_ code: String, _ message: String, _ fix: String, check: String? = nil) -> Step<LoadedProfile> {
        .stop(fail(code, message, fix, check.map { ["check": .string($0)] } ?? [:]))
    }

    /// The profile `provision` stored for this device and app: its ledger record, the file under `profiles/free/`
    /// (read once, without following a link), decoded from those bytes, and the same checks `provision` makes.
    private func loadProfile(ledger: Ledger, identity: FreeIdentity) async throws -> Step<LoadedProfile> {
        let provisionFix = "The owner runs `sideload provision --app \(app.rawValue) --device \(alias) --yes` to get a fresh profile."
        guard let record = ledger.freeProfiles.first(where: { $0.id == key }) else {
            return profileStop(
                "PROFILE_MISSING", "No free-team profile is recorded for \(app.rawValue) on this device.", provisionFix)
        }
        // The record is trusted only as far as it names the one file `provision` would have written.
        let expectedFile = "profiles/free/\(app.rawValue)/\(alias)/\(record.profileUuid).mobileprovision"
        guard UUID(uuidString: record.profileUuid) != nil, record.file == expectedFile else {
            return profileStop(
                "PROFILE_INVALID", "The ledger's record of the stored profile is not the file provision writes.",
                provisionFix, check: "ledger-record")
        }
        let path = services.home.home + "/" + record.file
        var st = stat()
        if lstat(path, &st) != 0, errno == ENOENT {
            return profileStop("PROFILE_MISSING", "The stored profile file is gone.", provisionFix)
        }
        guard let candidate = ProfileCacheRenewal.readCandidate(path) else {
            return profileStop(
                "PROFILE_INVALID",
                "The stored profile is not a regular file of a sane size (a symlink, a special file, over 1 MiB or unreadable).",
                provisionFix, check: "stored-file")
        }
        let decoded = await services.runner.run(
            CommandSpec(
                executable: "/usr/bin/security", args: ["cms", "-D"], timeout: SignCommand.toolTimeout,
                stdin: candidate.bytes))
        guard decoded.code == 0, let profile = ProvisioningProfile.parse(decoded.stdout) else {
            return profileStop(
                "PROFILE_INVALID", "The stored profile could not be decoded.", provisionFix, check: "decode")
        }
        guard profile.uuid.caseInsensitiveCompare(record.profileUuid) == .orderedSame else {
            return profileStop(
                "PROFILE_INVALID", "The stored profile is not the one the ledger records.", provisionFix, check: "uuid")
        }
        if let problem = ProvisionCommand.verify(
            profile, bundleId: bundleId, platform: app.profilePlatform, udid: udid, certificate: identity.sha1, now: now)
        {
            if problem.check == "expiry", let expires = profile.expires, expires <= now {
                return profileStop(
                    "PROFILE_EXPIRED", "The stored free profile has expired. Nothing was signed.", provisionFix,
                    check: "expiry")
            }
            return profileStop("PROFILE_INVALID", problem.message, provisionFix, check: problem.check)
        }
        guard let expires = profile.expires else {
            return profileStop("PROFILE_INVALID", "The stored profile has no expiry date.", provisionFix, check: "expiry")
        }
        return .value(LoadedProfile(profile: profile, bytes: candidate.bytes, expires: expires))
    }

    // MARK: the work

    private struct Worked {
        var stripped: [StrippedBundle] = []
        var reduction = EntitlementReduction(
            applicationIdentifier: "", teamIdentifier: "", getTaskAllow: true, keychainGroup: nil, dropped: [], appGroups: [])
        var groups: (declaredByApp: [String], extensionsOnly: [String]) = ([], [])
        var warnings: [JSONValue] = []
        var relativePath = ""
        /// The minimum OS the check used (the strictest known).
        var minimumOS: String?
    }

    private func cancelled() -> SideloadError {
        SideloadError("CANCELLED", "sign was interrupted.", fix: "Re-run the command.")
    }

    private func work(
        scratch: ScratchDirectory, entry: ManifestEntry, ipaPath: String, identity: FreeIdentity, pinned: CertReference,
        profile: ProvisioningProfile, profileBytes: Data, expires: Date, deviceOS: DeviceOS
    ) async throws -> Step<Worked> {
        var worked = Worked()
        let limits = InspectLimits()

        log("sign: unpacking")
        let inspector = IPAInspector(
            runner: services.runner, tmp: services.home.tmp, registry: registry, limits: limits, log: services.log)
        let unpacked = try await inspector.inspect(path: ipaPath, keeping: scratch)
        guard unpacked.sha256 == entry.sha256 else {
            return .stop(digestMismatch(expected: entry.sha256, actual: unpacked.sha256))
        }
        let appDir = unpacked.appDir
        let report = unpacked.report
        let appInfo = Self.fields(report["app"])
        worked.warnings += Self.list(report["warnings"])

        if case .string(let platform)? = appInfo["platform"], platform != app.devicePlatform {
            return .stop(
                fail(
                    "PLATFORM_MISMATCH", "The fetched IPA is built for \(platform), but \(app.rawValue) is signed for \(app.devicePlatform).",
                    "Do not use this IPA; fetch the right app."))
        }
        // The binary's own minimum (the manifest's inspect value, else the one just read) and the declared one: the
        // stricter counts, and with neither the minimum is unknown, which fails closed.
        var inspected: String?
        if case .string(let own)? = appInfo["minOS"] { inspected = own }
        guard let need = OSVersion.strictest([entry.minOS, entry.inspectMinOS ?? inspected]) else {
            return .stop(
                fail(
                    "MIN_OS_UNKNOWN", "Neither the manifest nor the IPA says which OS the app needs, so the device's OS cannot be checked. Nothing was signed.",
                    "Run `sideload inspect` on the IPA; do not sign an app whose minimum OS is unknown."))
        }
        worked.minimumOS = need
        if let stop = osTooOld(have: deviceOS.version, need: need) { return .stop(stop) }
        let appName = (appDir as NSString).lastPathComponent
        guard IPAInspector.isPlainName(appName), !appName.hasPrefix("."), appName.hasSuffix(".app") else {
            throw SideloadError("IPA_UNSAFE_TREE", "The app folder's name is not a plain name.", fix: "Do not use this IPA.")
        }
        if registry.isClosed { throw cancelled() }

        // Strip, then prove nothing is left.
        log("sign: removing extensions")
        let outcome = try await ExtensionStripper(runner: services.runner, limits: limits).strip(app: appDir)
        worked.stripped = outcome.stripped
        worked.warnings += outcome.warnings
        let remaining = ExtensionStripper.remaining(in: appDir, limits: limits)
        guard remaining.isEmpty else {
            return .stop(
                fail(
                    "EXTENSION_REMAINS", "An app extension or watch app is still in the bundle after stripping. Nothing was signed.",
                    "Do not use this IPA; run `sideload inspect` on it.",
                    ["remaining": .array(remaining.prefix(20).map { .string(BinaryTools.cut($0)) })]))
        }

        // Bundle ID, signature folder, profile, entitlements.
        guard let applicationIdentifier = profile.applicationIdentifier else {
            throw SideloadError("PROFILE_INVALID", "The stored profile has no application-identifier.", fix: "Run provision again.")
        }
        try BundleRewriter.setBundleIdentifier(infoPlist: appDir + "/Info.plist", to: bundleId)
        try BundleRewriter.installProfile(profileBytes, into: appDir)
        let reduction = EntitlementReducer.reduce(
            original: appInfo["entitlements"], applicationIdentifier: applicationIdentifier, team: Team.free,
            getTaskAllow: profile.getTaskAllow == true)
        worked.reduction = reduction
        worked.groups = EntitlementReducer.groupSplit(app: reduction.appGroups, stripped: outcome.stripped)
        for group in worked.groups.declaredByApp {
            worked.warnings.append(
                CanaryCommand.warning(
                    "APP_GROUP_DROPPED",
                    "The app declares the app group \(BinaryTools.cut(group)); a free profile cannot grant it, so it is dropped and settings shared through it may not carry over.",
                    "Accepted by the owner: not a stop. Check the app's settings after the first run."))
        }
        let entitlementsFile = scratch.path + "/entitlements.plist"
        try AtomicFile.write(try reduction.plistData(), to: entitlementsFile, mode: 0o600)
        if registry.isClosed { throw cancelled() }

        // Sign with the pinned identity's SHA-1, then verify.
        log("sign: signing")
        try await BundleSigner(runner: services.runner, identity: identity.sha1).sign(app: appDir, entitlements: entitlementsFile)
        if registry.isClosed { throw cancelled() }

        // Nothing is placed unless the free guard passes on exactly this bundle.
        log("sign: checking the result")
        let verdict = await Guard.run(
            context: .free(
                FreeSigning(
                    bundleId: bundleId, bundleIdPrefix: prefix, pinnedCertificate: pinned, now: now,
                    scratchRoot: services.home.tmp)),
            runner: services.runner, app: appDir, udid: udid)
        guard verdict.passed else {
            return .stop(
                fail(
                    verdict.code ?? "GUARD_FAILED", verdict.reason ?? "The signed app failed the free-team guard.",
                    "Nothing was kept. Check the profile and the pinned identity; run provision again if the profile is the problem."))
        }
        if registry.isClosed { throw cancelled() }

        // Move it into place atomically, then record it.
        let directory = "\(services.home.signedBuilds)/\(app.rawValue)/\(alias)"
        try makeDirectories(directory, mode: 0o700)
        var path = services.home.builds
        for part in ["signed", app.rawValue, alias] {
            path += "/" + part
            if chmod(path, 0o700) != 0 { throw ioError("chmod") }
        }
        let destination = directory + "/" + appName
        let swapped = try SignCommand.place(appDir, at: destination)
        worked.relativePath = "builds/signed/\(app.rawValue)/\(alias)/\(appName)"

        let signed = LedgerFreeSigned(
            id: key, device: alias, app: app.rawValue, bundleId: bundleId, version: entry.version,
            sha256Prefix: String(entry.sha256.prefix(8)), profileUuid: profile.uuid,
            profileExpires: Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down)), certFp8: identity.fp8,
            signedAt: now, path: worked.relativePath,
            strippedExtensions: outcome.stripped.map { LedgerStrippedExtension(path: $0.path, bundleId: $0.bundleId) },
            droppedEntitlements: reduction.dropped)
        let id = key
        do {
            try hooks.beforeLedgerWrite()
            try await services.ledgerStore.update { ledger in
                ledger.freeSigned.removeAll { $0.id == id }
                ledger.freeSigned.append(signed)
                ledger.freeSigned.sort { $0.id < $1.id }
            }
        } catch {
            // Disk and ledger must agree: put the previous state back (the new app, or the old one swapped out, is
            // in the scratch folder afterwards and goes with it).
            let code = (error as? SideloadError)?.code ?? "LEDGER_WRITE_FAILED"
            let restored = hooks.restore?(swapped, appDir, destination) ?? SignCommand.restore(swapped: swapped, scratchApp: appDir, destination: destination)
            if restored {
                return .stop(
                    fail(
                        code, "The ledger could not be written, so the signed app was not kept; the previous state is back.",
                        "Check the permissions and free space of $SIDELOAD_HOME, then run `sideload sign` again.",
                        ["placed": false]))
            }
            return .stop(
                fail(
                    code, "The ledger could not be written and the signed app could not be taken back out of place.",
                    "The signed app is in place but not recorded. Check the permissions and free space of $SIDELOAD_HOME, then run `sideload sign` again to record it.",
                    ["placed": true, "recorded": false, "signedPath": .string(worked.relativePath)]))
        }
        return .value(worked)
    }

    private static func fields(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = value { return o }
        return [:]
    }

    private static func list(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let a)? = value { return a }
        return []
    }
}
