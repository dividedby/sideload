import Darwin
import Foundation

public struct ProvisionOptions: Sendable, Equatable {
    public var app: String?
    public var device: String?
    /// Lets Xcode register the device on the free team (`-allowProvisioningDeviceRegistration`). Owner-only.
    public var registerDevice: Bool
    /// Moves sideload's own cached profile aside first so Xcode makes a fresh one (spike S3). Owner-only.
    public var renew: Bool
    /// Owner confirmation; agents must not pass it.
    public var yes: Bool
    /// `--renew-ack`: the owner has looked at the cached profiles an earlier `--renew` run left in `tmp/` and clears
    /// the ledger's record of them (the files are never touched). Stands alone; needs `--yes`.
    public var renewAck: Bool

    public init(
        app: String? = nil, device: String? = nil, registerDevice: Bool = false, renew: Bool = false, yes: Bool = false,
        renewAck: Bool = false
    ) {
        self.renewAck = renewAck
        self.app = app
        self.device = device
        self.registerDevice = registerDevice
        self.renew = renew
        self.yes = yes
    }
}

/// The apps `provision` can get a free-team profile for, and the platform each runs on. The bundle ID is
/// `<bundleIdPrefix>.free.<suffix>`; both Stremio apps share one App ID with two platform profiles (spike S7).
enum ProvisionApp: String, CaseIterable {
    case stremioIOS = "stremio-ios"
    case stremioTVOS = "stremio-tvos"
    case apollo
    /// A tiny app with no IPA: the Xcode-signed profile carrier itself. `provision` stages it as the `freeSigned`
    /// build, so `install` and `slot` can be exercised without a fetched IPA. Uses one App ID and one managed slot.
    case filler

    var suffix: String {
        switch self {
        case .apollo: "apollo"
        case .filler: "filler"
        case .stremioIOS, .stremioTVOS: "stremio"
        }
    }

    /// `<prefix>.free.<suffix>`, the bundle ID this app has on the free team; nil when the prefix is missing or invalid.
    func freeBundleId(prefix: String?) -> String? {
        guard let prefix, CanaryCommand.isValidPrefix(prefix) else { return nil }
        return prefix + ".free." + suffix
    }

    /// Signed by `provision` (Xcode signs the carrier), never by `sign`.
    var signedByProvision: Bool { self == .filler }

    /// The saved device's `platform` this app needs.
    var devicePlatform: String { self == .stremioTVOS ? "tvos" : "ios" }

    /// `Platform` as a provisioning profile spells it.
    var profilePlatform: String { Self.osName(devicePlatform: devicePlatform) }

    /// The OS as people and profiles spell it, from a saved device's `platform`.
    static func osName(devicePlatform: String?) -> String { devicePlatform == "tvos" ? "tvOS" : "iOS" }

    /// The SDK folder name under `Build/Products/Debug-<sdk>`.
    var sdk: String { self == .stremioTVOS ? "appletvos" : "iphoneos" }

    static var names: [String] { allCases.map(\.rawValue) }

    /// The apps `sign` handles (not the ones `provision` signs itself).
    static var signedBySign: [ProvisionApp] { allCases.filter { !$0.signedByProvision } }

    /// The one place that says how the owner gets a fresh signed build of this app: `provision` alone for an app that
    /// `provision` signs (the filler; `sign` refuses it), else `provision` then `sign`. `appName` is a ledger string and may
    /// not be a known app, which gets the general wording.
    static func resignSteps(app appName: String, device alias: String) -> String {
        guard let app = ProvisionApp(rawValue: appName) else {
            return "`sideload provision` and then `sideload sign` for \(printableCut(appName))"
        }
        return app.resignSteps(device: alias)
    }

    func resignSteps(device alias: String) -> String {
        let provision = "`sideload provision --app \(rawValue) --device \(alias) --yes`"
        return signedByProvision ? provision : provision + ", then " + signStep(device: alias)
    }

    /// What to run when only the signed build is missing: `sign` for most apps, `provision` for one it signs itself.
    func signStep(device alias: String) -> String {
        signedByProvision
            ? "`sideload provision --app \(rawValue) --device \(alias) --yes`"
            : "`sideload sign --app \(rawValue) --device \(alias) --yes`"
    }
}

/// `provision --app <a> --device <d>`: gets a free-team 7-day development profile for one app on one saved device
/// through Xcode, using the generated profile carrier (design section 18). It builds the carrier with
/// `xcodebuild -allowProvisioningUpdates` for the free team, so Xcode creates the App ID and the profile; sideload
/// then checks the profile Xcode embedded, stores a copy and records it. Owner-run: `--yes` is required.
///
/// Free-team narrow use: only `<prefix>.free.*`; the free team's identity set is snapshotted before and after
/// and any change is `FREE_CERT_CHANGED` (a hard stop that suspends auto-refresh); sideload never creates,
/// revokes or exports a certificate. Holds `.op.lock`.
public enum ProvisionCommand {
    static let command = "provision"
    static let buildTimeout = Duration.seconds(10 * 60)
    static let buildOutputCap = 128 * 1024 * 1024
    static let toolTimeout = Duration.seconds(30)
    /// A fresh profile lives 7 days; one that claims much more is not a free-team development profile.
    static let maxProfileLife: TimeInterval = 8 * 86_400
    /// A refresh must move the expiry by more than this, else Xcode reused its cached profile (spike S3).
    static let renewalMargin: TimeInterval = 24 * 3600

    public static func run(_ services: Services, _ options: ProvisionOptions) async -> Envelope {
        await run(services, options, hooks: ProvisionHooks())
    }

    static func run(_ services: Services, _ options: ProvisionOptions, hooks: ProvisionHooks) async -> Envelope {
        // Read once, first, without the lock: whatever happens next, the envelope says what an earlier --renew run
        // left in tmp/. An unreadable record is said too, never silently dropped.
        let record = RenewRecord.read(services)
        // A signal from here on, with or without --renew, carries them too.
        registerInterruptReport(services, record: record)
        let envelope: Envelope
        do {
            envelope = try await execute(services, options, hooks: hooks, record: record)
        } catch {
            envelope = .from(error, command: command)
        }
        // A successful --renew-ack lists what it cleared itself.
        return record.merged(into: envelope, listed: options.renewAck && envelope.ok)
    }

    /// Tells the signal handler to put the renew record in its `INTERRUPTED` object. `--renew` replaces this report
    /// with one that adds the renewal's outcome. Nothing is registered when there is nothing to say.
    public static func registerInterruptReport(_ services: Services, record: RenewRecord) {
        let report = record.json
        guard !report.isEmpty else { return }
        services.interruptReport.set { report }
    }

    /// The ledger's `freeRenewMoves` as `provision` found them at the start: read-only, no lock.
    public struct RenewRecord: Sendable {
        let home: Paths
        var moves: [LedgerFreeRenewMove] = []
        var unreadable = false

        /// `cachedProfilesFromEarlierRun` (when there are entries) and `renewRecordUnreadable` (when the ledger could
        /// not be read); empty when there is nothing to report.
        public var json: [String: JSONValue] {
            var data: [String: JSONValue] = [:]
            if !moves.isEmpty { data["cachedProfilesFromEarlierRun"] = ProvisionCommand.earlierRunJSON(moves, home: home) }
            if unreadable { data["renewRecordUnreadable"] = true }
            return data
        }

        public static func read(_ services: Services) -> RenewRecord {
            do {
                return RenewRecord(home: services.home, moves: try services.ledgerStore.load().freeRenewMoves)
            } catch {
                return RenewRecord(home: services.home, unreadable: true)
            }
        }

        /// Adds `json` to the envelope's data; an envelope with nothing to add is returned as it is. Idempotent.
        public func merged(into envelope: Envelope, listed: Bool = false) -> Envelope {
            let extra = json
            guard !listed, !extra.isEmpty else { return envelope }
            var data = envelope.data
            data.merge(extra) { _, new in new }
            return Envelope(ok: envelope.ok, command: envelope.command, data: data, errors: envelope.errors)
        }
    }

    /// The profile checks, in order. Nil means all of them hold. The message names the check, never profile content.
    static func verify(
        _ profile: ProvisioningProfile, bundleId: String, platform: String, udid: String, certificate: String, now: Date
    ) -> (check: String, message: String)? {
        if profile.team != Team.free { return ("team", "The profile does not belong to the free team.") }
        if profile.applicationIdentifier != Team.free + "." + bundleId {
            return ("application-identifier", "The profile's application-identifier is not the free team and this bundle ID.")
        }
        if !profile.platforms.contains(platform) { return ("platform", "The profile's platform does not match the device.") }
        if profile.getTaskAllow != true { return ("get-task-allow", "The profile does not set get-task-allow to true.") }
        if !profile.includes(device: udid) { return ("device", "The device is not in the profile's ProvisionedDevices.") }
        if !profile.contains(certificate: certificate) {
            return ("certificate", "The pinned free certificate is not in the profile's DeveloperCertificates.")
        }
        guard let expires = profile.expires, expires > now, expires <= now.addingTimeInterval(maxProfileLife)
        else { return ("expiry", "The profile's expiry is missing, past, or more than 8 days away.") }
        return nil
    }

    /// `provision --renew-ack --yes`: forgets the ledger's record of cached profiles an earlier run left in `tmp/`.
    /// It reads and clears the record only; no file is touched.
    private static func acknowledgeRenewMoves(_ services: Services, _ options: ProvisionOptions) async throws -> Envelope {
        guard options.app == nil, options.device == nil, !options.renew, !options.registerDevice else {
            return .fail(
                command, code: "USAGE", message: "--renew-ack stands alone.",
                fix: "sideload provision --renew-ack --yes")
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message: "--renew-ack forgets the record of cached profiles an earlier --renew run moved into tmp/. No file is touched.",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.")
        }
        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        let cleared = try await services.ledgerStore.update { ledger -> [LedgerFreeRenewMove] in
            defer { ledger.freeRenewMoves = [] }
            return ledger.freeRenewMoves
        }
        return .result(
            command,
            [
                "renewMovesAcknowledged": .number(Double(cleared.count)),
                "cachedProfilesFromEarlierRun": earlierRunJSON(cleared, home: services.home),
            ])
    }

    /// The ledger's leftover renew moves for an envelope: names relative to `$SIDELOAD_HOME`, never a path.
    /// `inTmp` says whether the file is in `tmp/` now (an `intent` entry may mean it never left Xcode's folder).
    static func earlierRunJSON(_ moves: [LedgerFreeRenewMove], home: Paths) -> JSONValue {
        .array(
            moves.map { move in
                var st = stat()
                let inTmp = move.to.hasPrefix("tmp/") && !move.to.contains("..") && lstat(home.home + "/" + move.to, &st) == 0
                var entry: [String: JSONValue] = [
                    "from": .string(move.from), "to": .string(move.to),
                    "at": .string(ProgressLog.isoTimestamp(move.at)), "state": .string(move.state.rawValue),
                    "inTmp": .bool(inTmp),
                ]
                if let folder = move.folder { entry["folder"] = .string(folder) }
                return .object(entry)
            })
    }

    private static func execute(
        _ services: Services, _ options: ProvisionOptions, hooks: ProvisionHooks, record: RenewRecord
    ) async throws -> Envelope {
        if options.renewAck { return try await acknowledgeRenewMoves(services, options) }
        guard let appName = options.app, !appName.isEmpty, let alias = options.device, !alias.isEmpty else {
            return .fail(
                command, code: "USAGE", message: "provision needs --app and --device <alias>.",
                fix: "sideload provision --app <\(ProvisionApp.names.joined(separator: "|"))> --device iphone --yes")
        }
        guard let app = ProvisionApp(rawValue: appName) else {
            return .fail(
                command, code: "USAGE", message: "Unknown app \"\(printableCut(appName))\".",
                fix: "Use one of: \(ProvisionApp.names.joined(separator: ", ")).")
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
                    "provision has portal side effects: Xcode creates the App ID \(bundleId) on the free team (if it has none) and a 7-day development profile"
                    + (options.registerDevice ? ", and registers this device on the free team" : "")
                    + (options.renew ? ", after sideload moves its own cached profile for this app aside" : "") + ".",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: ["bundleId": .string(bundleId), "device": .string(alias)])
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        var run = ProvisionRun(
            services: services, options: options, config: config, app: app, alias: alias, device: device,
            udid: udid, bundleId: bundleId, hooks: hooks, record: record)
        return await run.execute()
    }
}

/// The writes and other steps of a run that can fail after something irreversible happened, named so a test can make
/// each one throw (`ProvisionHooks.checkpoint`). The matrix covers every case.
enum ProvisionCheckpoint: String, CaseIterable, Sendable {
    /// The in-flight marker and App ID epoch write, right before `xcodebuild`.
    case markerWrite
    /// The ledger write after the build: the suspension (identity changed) or the marker clear (unchanged).
    case afterBuildWrite
    /// Pinning `freeTeam.certFp8`.
    case pinWrite
    /// Copying the profile under `profiles/free/`.
    case storeProfile
    /// The final ledger write that records the profile.
    case finalLedgerWrite
}

/// Test seams. The defaults do nothing, so production behaviour is the same with and without them.
struct ProvisionHooks: Sendable {
    var checkpoint: @Sendable (ProvisionCheckpoint) throws -> Void = { _ in }
    /// The renewal's syscalls, to fail any of them.
    var renewFS = RenewFS.live
    /// The renewal's running outcome, to seal it as a signal would.
    var renewProgress = RenewProgress()
    /// Wraps the renewal's ledger journal, to play a crash.
    var renewJournal: @Sendable (RenewJournal) -> RenewJournal = { $0 }
}

/// One `provision` run: the state shared by its steps.
private struct ProvisionRun {
    let services: Services
    let options: ProvisionOptions
    let config: Config
    let app: ProvisionApp
    let alias: String
    let device: ResolvedDevice
    let udid: String
    let bundleId: String
    let now: Date
    let hooks: ProvisionHooks
    /// The renew record read at the start; a signal's report keeps carrying it.
    let record: ProvisionCommand.RenewRecord

    /// Subject names the log tail must not show (the identities' common names, from the keychain read).
    var identityNames: [String] = []
    /// What `--renew` did, once it started (nil: it has not, so no envelope carries its keys). `execute()` merges
    /// one rendering of it into the single envelope this run returns, whatever path got there.
    var renew: ProfileCacheRenewal.Outcome?

    init(
        services: Services, options: ProvisionOptions, config: Config, app: ProvisionApp, alias: String,
        device: ResolvedDevice, udid: String, bundleId: String, hooks: ProvisionHooks, record: ProvisionCommand.RenewRecord
    ) {
        self.record = record
        self.hooks = hooks
        self.services = services
        self.options = options
        self.config = config
        self.app = app
        self.alias = alias
        self.device = device
        self.udid = udid
        self.bundleId = bundleId
        // Whole seconds, so what is recorded survives the ledger's ISO 8601 round trip unchanged.
        now = Date(timeIntervalSince1970: services.clock.now().timeIntervalSince1970.rounded(.down))
    }

    private func log(_ message: String) { services.log(message) }

    private func fail(
        _ code: String, _ message: String, _ fix: String, _ extra: [String: JSONValue] = [:]
    ) -> Envelope {
        var data: [String: JSONValue] = [
            "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId),
        ]
        data.merge(extra) { _, new in new }
        return .fail(ProvisionCommand.command, code: code, message: message, fix: fix, data: data)
    }

    private func iso(_ date: Date) -> JSONValue { .string(ProgressLog.isoTimestamp(date)) }

    /// app, device and bundleId: what every envelope of a renewing run carries, even a thrown error's.
    private var context: [String: JSONValue] {
        ["app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId)]
    }

    /// The single exit: it never throws. Without `--renew` the envelope is exactly what `steps()` produced. Once
    /// the renewal started, one rendering of its outcome (the five `Outcome.keys`) is merged into whatever envelope
    /// comes out, a thrown error's included, so no step can leave the owner without knowing what was moved. (The
    /// cached profiles an earlier run left in `tmp/` are added around this, for every envelope, in `ProvisionCommand.run`.)
    mutating func execute() async -> Envelope {
        let raw: Envelope
        do {
            raw = try await steps()
        } catch {
            raw = .from(error, command: ProvisionCommand.command)
        }
        guard let renew else { return raw }
        var data = context
        data.merge(raw.data) { _, new in new }
        data.merge(renew.json) { _, new in new }
        await recordStrays(renew)
        scheduleSettlement(renew)
        return Envelope(ok: raw.ok, command: raw.command, data: data, errors: raw.errors)
    }

    /// A stray stays recorded until the owner clears it; make sure it is marked so (best effort: the intent entry
    /// already says the file may be in `tmp/`).
    private func recordStrays(_ renew: ProfileCacheRenewal.Outcome) async {
        let stray = Set(renew.strayInTmp)
        guard !stray.isEmpty else { return }
        _ = try? await services.ledgerStore.update { ledger in
            for i in ledger.freeRenewMoves.indices where stray.contains(ledger.freeRenewMoves[i].to) {
                ledger.freeRenewMoves[i].state = .stray
            }
        }
    }

    /// The envelope reports this run's moves, but the ledger record of them goes only after that envelope was fully
    /// written to stdout (`Services.postEmit`, run by the CLI): exactly these files, under the ledger lock, and
    /// never a stray. A kill, a closed pipe or a failed write leaves the entries, and the next run reports them
    /// (a duplicate report is acceptable; an untracked file is not).
    private func scheduleSettlement(_ renew: ProfileCacheRenewal.Outcome) {
        let moved = Set(renew.movedTo)
        guard !moved.isEmpty else { return }
        let store = services.ledgerStore
        services.postEmit.add {
            _ = try? await store.update { ledger in
                ledger.freeRenewMoves.removeAll { moved.contains($0.to) && $0.state != .stray }
            }
        }
    }

    private mutating func steps() async throws -> Envelope {
        // 1. Preflight: keychain, pinned identity, App ID budget.
        log("provision: preflight")
        let identities: [KeychainCertificate]
        do {
            identities = try services.keychain.developmentIdentities()
        } catch {
            return fail(
                "KEYCHAIN_LOCKED", "The keychain could not be read; it is probably locked.",
                "Unlock the login keychain (open Keychain Access, or log in again) and retry.")
        }
        identityNames = identities.compactMap(\.commonName)
        // A marker left by a run that died during its build comes first: compare, record, clear.
        if let change = try await FreeIdentityGuard.settleInFlight(
            ledgerStore: services.ledgerStore, current: identities, now: now)
        {
            return identityStop(change, buildSucceeded: nil, interrupted: true)
        }
        let pinnedFp8 = try config.freeTeamCertFp8()
        let identity: FreeIdentity
        if let pinnedFp8 {
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
        } else {
            let candidates = CertCheck.freeIdentities(identities, now: now)
            switch candidates.count {
            case 0:
                return fail(
                    "FREE_IDENTITY_MISSING", "No valid free-team Apple Development identity is in the keychain.",
                    "Check Xcode > Settings > Accounts > Manage Certificates (owner action). sideload never creates a certificate.")
            case 1: identity = candidates[0]
            default:
                return fail(
                    "FREE_IDENTITY_AMBIGUOUS",
                    "There are \(candidates.count) valid free-team identities, so none can be pinned.",
                    "Leave exactly one valid free-team identity (owner action), or set `freeTeam.certFp8` in config.json to the one to use.",
                    ["candidateFp8": .array(candidates.map { .string($0.fp8) })])
            }
        }

        let ledger = try services.ledgerStore.load()
        let reserved = try config.freeTeamReservedAppIds()
        let budget = FreeAppIdBudget.evaluate(ledger.freeAppIds, bundleId: bundleId, reserved: reserved, now: now)
        guard budget.allowed else {
            return fail(
                "FREE_APP_ID_LIMIT",
                "A new App ID would exceed the free team's budget: \(budget.recent) in the last 7 days + \(reserved) reserved + 1 > \(FreeAppIdBudget.limit).",
                "Wait until an App ID is a week old, or the owner lowers `freeTeam.reservedAppIds`. Nothing was run.",
                [
                    "appIdsLast7Days": .number(Double(budget.recent)), "reservedAppIds": .number(Double(reserved)),
                    "appIdNew": true,
                ])
        }
        let previous = ledger.freeProfiles.first { $0.id == key }

        // 2. Identity snapshot before (from the same read).
        let before = FreeIdentitySnapshot(identities)

        // 3. The carrier project and a clean products folder.
        let project = try CarrierProject.write(to: services.home.carrierProject)
        // The derived data is ours; clearing the products means any profile found afterwards is from this build.
        guard ScratchDirectory.removeTree(services.home.carrierDerivedData + "/Build/Products") else {
            return fail(
                "DERIVED_DATA_NOT_CLEARED", "The previous carrier build products could not be removed.",
                "Delete $SIDELOAD_HOME/builds/carrier-dd by hand (it is only a build cache) and retry. Nothing was built.")
        }

        // 4. --renew: move sideload's own cached profile aside, then build. What it did is reported in every
        // envelope from here on.
        if options.renew {
            log("provision: moving this app's cached profile aside")
            // Registered first, so a signal from here on reports the (sealed) progress even though the build, not the
            // renewal, is what it interrupts.
            let progress = hooks.renewProgress, context = self.context
            let earlier = record.json
            services.interruptReport.set {
                earlier.merging(context) { _, new in new }.merging(progress.seal().json) { _, new in new }
            }
            let outcome = await ProfileCacheRenewal.moveOwnProfiles(
                in: services.xcodeProfileDirectories, bundleId: bundleId, platform: app.profilePlatform,
                to: services.home.tmp, runner: services.runner, now: now, progress: progress, fs: hooks.renewFS,
                journal: hooks.renewJournal(.ledger(services.ledgerStore)), beforeMove: { _ in }, afterCheck: { _ in })
            renew = outcome
            if let error = outcome.error { return .from(error, command: ProvisionCommand.command) }
        }

        // The crash-safe marker: written before Xcode can touch the free team's certificates, cleared only in the
        // ledger write that records the after-comparison. A signal or crash in between leaves it for the next run.
        // The App ID epoch goes in the same atomic write, so a build killed halfway still counts it (conservatively
        // high: xcodebuild may or may not have registered it). A failed write stops the run before the build.
        let marker = LedgerFreeInFlight(
            beforeFp8: FreeIdentityGuard.fp8s(identities), startedAt: now, app: app.rawValue, device: alias)
        let (epochBundleId, epochNow) = (bundleId, now)
        try hooks.checkpoint(.markerWrite)
        try await services.ledgerStore.update { ledger in
            ledger.freeProvisionInFlight = marker
            ledger.freeAppIds = FreeAppIdBudget.recording(ledger.freeAppIds, bundleId: epochBundleId, now: epochNow)
        }

        log("provision: building the carrier (up to 10 minutes)")
        let build = await services.runner.run(
            CommandSpec(
                executable: "xcodebuild", args: buildArguments(project: project),
                timeout: ProvisionCommand.buildTimeout, maxOutputBytes: ProvisionCommand.buildOutputCap))
        let failure = ProvisionClassifier.classify(
            .init(
                exitCode: build.code, stderr: build.stderr, stdout: build.stdout, timedOut: build.timedOut,
                overflow: build.overflow, spawnError: build.spawnError),
            registerDevice: options.registerDevice)

        // 4. Identity snapshot after: always, even when the build failed.
        var after: FreeIdentitySnapshot?
        var afterIdentities: [KeychainCertificate] = []
        if let read = try? services.keychain.developmentIdentities() {
            afterIdentities = read
            after = FreeIdentitySnapshot(read)
        }
        let diff = after.map { before.diff(to: $0) }
        let identityBroken = diff?.changed ?? true

        var suspensionRecorded = true
        let (now, compared) = (self.now, diff != nil)
        do {
            try hooks.checkpoint(.afterBuildWrite)
            try await services.ledgerStore.update { ledger in
                if identityBroken {
                    ledger.freeSuspended = LedgerFreeSuspension(
                        code: compared ? "FREE_CERT_CHANGED" : "IDENTITY_CHECK_FAILED", at: now,
                        addedFp8: diff?.addedFp8 ?? [], removedFp8: diff?.removedFp8 ?? [])
                }
                // The comparison ran and is recorded in this same write: the marker's job is done. If the keychain
                // could not be read the marker stays, and the next run compares.
                if compared { ledger.freeProvisionInFlight = nil }
            }
        } catch {
            if !identityBroken { throw error }
            suspensionRecorded = false
        }
        if identityBroken {
            return identityStop(
                diff.map { FreeIdentityGuard.Change(addedFp8: $0.addedFp8, removedFp8: $0.removedFp8) },
                buildSucceeded: failure == nil, suspensionRecorded: suspensionRecorded)
        }
        if let failure { return buildFailure(failure, build, budget) }

        // 5. The profile Xcode embedded.
        let derived = services.home.carrierDerivedData
        let built = "\(derived)/Build/Products/Debug-\(app.sdk)/\(CarrierProject.productName)"
        var st = stat()
        guard stat(built, &st) == 0 else {
            return fail(
                "BUILD_PRODUCT_MISSING", "The build succeeded but \(CarrierProject.productName) was not found.",
                "Retry; if it repeats, open the carrier project in Xcode once.")
        }
        let profilePath = built + "/embedded.mobileprovision"
        // Read once, without following a symlink: these exact bytes are decoded (on stdin) and, if they pass, stored.
        var embedded = stat()
        guard lstat(profilePath, &embedded) == 0 else {
            return invalidProfile("decode", "The embedded provisioning profile is missing or could not be decoded.")
        }
        guard let candidate = ProfileCacheRenewal.readCandidate(profilePath) else {
            return invalidProfile(
                "embedded-profile",
                "The embedded provisioning profile is not a regular file of a sane size (a symlink, a special file, over 1 MiB or unreadable).")
        }
        let profileBytes = candidate.bytes
        let decoded = await services.runner.run(
            CommandSpec(
                executable: "/usr/bin/security", args: ["cms", "-D"], timeout: ProvisionCommand.toolTimeout,
                stdin: profileBytes))
        guard decoded.code == 0, let profile = ProvisioningProfile.parse(decoded.stdout) else {
            return invalidProfile("decode", "The embedded provisioning profile is missing or could not be decoded.")
        }
        if let problem = ProvisionCommand.verify(
            profile, bundleId: bundleId, platform: app.profilePlatform, udid: udid, certificate: identity.sha1, now: now)
        {
            return invalidProfile(problem.check, problem.message)
        }
        guard let expires = profile.expires else { return invalidProfile("expiry", "The profile has no expiry date.") }

        // The first success with no pin pins the one valid free identity (re-read after the build).
        var pinnedNow = false
        if pinnedFp8 == nil {
            let valid = CertCheck.freeIdentities(afterIdentities, now: now)
            guard valid.count == 1, valid[0].sha1 == identity.sha1 else {
                return fail(
                    "FREE_IDENTITY_AMBIGUOUS", "There is not exactly one valid free-team identity to pin.",
                    "Leave exactly one valid free-team identity (owner action) and run provision again.")
            }
            pinnedNow = true
        }

        // 6. Renewal: a refresh must move the expiry on by more than a day.
        if let previous, expires <= previous.expires.addingTimeInterval(ProvisionCommand.renewalMargin) {
            return fail(
                "PROFILE_NOT_RENEWED",
                "Xcode reused its cached profile: the new expiry is not more than 24 hours past the previous one.",
                options.renew
                    ? "--renew was used and the expiry still did not move. Do not retry in a loop; report it (spike S3)."
                    : "Spike S3. The owner may re-run with --renew --yes, which moves sideload's own cached profile for this app aside so Xcode makes a fresh one.",
                [
                    "profile": profileJSON(profile, expires: expires),
                    "sameProfile": .bool(profile.uuid.caseInsensitiveCompare(previous.profileUuid) == .orderedSame),
                ])
        }

        // 6b. The filler is its own signed build: a copy of Xcode's signed carrier is checked by the free guard before
        // anything is pinned, stored or recorded. The scratch folder holds the copy, and the previous app after a swap.
        var scratch: ScratchDirectory?
        defer { scratch?.remove() }
        var filler: StagedFiller?
        if app.signedByProvision {
            switch try await prepareFiller(built: built, identity: identity, scratch: &scratch) {
            case .stop(let envelope): return envelope
            case .staged(let staged): filler = staged
            }
        }

        // 7. Pin, store, record.
        if pinnedNow {
            let fp8 = identity.fp8
            try hooks.checkpoint(.pinWrite)
            try await services.store.update { try $0.pinFreeTeamCert(fp8: fp8) }
            log("provision: pinned the free identity")
        }
        let relative = "profiles/free/\(app.rawValue)/\(alias)/\(profile.uuid).mobileprovision"
        try hooks.checkpoint(.storeProfile)
        try storeProfile(profileBytes, uuid: profile.uuid)
        let entry = LedgerFreeProfile(
            id: key, device: alias, deviceTail: Redactor.tail4(udid), app: app.rawValue, bundleId: bundleId,
            profileUuid: profile.uuid, created: profile.created.map(Self.wholeSeconds), expires: Self.wholeSeconds(expires),
            certFp8: identity.fp8, file: relative)
        let entryKey = key
        // The filler's signed app goes into place in one rename and is recorded in the same ledger write as the
        // profile; if that write fails the placement is taken back, so disk and ledger agree.
        var placed: (swapped: Bool, destination: String)?
        var signedRecord: LedgerFreeSigned?
        if let filler {
            let destination = "\(services.home.signedBuilds)/\(app.rawValue)/\(alias)/\(CarrierProject.productName)"
            try makeSignedDirectories((destination as NSString).deletingLastPathComponent)
            placed = (try SignCommand.place(filler.copy, at: destination), destination)
            signedRecord = LedgerFreeSigned(
                id: key, device: alias, app: app.rawValue, bundleId: bundleId, version: Self.fillerVersion,
                sha256Prefix: filler.sha256Prefix, profileUuid: profile.uuid, profileExpires: Self.wholeSeconds(expires),
                certFp8: identity.fp8, signedAt: now, path: Self.fillerSignedPath(alias: alias),
                strippedExtensions: [], droppedEntitlements: [])
        }
        let signedEntry = signedRecord
        let cleared: Bool
        do {
            try hooks.checkpoint(.finalLedgerWrite)
            cleared = try await services.ledgerStore.update { ledger -> Bool in
                ledger.freeProfiles.removeAll { $0.id == entryKey }
                ledger.freeProfiles.append(entry)
                ledger.freeProfiles.sort { $0.id < $1.id }
                if let signedEntry {
                    ledger.freeSigned.removeAll { $0.id == entryKey }
                    ledger.freeSigned.append(signedEntry)
                    ledger.freeSigned.sort { $0.id < $1.id }
                }
                let wasSuspended = ledger.freeSuspended != nil
                ledger.freeSuspended = nil
                return wasSuspended
            }
        } catch {
            if let placed, let filler {
                _ = SignCommand.restore(swapped: placed.swapped, scratchApp: filler.copy, destination: placed.destination)
            }
            throw error
        }
        let live = FreeAppIdBudget.live(
            FreeAppIdBudget.recording(ledger.freeAppIds, bundleId: bundleId, now: now), now: now)

        var data: [String: JSONValue] = [
            "app": .string(app.rawValue), "device": .string(alias), "bundleId": .string(bundleId),
            "profile": profileJSON(profile, expires: expires), "file": .string(relative),
            "appIdNew": .bool(budget.isNew), "appIdsLast7Days": .number(Double(live.count)),
            "identityChanged": false, "pinnedFp8": .string(identity.fp8), "pinnedNow": .bool(pinnedNow),
        ]
        if cleared { data["suspensionCleared"] = true }
        if signedRecord != nil { data["signed"] = .string(Self.fillerSignedPath(alias: alias)) }
        return .result(ProvisionCommand.command, data)
    }

    var key: String { "\(alias)/\(app.rawValue)" }

    // MARK: filler

    /// The version `freeSigned` records for the filler (it has no upstream release).
    static let fillerVersion = "1.0"

    static func fillerSignedPath(alias: String) -> String {
        "builds/signed/\(ProvisionApp.filler.rawValue)/\(alias)/\(CarrierProject.productName)"
    }

    private struct StagedFiller {
        /// The checked copy of the signed carrier, inside the scratch folder.
        let copy: String
        /// First 8 hex digits of the SHA-256 of the app's executable.
        let sha256Prefix: String
    }

    private enum FillerStep {
        case staged(StagedFiller)
        case stop(Envelope)
    }

    private static let fillerCopyFix = "Retry; if it repeats, open the carrier project in Xcode once. Nothing was recorded."

    /// Copies the Xcode-signed carrier (`ditto` keeps the signature) into a registered 0700 scratch folder and runs the
    /// free guard on the copy. Nothing is placed, stored or recorded here.
    private func prepareFiller(built: String, identity: FreeIdentity, scratch: inout ScratchDirectory?) async throws -> FillerStep {
        guard let pinned = CertReference(identity.sha1) else {
            return .stop(
                fail(
                    "FREE_IDENTITY_MISSING", "The pinned free-team identity has no usable fingerprint.",
                    "Check the login keychain (owner action)."))
        }
        // A folder left by a run that was killed; safe to remove under the lock.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: services.home.tmp)) ?? [] where name.hasPrefix("provision-") {
            _ = ScratchDirectory.removeTree(services.home.tmp + "/" + name)
        }
        let folder = try ScratchDirectory.create(under: services.home.tmp, registry: .shared, prefix: "provision")
        scratch = folder
        let copy = folder.path + "/" + CarrierProject.productName
        log("provision: copying the signed carrier")
        let copied = await services.runner.run(
            CommandSpec(executable: "/usr/bin/ditto", args: [built, copy], timeout: ProvisionCommand.toolTimeout))
        guard copied.code == 0 else {
            return .stop(
                fail(
                    "BUILD_PRODUCT_MISSING", "The signed carrier could not be copied for its checks.",
                    Self.fillerCopyFix))
        }
        guard let digest = Self.executableDigest(of: copy) else {
            return .stop(
                fail(
                    "BUILD_PRODUCT_MISSING", "The signed carrier has no readable executable.",
                    Self.fillerCopyFix))
        }
        let verdict = await Guard.run(
            context: .free(
                FreeSigning(
                    bundleId: bundleId, bundleIdPrefix: config.bundleIdPrefix, pinnedCertificate: pinned, now: now,
                    scratchRoot: services.home.tmp)),
            runner: services.runner, app: copy, udid: udid)
        guard verdict.passed else {
            return .stop(
                fail(
                    verdict.code ?? "GUARD_FAILED", verdict.reason ?? "The signed carrier failed the free-team guard.",
                    "Nothing was recorded. Check the free account in Xcode and retry."))
        }
        return .staged(StagedFiller(copy: copy, sha256Prefix: String(digest.prefix(8))))
    }

    /// SHA-256 (hex) of the file `CFBundleExecutable` names in the app's Info.plist; nil when it cannot be read.
    private static func executableDigest(of app: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: app + "/Info.plist")),
            let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
            let name = info["CFBundleExecutable"] as? String, IPAInspector.isPlainName(name), !name.hasPrefix(".")
        else { return nil }
        return (try? FileDigest.sha256(path: app + "/" + name))?.hex
    }

    /// `builds/signed/filler/<alias>/`, directories 0700 (as `sign` makes them).
    private func makeSignedDirectories(_ directory: String) throws {
        try makeDirectories(directory, mode: 0o700)
        var path = services.home.builds
        for part in ["signed", app.rawValue, alias] {
            path += "/" + part
            if chmod(path, 0o700) != 0 { throw ioError("chmod") }
        }
    }

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// The exact argv from the design: the carrier, this device by ID, a private derived data folder, automatic
    /// signing for the free team. The identity argument is one element (no shell). Device registration is added
    /// only for the owner's `--register-device --yes`.
    func buildArguments(project: String) -> [String] {
        var args = [
            "-project", project, "-scheme", CarrierProject.scheme, "-destination", "id=\(udid)",
            "-derivedDataPath", services.home.carrierDerivedData, "-allowProvisioningUpdates",
        ]
        if options.registerDevice && options.yes { args.append("-allowProvisioningDeviceRegistration") }
        args += [
            "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=\(Team.free)", "CODE_SIGN_IDENTITY=Apple Development",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleId)", "build",
        ]
        return args
    }

    private func invalidProfile(_ check: String, _ message: String) -> Envelope {
        fail(
            "PROFILE_INVALID", message,
            "Nothing was stored. Check the free account in Xcode and retry; the failed check is in `check`.",
            ["check": .string(check)])
    }

    private func profileJSON(_ profile: ProvisioningProfile, expires: Date) -> JSONValue {
        let days = Int((expires.timeIntervalSince(now) / 86_400).rounded(.down))
        return [
            "uuid": .string(profile.uuid), "created": profile.created.map(iso) ?? .null, "expires": iso(expires),
            "daysLeft": .number(Double(days)),
        ]
    }

    /// `profiles/free/<app>/<device>/<uuid>.mobileprovision`: directories 0700, file 0600.
    private func storeProfile(_ bytes: Data, uuid: String) throws {
        let dir = "\(services.home.freeProfiles)/\(app.rawValue)/\(alias)"
        try makeDirectories(dir, mode: 0o700)
        var path = services.home.home
        for part in ["profiles", "free", app.rawValue, alias] {
            path += "/" + part
            if chmod(path, 0o700) != 0 { throw ioError("chmod") }
        }
        try AtomicFile.write(bytes, to: "\(dir)/\(uuid).mobileprovision", mode: 0o600)
    }

    /// A hard stop: the free team's identities changed (or could not be compared) during a build. `change` is nil
    /// when the keychain could not be read afterwards; `buildSucceeded` is nil when the change was found at the
    /// start of this run, from a marker a dead run left (`interrupted`).
    private func identityStop(
        _ change: FreeIdentityGuard.Change?, buildSucceeded: Bool?, suspensionRecorded: Bool = true,
        interrupted: Bool = false
    ) -> Envelope {
        var extra: [String: JSONValue] = [
            "identityChanged": true, "suspended": .bool(suspensionRecorded),
            "addedFp8": .array((change?.addedFp8 ?? []).map { .string($0) }),
            "removedFp8": .array((change?.removedFp8 ?? []).map { .string($0) }),
        ]
        if let buildSucceeded { extra["buildSucceeded"] = .bool(buildSucceeded) }
        let suspendedText = suspensionRecorded
            ? "Auto-refresh is suspended." : "Auto-refresh could not be marked suspended (the ledger write failed)."
        guard let change else {
            return fail(
                "IDENTITY_CHECK_FAILED",
                "The keychain could not be read after the build, so the free team's identities could not be compared. The next run compares first.",
                "\(suspendedText) Unlock the login keychain and run `sideload doctor`; check Manage Certificates in Xcode.",
                extra)
        }
        let when = interrupted ? "during an earlier run that did not finish (interrupted or crashed)" : "during the build"
        return fail(
            "FREE_CERT_CHANGED",
            "The free team's signing identities changed \(when) (\(change.addedFp8.count) added, \(change.removedFp8.count) removed). Nothing was stored.",
            "\(suspendedText) The owner checks Xcode > Settings > Accounts > Manage Certificates, atvloadly and the lab (something created or revoked a free certificate). sideload never creates or revokes one. Run provision by hand once satisfied.",
            extra)
    }

    private func buildFailure(
        _ failure: ProvisionClassifier.Failure, _ build: RunResult, _ budget: FreeAppIdBudget.Decision
    ) -> Envelope {
        var extra: [String: JSONValue] = [:]
        if failure.code == "PROVISION_FAILED" {
            extra["logTail"] = .string(
                ProvisionClassifier.tail(stderr: build.stderr, stdout: build.stdout, redact: scrub))
        }
        if failure.code == "FREE_APP_ID_LIMIT" { extra["appIdsLast7Days"] = .number(Double(budget.recent)) }
        return fail(failure.code, failure.message, failure.fix, extra)
    }

    /// Build output with the device's IDs, names and the identities' common names masked.
    private func scrub(_ line: String) -> String {
        var out = line
        for name in [device.name].compactMap({ $0 }) + device.hostnames + identityNames where name.count >= 3 {
            out = out.replacingOccurrences(of: name, with: "<hidden>")
        }
        return Redactor(literals: [udid, device.coreDeviceId].compactMap { $0 }).redact(out)
    }
}
