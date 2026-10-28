import Foundation

/// What each menu action calls. The defaults are the real commands (the same in-process entry points the CLI runs, each
/// taking `.op.lock` itself); tests replace them.
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
    ///   - isCancelled: asked once the command has returned. A cancelled action skips the post-emit work, as a
    ///     signal-stopped CLI does.
    ///   - deliver: receives the outcome before the post-emit work runs.
    public static func perform(
        _ action: MenuAction, services: Services, steps: MenuActionSteps = MenuActionSteps(),
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
        case .renew(let device, let app):
            envelope = await steps.refresh(services, RefreshOptions(device: device, app: app, force: true, yes: true))
        case .install(let device, let app):
            envelope = await steps.install(services, InstallOptions(app: app, device: device, yes: true))
        case .remove(let device, let app):
            envelope = await steps.remove(services, AppOptions(sub: "remove", app: app, device: device, yes: true))
        case .lendable(let device, let app):
            envelope = await steps.lendable(
                services, DeviceOptions(sub: "lendable", alias: device, app: app, none: app == nil, yes: true))
        }
        let cancelled = isCancelled()
        await deliver(MenuActionOutcome(action: action, envelope: envelope, cancelled: cancelled))
        if !cancelled { await postEmit.runIfPending() }
    }
}
