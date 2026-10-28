import Foundation

/// What each menu action calls. The defaults are the real commands (the same in-process entry points the CLI runs, each
/// taking `.op.lock` itself, except `device lendable`, which only writes config); tests replace them.
public struct MenuActionSteps: Sendable {
    public var refresh: @Sendable (Services, RefreshOptions) async -> Envelope = { await RefreshCommand.run($0, $1) }
    public var install: @Sendable (Services, InstallOptions) async -> Envelope = { await InstallCommand.run($0, $1) }
    public var remove: @Sendable (Services, AppOptions) async -> Envelope = { await AppCommand.run($0, $1) }
    public var lendable: @Sendable (Services, DeviceOptions) async -> Envelope = { await DeviceCommand.run($0, $1) }

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
        // already settled from a live read, so it does not refuse a confirm the panel offered.
        let now = services.clock.now()
        let busy = SlotRule.migrated(ledger, now: now).slots.contains { slot in
            slot.device == device && (slot.lentTo != nil || slot.op.map { SlotRule.remaining($0, now: now) != nil } == true)
        }
        return busy ? MenuActions.lentOrChanging(device) : nil
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
                stop = "INTERRUPTED"
                errors.append(.init(code: "INTERRUPTED", message: "The run was interrupted.", fix: nil))
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
                results.append(["app": .string(app), "status": "skipped", "code": "NOT_DUE"])
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
            if let failed = envelope.errors.first?.code, RefreshPolicy.isFatal(failed) || failed == "OPERATION_IN_PROGRESS" {
                stop = failed
            }
        }
        return Envelope(
            ok: errors.isEmpty, command: "refresh",
            data: ["device": .string(device), "results": .array(results), "warnings": .array(warnings)], errors: errors)
    }
}
