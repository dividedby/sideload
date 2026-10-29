import Foundation
import Observation
import SideloadCore

/// What "Run doctor" is doing (the result shows inline in the panel).
enum DoctorState: Equatable {
    case idle
    case running
    case done(DoctorSummary)
}

/// The panel's one view model (design section 12). No timers: the snapshot loads at launch, when the panel opens and on
/// "Check status now". Local files fill the panel at once; `devicectl list devices` (about 1 to 2 s) then settles the
/// device cards, which say "checking…" until it answers. Each visible device's app list is then read once
/// (`MenuAppsCache`: at launch, on "Check status now", and on an open only when the last attempt is 5 minutes old), one
/// device after the other, repainting after each. The update check (`MenuUpdates.check`, the one network call the panel
/// makes on its own, at most one metadata GET per approved installed source and only when the 6 h cadence allows) runs as a
/// task of its own once the device reads are done, one at a time, and repaints when it ends.
@MainActor @Observable
final class MenuModel {
    private(set) var panel: MenuPanel = .loading
    private(set) var doctor: DoctorState = .idle
    private(set) var actionState: MenuActionState = .idle

    let services: Services
    private(set) var loadTask: Task<Void, Never>?
    private var doctorTask: Task<Void, Never>?
    /// Bumped by every `runDoctor` and `cancelDoctor`: only the latest run may write its result.
    private var doctorGeneration = 0
    private var lastLoadFinished: Date?
    /// "Check status now" arrived while a load was running.
    private var pendingForce = false
    private var apps = MenuAppsCache()
    private let steps: MenuActionSteps
    private var actionTask: Task<Void, Never>?
    /// The update check, one at a time; cancelled on shutdown.
    private(set) var updateTask: Task<Void, Never>?
    /// What the checks of this session listed; `MenuLoader.panel` lays it over `updates.json`.
    private var checked: [String: MenuUpstream] = [:]
    /// Add app: the second confirm a successful fetch opened, held until the fetch task has ended.
    private var proceed: MenuAction?
    /// Bumped when an action starts: a load that began earlier must not write anything after it.
    private var loadGeneration = 0
    /// The last local read, so the icon can be redrawn (`renewing`) without reading again.
    private var lastLocal: MenuLoader.Local?

    /// Panel-open events can arrive in bursts; a load that finished this recently is not repeated.
    private static let openDebounce: TimeInterval = 2

    init(services: Services = .live(), steps: MenuActionSteps = MenuActionSteps()) {
        self.services = services
        self.steps = steps
    }

    /// An action's command is running (until its post-result work is done too).
    var actionBusy: Bool { actionTask != nil }

    var configPath: String { services.home.config }
    var homePath: String { services.home.home }

    /// `force` is the explicit "Check status now"; a panel-open event passes false. Does nothing while an action runs: its
    /// own end re-reads the device it changed.
    func reload(force: Bool = false) {
        if actionTask != nil { return }
        if loadTask != nil {
            // A running load may hold a read up to 5 minutes old: the owner's explicit check runs once it ends.
            if force { pendingForce = true }
            return
        }
        if !force, let last = lastLoadFinished, services.clock.now().timeIntervalSince(last) < Self.openDebounce { return }
        let generation = loadGeneration
        loadTask = Task { [services] in
            let local = await Task.detached { MenuLoader.loadLocal(services) }.value
            guard generation == loadGeneration else { return }
            lastLocal = local
            panel = MenuLoader.firstPaint(local, cache: apps, checked: checked)
            if case .ready(let inputs) = local {
                let probe = await MenuLoader.probeDevices(services, saved: inputs.config)
                guard generation == loadGeneration else { return }
                apps.remember(probe)
                let visible = MenuLoader.visibleAliases(inputs.config, probe: probe)
                apps.retain(visible)
                // Every device still to be read says so at once, not when its turn comes; one with an earlier answer keeps
                // showing it while it is read again.
                let due = visible.filter { apps.needsRead($0, force: force, now: services.clock.now()) }
                for alias in due where apps.entries[alias] == nil { apps.set(alias, .checking) }
                panel = MenuLoader.panel(local, probe: probe, apps: apps.entries, checked: checked)
                for alias in due {
                    let read = await MenuLoader.readApps(services, alias: alias, prefix: inputs.config.bundleIdPrefix)
                    guard generation == loadGeneration else { return }
                    apps.set(alias, read)
                    panel = MenuLoader.panel(local, probe: probe, apps: apps.entries, checked: checked)
                }
                // A lend or return by the lab can land while the reads run: draw once more from the ledger as it is now.
                let fresh = await Task.detached { MenuLoader.loadLocal(services) }.value
                guard generation == loadGeneration else { return }
                lastLocal = fresh
                panel = MenuLoader.panel(fresh, probe: probe, apps: apps.entries, checked: checked)
            }
            lastLoadFinished = services.clock.now()
            loadTask = nil
            if case .ready = local { checkUpdates(force: force) }
            if pendingForce {
                pendingForce = false
                reload(force: true)
            }
        }
    }

    /// The update check, after the device reads: one at a time, never while an action runs (its end reloads, and that load
    /// checks again). `MenuUpdates.check` decides by its own cadence whether any source is asked at all, so a panel open
    /// within 6 h of the last check makes no request; `force` ("Check status now") keeps only the 5-minute floor.
    private func checkUpdates(force: Bool) {
        guard updateTask == nil, actionTask == nil else { return }
        updateTask = Task { [services] in
            let listed = await MenuUpdates.check(services, force: force)
            updateTask = nil
            // A shut-down or replaced check says nothing; an action that began meanwhile repaints when it ends.
            guard !Task.isCancelled, !listed.isEmpty else { return }
            checked.merge(listed) { _, new in new }
            if actionTask == nil, loadTask == nil { repaint(renewing: false) }
        }
    }

    // MARK: actions

    /// Opens the inline confirm for `action`. Nothing runs. Ignored while an action runs or when the action is not
    /// available in the current panel.
    func request(_ action: MenuAction) {
        guard actionTask == nil, case .loaded(let snapshot) = panel else { return }
        guard let prompt = MenuActions.prompt(for: action, in: snapshot, now: services.clock.now()) else { return }
        actionState = .confirming(action, prompt)
    }

    /// The owner's click on the confirm button. The action is checked again against the panel as it is now.
    func confirm() {
        guard actionTask == nil, case .confirming(let action, let shown) = actionState else { return }
        guard case .loaded(let snapshot) = panel else {
            actionState = .finished(.notRun("The panel is not loaded."))
            return
        }
        // Only what the owner saw may run: the confirm is worked out again from the panel as it is now.
        let prompt: MenuPrompt
        switch MenuActions.reconfirm(action, shown: shown, in: snapshot, now: services.clock.now()) {
        case .run(let same): prompt = same
        case .show(let changed):
            actionState = .confirming(action, changed)
            return
        case .blocked(let reason):
            actionState = .finished(.notRun(reason))
            return
        }
        // A load in flight must not write over the action's state or store a read cut short by it. The fetch of Add app
        // changes neither the device nor the ledger, so it leaves the load alone and the panel stays current for stage 2.
        if !action.isFetchStage {
            loadGeneration += 1
            loadTask?.cancel()
            loadTask = nil
            pendingForce = false
        }
        actionState = .running(label: prompt.runningLabel, cancellable: MenuActions.cancellable(action), cancelling: false)
        if case .renew = action { repaint(renewing: true) }
        actionTask = Task { [services, steps] in
            await MenuActionRunner.perform(action, renewApps: prompt.apps, services: services, steps: steps) { outcome in
                await self.deliver(outcome)
            }
            finishAction(action)
        }
    }

    private func deliver(_ outcome: MenuActionOutcome) {
        if let next = outcome.proceed {
            // No result card: the fetched version goes straight to its approval confirm once the task ends.
            proceed = next
            return
        }
        actionState = .finished(outcome)
    }

    /// The command and its post-result work are done: forget what was read of the device and read it again at once.
    private func finishAction(_ action: MenuAction) {
        actionTask = nil
        if let next = proceed {
            // Stage 1 changed nothing on the device or in the ledger: the device cache stays and nothing reloads, or the
            // card would say "Checking apps…" and the second confirm could not open.
            proceed = nil
            openApproval(next)
            return
        }
        // A fetch that failed, was busy or was cancelled changed nothing either.
        if action.isFetchStage { return }
        invalidateAndReload(action)
    }

    private func openApproval(_ action: MenuAction) {
        actionState = .idle
        request(action)
        if case .confirming = actionState { return }
        // The panel moved on while the fetch ran (a device went away, a slot was taken): say why, and read the device again.
        actionState = .finished(.notRun(MenuActions.blockedReason(action, in: panelSnapshot, now: services.clock.now())))
        invalidateAndReload(action)
    }

    /// Forgets what was read of the action's device and reads it again at once.
    private func invalidateAndReload(_ action: MenuAction) {
        apps.invalidate(action.device)
        repaint(renewing: false)
        lastLoadFinished = nil
        reload()
    }

    private var panelSnapshot: MenuSnapshot? {
        if case .loaded(let snapshot) = panel { return snapshot }
        return nil
    }

    func cancelAction() {
        guard case .running(let label, let cancellable, false) = actionState, cancellable else { return }
        actionState = .running(label: label, cancellable: cancellable, cancelling: true)
        actionTask?.cancel()
    }

    /// Quit and SIGTERM: Cancel's stop, plus the command's post-result work, which still runs after the result is shown or
    /// dismissed (the on-card Cancel is gone by then, so `cancelAction` alone would leave the task running until the kill).
    func cancelForShutdown() {
        updateTask?.cancel()
        if case .running = actionState { cancelAction() } else { actionTask?.cancel() }
    }

    /// Closes the confirm or the result.
    func dismiss() {
        switch actionState {
        case .confirming, .finished: actionState = .idle
        case .idle, .running: break
        }
    }

    /// The controls take a click unless an action is being confirmed or run (a finished result is replaced by the next).
    var controlsEnabled: Bool {
        switch actionState {
        case .idle: true
        // A result is replaced by the next action, but not while the command's post-result work still runs.
        case .finished: actionTask == nil
        case .confirming, .running: false
        }
    }

    func availability(_ action: MenuAction, in snapshot: MenuSnapshot) -> MenuAvailability {
        if !controlsEnabled { return .disabled(MenuActions.controlsBusy) }
        return MenuActions.availability(action, in: snapshot, now: services.clock.now())
    }

    /// A result's Retry, against the panel as it is now (it goes through the confirm, which checks again).
    func retryAvailability(_ action: MenuAction) -> MenuAvailability {
        guard case .loaded(let snapshot) = panel else { return .disabled("Panel not loaded") }
        return availability(action, in: snapshot)
    }

    func offers(for row: MenuAppRow, on card: MenuDeviceCard, in snapshot: MenuSnapshot) -> [MenuOffer] {
        MenuActions.rowOffers(row, card: card, snapshot: snapshot, now: services.clock.now()).map { offer in
            var offer = offer
            if !controlsEnabled { offer.availability = .disabled(MenuActions.controlsBusy) }
            return offer
        }
    }

    private func repaint(renewing: Bool) {
        guard let local = lastLocal else { return }
        panel = MenuLoader.panel(
            local, probe: apps.lastProbe ?? .checking, apps: apps.entries, renewing: renewing, checked: checked)
    }

    func runDoctor() {
        if doctor == .running { return }
        doctor = .running
        doctorGeneration += 1
        let generation = doctorGeneration
        doctorTask = Task { [services] in
            let summary = await DoctorSummary.run(services)
            // A cancelled (or replaced) run must not write over a newer one.
            guard generation == doctorGeneration else { return }
            doctor = .done(summary)
            doctorTask = nil
        }
    }

    func cancelDoctor() {
        doctorGeneration += 1
        doctorTask?.cancel()
        doctorTask = nil
        doctor = .idle
    }

    func dismissDoctor() {
        doctorGeneration += 1
        doctor = .idle
    }
}
