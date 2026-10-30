import Foundation

/// The pure part of `status --notify` (design sections 11 and 18): which items stand at which threshold, which of them are
/// due a notification, and how `lastNotified` changes. No I/O here.
///
/// Thresholds are days left; 0 is expired. Paid certificates and profiles cross 60, 14 and 0; free installs cross 3, 1 and 0;
/// a pending app-data restore has the one threshold, 0. An item's current threshold is the smallest one it has reached.
/// It comes from the item's `level`, so it agrees with `status` to the second: a paid item is `warn` at 60 whole days or
/// fewer (61.9 days floors to 61, so no threshold yet), `critical` at 14 or fewer; an install is `warn` at 3 days or
/// fewer and `critical` at 1 day or fewer by exact remaining time (2.5 days is threshold 3, though its day count is 2);
/// both are `expired` once `notAfter` has passed. `ok` has no threshold.
enum StatusNotify {
    /// One item standing at a threshold.
    struct Current: Equatable {
        /// The `lastNotified` key: `install <app> @ <alias>`, `cert <fp8>`, `profile …<tail4>` or `restore <app> @ <alias>`.
        /// Never a device ID, a device name or an identity name.
        var key: String
        var threshold: Int
        /// The words in the notification.
        var text: String
        /// Worst first: soonest expiry first; restores, which have no date, last.
        var notAfter: Date?
    }

    /// The prefixes of the keys this feature writes. Every other key in `lastNotified` is someone else's.
    static let ownedPrefixes = ["install ", "cert ", "profile ", "restore "]

    static func owns(_ key: String) -> Bool { ownedPrefixes.contains { key.hasPrefix($0) } }

    static func threshold(of item: ExpiryItem) -> Int? {
        switch (item.kind, item.level) {
        case (_, .ok): nil
        case (_, .expired): 0
        case (.install, .critical): FreeInstallExpiry.criticalDays
        case (.install, .warn): FreeInstallExpiry.warnDays
        case (_, .critical): CertCheck.criticalDays
        case (_, .warn): CertCheck.warnDays
        }
    }

    /// Every item that stands at a threshold, worst first.
    static func current(items: [ExpiryItem], pending: [PendingRestores.Entry]) -> [Current] {
        var out: [Current] = []
        for item in items {
            guard let threshold = threshold(of: item) else { continue }
            // `item.name` is `cert <fp8>`, `profile …<tail4>` or `<app> @ <alias>`.
            let name = item.kind == .install ? printableName(item.name) : item.name
            let key = item.kind == .install ? "install " + name : name
            let text = threshold == 0 ? Notifier.expired(name) : Notifier.expiring(name, daysLeft: item.daysLeft)
            out.append(Current(key: key, threshold: threshold, text: text, notAfter: item.notAfter))
        }
        for entry in pending {
            let alias = printableAlias(entry.device)
            out.append(
                Current(
                    key: "restore \(entry.app) @ \(alias)", threshold: 0,
                    text: Notifier.restoreWaiting(app: entry.app, alias: alias), notAfter: nil))
        }
        return out.sorted { a, b in
            switch (a.notAfter, b.notAfter) {
            case (let x?, let y?): (x, a.key) < (y, b.key)
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.key < b.key
            }
        }
    }

    /// `<app> @ <alias>` with the alias made printable (an alias that is a device ID is cut to its last 4 characters).
    private static func printableName(_ name: String) -> String {
        guard let range = name.range(of: " @ ") else { return name }
        return name[..<range.upperBound] + printableAlias(String(name[range.upperBound...]))
    }

    /// The items to announce: no value stored, or a stored one above the current threshold.
    static func due(_ current: [Current], stored: [String: Int]) -> [Current] {
        current.filter { item in stored[item.key].map { item.threshold < $0 } ?? true }
    }

    /// Changes `lastNotified` in place; true when it changed. Run against the freshly read dictionary inside
    /// `ConfigStore.update`, so another writer's keys are kept:
    /// - each announced item is recorded at its threshold (never raised above a value already stored);
    /// - an item whose stored threshold is below its current one was renewed into a higher bracket: re-armed at the current
    ///   one without a notification, so the next crossing is announced;
    /// - with `prune` (the ledger and the config were both read), an owned key with no item at a threshold any more (renewed
    ///   above the top threshold, or gone) is removed. A key not owned by this feature is never touched.
    @discardableResult
    static func apply(
        to stored: inout [String: Int], announced: [Current], current: [Current], prune: Bool
    ) -> Bool {
        let before = stored
        for item in announced { stored[item.key] = min(stored[item.key] ?? .max, item.threshold) }
        for item in current {
            if let value = stored[item.key], value < item.threshold { stored[item.key] = item.threshold }
        }
        if prune {
            let live = Set(current.map(\.key))
            for key in stored.keys where owns(key) && !live.contains(key) { stored[key] = nil }
        }
        return stored != before
    }
}

extension StatusCommand {
    /// `status --notify`: the normal `status` envelope, then one notification for what crossed a threshold since the last
    /// run (`StatusNotify`). Reads without a lock like `status`; takes no `.op.lock`, touches no device, keychain, portal or
    /// network. The one subprocess is `osascript` through the runner. `lastNotified` is written (under the config lock, from a
    /// fresh read) only after the notification was delivered, so a failed delivery is tried again at the next run; stale keys
    /// are pruned either way. A notification or a config write that fails is a warning, never a failure.
    ///
    /// Adds `notified` (`[{item: <key>, threshold: N}]`, the items this run's notification covered and recorded) and
    /// `delivered` (true only when a notification was posted).
    public static func runNotify(_ services: Services) async -> Envelope {
        var snapshot = gather(services)
        var warnings = snapshot.warnings
        var announced: [StatusNotify.Current] = []
        var delivered = false

        func warn(_ code: String, _ message: String, _ fix: String) {
            warnings.append(["code": .string(code), "message": .string(message), "fix": .string(fix)])
        }

        if let config = snapshot.config {
            let current = StatusNotify.current(items: snapshot.items, pending: snapshot.pending)
            let due = StatusNotify.due(current, stored: config.lastNotified)
            if !due.isEmpty {
                let posted = await Notifier(runner: services.runner).notify(Notifier.combined(due.map(\.text)))
                if posted {
                    delivered = true
                    announced = due
                } else {
                    warn(
                        "NOTIFY_FAILED", "The notification could not be posted, so nothing was recorded as announced.",
                        "Allow notifications for the process that runs sideload (System Settings > Notifications, Script Editor) and run it in the logged-in GUI session; `sideload status` and the menu bar app show the same items.")
                }
            }
            let prune = snapshot.complete
            var preview = config.lastNotified
            if StatusNotify.apply(to: &preview, announced: announced, current: current, prune: prune) {
                do {
                    try await services.store.update { config in
                        StatusNotify.apply(
                            to: &config.lastNotified, announced: announced, current: current, prune: prune)
                    }
                } catch {
                    let why = (error as? SideloadError).map { " (\($0.code))" } ?? ""
                    warn(
                        "NOTIFY_STATE_NOT_SAVED",
                        "config.json could not be updated\(why), so the thresholds announced are not recorded and will be announced again at the next run.",
                        "Check that $SIDELOAD_HOME is writable and no other sideload command holds the config lock, then run `sideload status --notify` again.")
                }
            }
        } else {
            warn(
                "NOTIFY_SKIPPED", "config.json could not be read, so what was announced before is unknown and nothing was posted.",
                "Fix config.json (see the warning above), then run `sideload status --notify` again.")
        }

        snapshot.data["notified"] = .array(
            announced.map { ["item": .string($0.key), "threshold": .number(Double($0.threshold))] })
        snapshot.data["delivered"] = .bool(delivered)
        snapshot.data["warnings"] = .array(warnings)
        return .result(command, snapshot.data)
    }
}
