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
/// device cards, which say "checking…" until it answers.
@MainActor @Observable
final class MenuModel {
    private(set) var panel: MenuPanel = .loading
    private(set) var doctor: DoctorState = .idle

    let services: Services
    private var loadTask: Task<Void, Never>?
    private var doctorTask: Task<Void, Never>?
    /// Bumped by every `runDoctor` and `cancelDoctor`: only the latest run may write its result.
    private var doctorGeneration = 0
    private var lastLoadFinished: Date?

    /// Panel-open events can arrive in bursts; a load that finished this recently is not repeated.
    private static let openDebounce: TimeInterval = 2

    init(services: Services = .live()) {
        self.services = services
    }

    var configPath: String { services.home.config }
    var homePath: String { services.home.home }

    /// `force` is the explicit "Check status now"; a panel-open event passes false.
    func reload(force: Bool = false) {
        if loadTask != nil { return }
        if !force, let last = lastLoadFinished, Date().timeIntervalSince(last) < Self.openDebounce { return }
        loadTask = Task { [services] in
            let local = await Task.detached { MenuLoader.loadLocal(services) }.value
            panel = MenuLoader.panel(local, probe: .checking)
            if case .ready(let inputs) = local {
                let probe = await MenuLoader.probeDevices(services, saved: inputs.config)
                panel = MenuLoader.panel(local, probe: probe)
            }
            lastLoadFinished = Date()
            loadTask = nil
        }
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
