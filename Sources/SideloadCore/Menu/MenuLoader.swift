import Foundation

/// Reads what the panel shows (design section 12). Local files first (instant: the config, the ledger, the canary log and
/// the app-data backups' manifests for the pending-restore notice), then one `devicectl list devices`
/// (about 1 to 2 s) for visibility and transport. Nothing here writes, locks, or touches the keychain, the portal or
/// the network; there are no timers: the app calls it at launch, when the panel opens and on "Check status now".
public enum MenuLoader {
    /// The part of the snapshot that comes from `config.json`, `ledger.json`, `logs/canary.jsonl` and the backup manifests.
    public enum Local: Sendable {
        case ready(MenuInputs)
        case firstRun(MenuIssue)
        case failed(MenuIssue)
    }

    /// The doctor's fix for a Mac with no saved device, shown on first run.
    public static let firstRunFix = DeviceCheck.fixSave

    public static func loadLocal(_ services: Services) -> Local {
        // No config at all is a first run, not a failure. The file may exist and not parse; that is a failure.
        guard FileManager.default.fileExists(atPath: services.home.config) else {
            return .firstRun(
                MenuIssue(
                    code: "NOT_SET_UP", message: "sideload has not been set up on this Mac yet (no config.json).",
                    fix: firstRunFix))
        }
        let config: Config
        do {
            config = try services.store.load()
        } catch {
            return .failed(MenuIssue(error))
        }

        var notices: [MenuIssue] = []
        var canaryStatus: String?
        do {
            if case .string(let status)? = try CanaryHistory.read(services.home.canaryLog).records.last?["status"] {
                canaryStatus = status
            }
        } catch {
            notices.append(MenuIssue(error))
        }
        var ledger = Ledger()
        var ledgerReadable = true
        do {
            ledger = try services.ledgerStore.load()
        } catch {
            ledgerReadable = false
            notices.append(MenuIssue(error))
        }
        // The same pending-restore warning `status` prints; an unreadable ledger says nothing about which apps are lent.
        if ledgerReadable {
            for entry in PendingRestores.find(services, config: config, ledger: ledger, now: services.clock.now()) {
                notices.append(MenuIssue(PendingRestores.warning(entry)))
            }
        }
        return .ready(
            MenuInputs(
                now: services.clock.now(), canaryStatus: canaryStatus, config: config, ledger: ledger,
                probe: .checking, notices: notices, ledgerReadable: ledgerReadable))
    }

    /// `devicectl list devices` through `DeviceCtl` (read-only). With no saved device there is nothing to ask.
    public static func probeDevices(_ services: Services, saved: Config) async -> DeviceProbe {
        if saved.devices.isEmpty { return .listed([]) }
        do {
            guard let devices = try await services.deviceCtl.listDevices() else { return .failed }
            return .listed(devices)
        } catch {
            return .failed
        }
    }

    public static func panel(_ local: Local, probe: DeviceProbe) -> MenuPanel {
        switch local {
        case .firstRun(let issue): return MenuPanel.firstRun(issue)
        case .failed(let issue): return MenuPanel.failed(issue)
        case .ready(var inputs):
            inputs.probe = probe
            return .loaded(MenuSnapshotBuilder.build(inputs))
        }
    }
}

/// `doctor` for the panel: the checks run in-process through `Doctor.run` (which uses the `Runner`), so the app needs
/// no copy of the CLI. Messages are redacted again here.
public struct DoctorSummary: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String
        public var severity: CheckResult.Severity
        public var message: String
        public var fix: String?
    }

    public var ok: Bool
    public var rows: [Row]

    public init(ok: Bool, rows: [Row]) {
        self.ok = ok
        self.rows = rows
    }

    public init(_ envelope: Envelope) {
        var rows: [Row] = []
        if case .array(let checks)? = envelope.data["checks"] {
            for case .object(let check) in checks {
                guard case .string(let id)? = check["id"], case .string(let message)? = check["message"] else { continue }
                var severity = CheckResult.Severity.info
                if case .string(let raw)? = check["severity"], let parsed = CheckResult.Severity(rawValue: raw) {
                    severity = parsed
                }
                var fix: String?
                if case .string(let text)? = check["fix"] { fix = Redactor.redactPatterns(text) }
                rows.append(
                    Row(
                        id: id + "-\(rows.count)", severity: severity, message: Redactor.redactPatterns(message), fix: fix))
            }
        }
        self.init(ok: envelope.ok, rows: rows)
    }

    public static func run(_ services: Services) async -> DoctorSummary {
        DoctorSummary(await Doctor.run(services))
    }
}
