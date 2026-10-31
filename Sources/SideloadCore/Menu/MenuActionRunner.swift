import Foundation

/// What each menu action calls. The defaults are the real commands (the same in-process entry points the CLI runs, each
/// taking `.op.lock` itself, except `device lendable`, which only writes config); tests replace them.
public struct MenuActionSteps: Sendable {
    public var refresh: @Sendable (Services, RefreshOptions) async -> Envelope = { await RefreshCommand.run($0, $1) }
    public var install: @Sendable (Services, InstallOptions) async -> Envelope = { await InstallCommand.run($0, $1) }
    public var remove: @Sendable (Services, AppOptions) async -> Envelope = { await AppCommand.run($0, $1) }
    public var lendable: @Sendable (Services, DeviceOptions) async -> Envelope = { await DeviceCommand.run($0, $1) }
    /// Add app: `fetch` (stage 1, and `--approve --version` in stage 2), then `provision`, `sign` and `install`.
    public var fetch: @Sendable (Services, FetchOptions) async -> Envelope = { await FetchCommand.run($0, $1) }
    public var provision: @Sendable (Services, ProvisionOptions) async -> Envelope = { await ProvisionCommand.run($0, $1) }
    public var sign: @Sendable (Services, SignOptions) async -> Envelope = { await SignCommand.run($0, $1) }

    public init() {}
}

/// Runs one confirmed menu action (design section 12). The owner's click on the confirm button is the `--yes`.
public enum MenuActionRunner {
    /// Runs `action` and hands the outcome to `deliver`, then runs the work the command left for after its result
    /// (`provision` settling its ledger record of moved profiles), as the CLI does after it writes its object.
    ///
    /// - Parameters:
    ///   - renewApps: for "All apps", the apps the confirm listed. The run renews exactly these, one `refresh` call each, and
    ///     never asks `refresh` to choose: an app that became due after the panel was drawn is not touched.
    ///   - isCancelled: asked once the command has returned. A cancelled action skips the post-emit work, as a
    ///     signal-stopped CLI does.
    ///   - deliver: receives the outcome before the post-emit work runs.
    public static func perform(
        _ action: MenuAction, renewApps: [String] = [], services: Services, steps: MenuActionSteps = MenuActionSteps(),
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }, deliver: @Sendable (MenuActionOutcome) async -> Void
    ) async {
        // `Services.live()` leaves both at their inert defaults and only the CLI wires its own, so each action gets fresh
        // ones: nothing registered by one action can be run, or reported, by the next.
        var services = services
        let postEmit = PostEmit()
        services.postEmit = postEmit
        services.interruptReport = InterruptReport()

        let envelope: Envelope
        switch action {
        case .renew(let device, let app?):
            envelope = await steps.refresh(services, RefreshOptions(device: device, app: app, force: true, yes: true))
        case .renew(let device, nil):
            envelope = await renewEach(renewApps, device: device, services: services, steps: steps, isCancelled: isCancelled)
        case .install(let device, let app):
            envelope = await steps.install(services, InstallOptions(app: app, device: device, yes: true))
        case .remove(let device, let app):
            envelope = await steps.remove(services, AppOptions(sub: "remove", app: app, device: device, yes: true))
        case .addFetch(_, let app), .updateFetch(_, let app, _):
            envelope = await steps.fetch(services, FetchOptions(app: app))
        case .addApprove(let device, let app, let fetched), .updateApprove(let device, let app, _, let fetched):
            if let reason = addStop(app: app, fetched: fetched, services: services) {
                await deliver(.notRun(reason))
                return
            }
            // Update is the same chain: the app is already installed, so `install` goes over it and keeps its data.
            envelope = await runChain(
                app, device: device, version: fetched.version, sha256: fetched.sha256, command: (action.chain ?? .add).command,
                approve: true, services: services, steps: steps, isCancelled: isCancelled)
        case .reinstallPrevious(let device, let app, _, let to):
            if let reason = reinstallStop(app: app, to: to, services: services) {
                await deliver(.notRun(reason))
                return
            }
            // Already fetched and approved: only the tail of the Update chain, signing exactly `to`.
            envelope = await runChain(
                app, device: device, version: to.version, sha256: to.sha256, command: "reinstall", approve: false,
                services: services, steps: steps, isCancelled: isCancelled)
        case .lendable(let device, let app):
            // `device lendable` takes no `.op.lock`, so a lab `slot lend` can land after the panel was drawn: the ledger is
            // read again here, and the setting is not written while the device has a lent or pending slot.
            if let reason = lendableStop(device: device, services: services) {
                await deliver(.notRun(reason))
                return
            }
            envelope = await steps.lendable(
                services, DeviceOptions(sub: "lendable", alias: device, app: app, none: app == nil, yes: true))
        }
        let cancelled = isCancelled()
        await deliver(MenuActionOutcome(action: action, envelope: envelope, cancelled: cancelled))
        if !cancelled { await postEmit.runIfPending() }
    }

    /// Why the lendable setting must not be written now: the ledger as it is on disk says the device has a lent or pending
    /// slot, or cannot be read. Nil when it is clear.
    static func lendableStop(device: String, services: Services) -> String? {
        let ledger: Ledger
        do {
            ledger = try services.ledgerStore.load()
        } catch {
            return MenuActions.ledgerUnreadable
        }
        // Only a lend or an op still inside its window can collide with the lab; an op past its window is what the panel
        // already settled from a live read. A lent record the panel settled from a live read still refuses here (it holds
        // until a command writes the settled record): that errs on the lab's side.
        let now = services.clock.now()
        let busy = SlotRule.migrated(ledger, now: now).slots.contains { slot in
            slot.device == device && (slot.lentTo != nil || slot.op.map { SlotRule.remaining($0, now: now) != nil } == true)
        }
        return busy ? MenuActions.lentOrChanging(device) : nil
    }

    /// The steps of the second Add app (and Update) confirm, in order.
    enum AddStep: String, CaseIterable, Sendable {
        case approve, provision, sign, install

        var title: String { MenuFormat.capitalised(rawValue) }

        func text(skipped: Bool, appIdNew: Bool) -> String {
            switch self {
            case .approve: skipped ? "Already approved" : "Approved"
            case .provision: skipped ? "Profile still fresh" : appIdNew ? "Profile ready · new App ID" : "Profile ready"
            case .sign: skipped ? "Signed build is current" : "Signed"
            case .install: "Installed"
            }
        }
    }

    /// The status the runner records for a step in the add envelope.
    enum AddStepStatus: String, Sendable {
        case done, skipped, failed
    }

    /// A profile with this many days left or more is used as it is: `provision` within 24 h of the last one answers
    /// `PROFILE_NOT_RENEWED`, and `refresh` renews at 6 days.
    static let freshProfileDays = Double(RefreshPolicy.maxWithin)

    /// The one rule for "the stored profile is fresh, skip `provision`": the run and the confirm that describes it both ask it.
    static func profileIsFresh(expires: Date, now: Date) -> Bool {
        expires.timeIntervalSince(now) >= freshProfileDays * FreeInstallExpiry.secondsPerDay
    }

    /// Why the approval must not run: the manifest as it is on disk has no such entry, or its file is not the one the owner
    /// saw (a different SHA-256). Nil when it matches.
    static func addStop(app: String, fetched: MenuFetched, services: Services) -> String? {
        let manifest: Manifest
        do {
            manifest = try ManifestStore(paths: services.home).load()
        } catch {
            return "The fetched file could not be checked. Fetch it again."
        }
        guard let entry = manifest.entry(app: app, version: fetched.version), entry.prunedAt == nil else {
            return "\(MenuFormat.appName(app)) \(fetched.version) is no longer fetched. Fetch it again."
        }
        guard entry.sha256 == fetched.sha256 else { return "The fetched file changed since you reviewed it. Fetch it again." }
        return nil
    }

    /// Why Reinstall previous version must not run: the manifest as it is on disk has no approved, unpruned entry for `to`, its
    /// file is not the one the owner saw (a different SHA-256), or the file is gone. Nil when it matches.
    static func reinstallStop(app: String, to: MenuPrevious, services: Services) -> String? {
        let store = ManifestStore(paths: services.home)
        let manifest: Manifest
        do {
            manifest = try store.load()
        } catch {
            return "The stored file could not be checked. Fetch it again."
        }
        let name = "\(MenuFormat.appName(app)) \(MenuFormat.version(to.version))"
        guard let entry = manifest.entry(app: app, version: to.version), entry.approved, store.hasFile(entry) else {
            return "\(name) is no longer stored and approved."
        }
        guard entry.sha256 == to.sha256 else { return "The stored file for \(name) changed since you reviewed it." }
        return nil
    }

    /// Add app and Update, stage 2 (`approve`): approve exactly the confirmed version, then only the steps still needed, then
    /// install, folded into one `add`- (or `update`-) shaped envelope with a status per step. Reinstall previous version is the
    /// same tail without the approval (`approve` false: the build is already approved, and no `approve` step is recorded). Each
    /// command takes `.op.lock` itself, so the lab can interleave between
    /// steps. A step that is already done (a profile with 6 days or more left, a signed build for this version and profile) is
    /// skipped, so a run that stopped halfway resumes. Stops between steps when cancelled, and on the first failure.
    private static func runChain(
        _ app: String, device: String, version: String, sha256: String, command: String, approve: Bool, services: Services,
        steps: MenuActionSteps, isCancelled: @Sendable () -> Bool
    ) async -> Envelope {
        var results: [JSONValue] = []
        var warnings: [JSONValue] = []
        var appIdNew: Bool?
        var installStarted = false
        func record(_ step: AddStep, _ status: AddStepStatus) {
            results.append(["step": .string(step.rawValue), "status": .string(status.rawValue)])
        }
        func finish(_ failed: AddStep? = nil, _ error: Envelope.Entry? = nil) -> Envelope {
            if let failed { record(failed, .failed) }
            var data: [String: JSONValue] = [
                "device": .string(device), "app": .string(app), "version": .string(version),
                "steps": .array(results), "warnings": .array(warnings),
            ]
            if let appIdNew { data["appIdNew"] = .bool(appIdNew) }
            if installStarted { data["installStarted"] = true }
            return Envelope(ok: failed == nil, command: command, data: data, errors: error.map { [$0] } ?? [])
        }
        func stop(_ step: AddStep, _ envelope: Envelope) -> Envelope {
            finish(step, envelope.errors.first ?? .init(code: "INTERNAL_ERROR", message: "\(step.rawValue) failed.", fix: nil))
        }
        func interrupted(_ step: AddStep) -> Envelope? {
            guard isCancelled() else { return nil }
            return finish(step, .init(code: RefreshPolicy.interrupted, message: "The run was interrupted.", fix: nil))
        }
        let id = "\(device)/\(app)"
        let loadLedger = { () -> Ledger in try services.ledgerStore.load() }
        func profile(in ledger: Ledger) -> LedgerFreeProfile? { ledger.freeProfiles.first { $0.id == id } }
        func signed(in ledger: Ledger) -> LedgerFreeSigned? { ledger.freeSigned.first { $0.id == id } }

        // 1. Approve this exact version (offline: it re-hashes and inspects the stored file).
        if approve {
            let approved = await steps.fetch(services, FetchOptions(app: app, approve: true, version: version))
            guard approved.ok else { return stop(.approve, approved) }
            guard approved.data["sha256"] == .string(sha256) else {
                return finish(
                    .approve,
                    .init(
                        code: "DIGEST_MISMATCH", message: "The approved file is not the one you reviewed. Nothing was signed.",
                        fix: "Fetch it again and review the SHA-256."))
            }
            record(.approve, approved.data["alreadyApproved"] == .bool(true) ? .skipped : .done)
        }

        // 2. Provision, unless a stored profile is still fresh.
        if let stopped = interrupted(.provision) { return stopped }
        do {
            let ledger = try loadLedger()
            let fresh = profile(in: ledger).map { profileIsFresh(expires: $0.expires, now: services.clock.now()) }
            if fresh == true {
                record(.provision, .skipped)
            } else {
                var envelope = await steps.provision(services, ProvisionOptions(app: app, device: device, yes: true))
                // Like `refresh`: only a profile that did not move is retried, once, with the renewal of our own cached copy.
                if !envelope.ok, envelope.errors.first?.code == "PROFILE_NOT_RENEWED" {
                    envelope = await steps.provision(services, ProvisionOptions(app: app, device: device, renew: true, yes: true))
                }
                guard envelope.ok else { return stop(.provision, envelope) }
                if case .bool(let isNew)? = envelope.data["appIdNew"] { appIdNew = isNew }
                record(.provision, .done)
            }
        } catch {
            return stop(.provision, .from(error, command: command))
        }

        // 3. Sign exactly this version, unless the signed build already is this version on the stored profile.
        if let stopped = interrupted(.sign) { return stopped }
        do {
            let ledger = try loadLedger()
            let prefix = String(sha256.prefix(8))
            let current = signed(in: ledger).map { build in
                build.version == version && build.sha256Prefix == prefix
                    && build.profileUuid == profile(in: ledger)?.profileUuid
            }
            var status = AddStepStatus.skipped
            if current != true {
                let envelope = await steps.sign(services, SignOptions(app: app, device: device, yes: true, version: version))
                guard envelope.ok else { return stop(.sign, envelope) }
                status = .done
            }
            // `install` puts whatever `freeSigned` holds on the device: it must be what the owner approved.
            let after = signed(in: try loadLedger())
            guard after?.version == version, after?.sha256Prefix == prefix else {
                return finish(
                    .sign,
                    .init(
                        code: "SIGNED_BUILD_MISMATCH", message: "The signed build is not the version you approved. Nothing was installed.",
                        fix: approve
                            ? "Don't install this build. Re-sign with `sideload sign --app \(app) --device \(device) --yes` (it signs the newest approved version), then use Install."
                            : "Don't install this build. Re-sign with `sideload sign --app \(app) --device \(device) --version \(version) --yes`, then `sideload install --app \(app) --device \(device) --yes`."))
            }
            record(.sign, status)
        } catch {
            return stop(.sign, .from(error, command: command))
        }

        // 4. Install.
        if let stopped = interrupted(.install) { return stopped }
        installStarted = true
        let installed = await steps.install(services, InstallOptions(app: app, device: device, yes: true))
        guard installed.ok else { return stop(.install, installed) }
        if case .array(let more)? = installed.data["warnings"] { warnings += more }
        record(.install, .done)
        return finish()
    }

    /// "All apps": one `refresh --app X --force` per listed app, in order, folded into one `refresh`-shaped envelope. Like
    /// one run of `refresh`, it goes on past an app's own failure, stops on a fatal one (the rest are skipped with its
    /// code) and on a busy lock, and between apps when cancelled. Each call takes `.op.lock` per step, so the lab can
    /// interleave between apps.
    private static func renewEach(
        _ apps: [String], device: String, services: Services, steps: MenuActionSteps, isCancelled: @Sendable () -> Bool
    ) async -> Envelope {
        var results: [JSONValue] = []
        var errors: [Envelope.Entry] = []
        var warnings: [JSONValue] = []
        var stop: String?
        for app in apps {
            if stop == nil, isCancelled() {
                stop = RefreshPolicy.interrupted
                errors.append(.init(code: RefreshPolicy.interrupted, message: "The run was interrupted.", fix: nil))
            }
            if let stop {
                results.append(["app": .string(app), "status": "skipped", "code": .string(stop)])
                continue
            }
            let envelope = await steps.refresh(services, RefreshOptions(device: device, app: app, force: true, yes: true))
            var entry: JSONValue?
            if case .array(let items)? = envelope.data["results"] {
                entry = items.first { item in
                    if case .object(let fields) = item { return fields["app"] == .string(app) }
                    return false
                }
            }
            if let entry {
                results.append(entry)
            } else if envelope.ok {
                results.append(["app": .string(app), "status": "skipped", "code": .string(RefreshPolicy.notDue)])
            } else {
                // Stopped before any app ran (a suspension, a pending change, a config problem).
                let code = envelope.errors.first?.code ?? "INTERNAL_ERROR"
                results.append(["app": .string(app), "status": "failed", "code": .string(code)])
            }
            if case .array(let more)? = envelope.data["warnings"] { warnings += more }
            for error in envelope.errors {
                let named = error.message.hasPrefix("\(app): ") ? error.message : "\(app): \(error.message)"
                errors.append(.init(code: error.code, message: named, fix: error.fix))
            }
            if let failed = envelope.errors.first?.code, RefreshPolicy.isFatal(failed) || failed == OperationLock.busyCode {
                stop = failed
            }
        }
        return Envelope(
            ok: errors.isEmpty, command: "refresh",
            data: ["device": .string(device), "results": .array(results), "warnings": .array(warnings)], errors: errors)
    }
}
