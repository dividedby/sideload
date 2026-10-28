import Foundation

/// Reads what the panel shows (design section 12). Local files first (instant: the config, the ledger, the canary log and
/// the app-data backups' manifests for the pending-restore notice), then one `devicectl list devices`
/// (about 1 to 2 s) for visibility and transport, then one `device info apps` per visible device. Nothing here writes, locks,
/// or touches the keychain, the portal or the network; there are no timers: the app calls it at launch, when the panel
/// opens and on "Check status now".
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

    /// The saved devices that `devicectl list devices` shows as paired and reachable: the ones worth a `device info apps`.
    /// Sorted, so reads happen in a stable order.
    public static func visibleAliases(_ config: Config, probe: DeviceProbe) -> [String] {
        config.devices.keys.sorted().filter { alias in
            config.devices[alias].map { MenuSnapshotBuilder.presence(of: $0, probe: probe).isVisible } ?? false
        }
    }

    /// One read-only `devicectl device info apps` on a saved device (about 1 to 3 s, at most 15 s), through `DeviceCtl`.
    /// It takes no lock and writes nothing: no ledger, no config, no profile read. The call names the `apollo` free ID only
    /// because `FreeDeviceCalls` carries one; `info apps` is not an app mutation and the ID is never sent. A failed, locked
    /// or timed-out read keeps its error code and never looks like an empty device.
    public static func readApps(_ services: Services, alias: String) async -> DeviceAppsProbe {
        guard let prefix = (try? services.store.load())?.bundleIdPrefix, CanaryCommand.isValidPrefix(prefix) else {
            return .failed(code: "CONFIG_MISSING", takenAt: services.clock.now())
        }
        let calls = FreeDeviceCalls(services: services, alias: alias, bundleId: prefix + ".free." + ProvisionApp.apollo.suffix)
        let read = await calls.trySnapshot(timeoutSec: 15)
        if let snapshot = read.snapshot { return .read(snapshot, takenAt: read.takenAt) }
        return .failed(code: read.error?.code ?? "SNAPSHOT_FAILED", takenAt: read.takenAt)
    }

    /// `apps` holds what was read per alias; a missing key means the device was not asked.
    public static func panel(_ local: Local, probe: DeviceProbe, apps: [String: DeviceAppsProbe] = [:]) -> MenuPanel {
        switch local {
        case .firstRun(let issue): return MenuPanel.firstRun(issue)
        case .failed(let issue): return MenuPanel.failed(issue)
        case .ready(var inputs):
            inputs.probe = probe
            inputs.deviceApps = apps
            return .loaded(MenuSnapshotBuilder.build(inputs))
        }
    }
}

/// What one `devicectl device info apps` read of a saved device came to. The snapshot stays in memory (the app IDs on the
/// device are never printed, logged or kept in the panel's values).
public enum DeviceAppsProbe: Sendable, Equatable {
    /// The read is running.
    case checking
    /// `takenAt` is the clock before the call started (the evidence rule of `SlotRule` compares it with an op's window).
    case read(AppSnapshot, takenAt: Date)
    /// Only the error code is kept (`DEVICE_LOCKED`, `TIMEOUT`, ...), at the time of the attempt.
    case failed(code: String, takenAt: Date)

    /// When the read was attempted; nil while it runs.
    public var takenAt: Date? {
        switch self {
        case .checking: nil
        case .read(_, let at), .failed(_, let at): at
        }
    }
}

/// Which saved devices the panel reads and when (design section 12): at launch, on "Check status now", and on a panel open
/// only when the last attempt is older than `maxAge`. A failed attempt counts as an attempt, so a locked device is not
/// retried at every open. Plain values; the view model owns one.
public struct MenuAppsCache: Sendable, Equatable {
    public static let maxAge: TimeInterval = 300

    public private(set) var entries: [String: DeviceAppsProbe] = [:]

    public init() {}

    public func needsRead(_ alias: String, force: Bool, now: Date) -> Bool {
        if force { return true }
        guard let taken = entries[alias]?.takenAt else { return true }
        // A clock that moved back counts as stale.
        return now.timeIntervalSince(taken) >= Self.maxAge || taken > now
    }

    public mutating func set(_ alias: String, _ probe: DeviceAppsProbe) { entries[alias] = probe }

    /// Devices that are no longer visible are forgotten: their next appearance is read afresh.
    public mutating func retain(_ aliases: [String]) {
        entries = entries.filter { aliases.contains($0.key) }
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
