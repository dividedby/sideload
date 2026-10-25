import Foundation

/// What `devicectl list devices` has told us so far.
public enum DeviceProbe: Sendable, Equatable {
    /// Not answered yet: cards say "checking…".
    case checking
    /// `devicectl` failed: visibility is unknown, which is never shown as offline.
    case failed
    case listed([ListedDevice])
}

/// Everything the snapshot is built from. Plain values: no file, process or clock is touched.
public struct MenuInputs: Sendable {
    public var now: Date
    /// The last canary run's status (nil when there is none).
    public var canaryStatus: String?
    public var config: Config
    public var ledger: Ledger
    public var probe: DeviceProbe
    public var notices: [MenuIssue]
    /// False when `ledger.json` could not be read: `ledger` is then empty and says nothing about the slots.
    public var ledgerReadable: Bool
    /// Whether `refresh` exists. False in v1: auto-renew state is then not shown at all (no per-row exception, no
    /// "renews when back" wording). When it ships, the app sets this true and the exception renders.
    public var autoRefreshAvailable: Bool
    /// A renewal is running / the last one failed. Nothing sets these in v1: `refresh` does not exist yet and the
    /// ledger records no refresh result.
    public var renewing: Bool
    public var renewFailed: Bool

    public init(
        now: Date, canaryStatus: String?, config: Config, ledger: Ledger, probe: DeviceProbe,
        notices: [MenuIssue] = [], ledgerReadable: Bool = true, autoRefreshAvailable: Bool = false, renewing: Bool = false,
        renewFailed: Bool = false
    ) {
        self.ledgerReadable = ledgerReadable
        self.renewing = renewing
        self.renewFailed = renewFailed
        self.autoRefreshAvailable = autoRefreshAvailable
        self.now = now
        self.canaryStatus = canaryStatus
        self.config = config
        self.ledger = ledger
        self.probe = probe
        self.notices = notices
    }
}

/// Pure: inputs in, `MenuSnapshot` out (design sections 12 and 18).
public enum MenuSnapshotBuilder {
    /// The free team allows 3 apps per device (design section 18).
    public static let slotLimit = 3

    public static let renewDisabledTooltip = "Renewal arrives with refresh"

    public static func build(_ inputs: MenuInputs) -> MenuSnapshot {
        let now = inputs.now
        let config = inputs.config
        let ledger = inputs.ledger

        let cards = config.devices.keys
            .sorted { lhs, rhs in
                let l = (config.devices[lhs]?.platform == "tvos" ? 1 : 0, lhs)
                let r = (config.devices[rhs]?.platform == "tvos" ? 1 : 0, rhs)
                return l < r
            }
            .compactMap { alias in config.devices[alias].map { card(alias: alias, saved: $0, inputs: inputs) } }

        // The paid-side state: paid certificate/profile expiry, plus one item per free install, through the same
        // worst-state rule `status` uses (expiry outranks `blocked`; an expired item is `critical`).
        var items = ExpiryItems.compute(ledger, now: now)
        var soonest: Date?
        for signed in ledger.freeSigned where config.devices[signed.device] != nil {
            let (days, level) = FreeInstallExpiry.assess(expires: expiry(of: signed, in: ledger), now: now)
            soonest = min(soonest ?? .distantFuture, expiry(of: signed, in: ledger))
            items.append(
                ExpiryItem(
                    kind: .profile, name: "\(signed.app) @ \(signed.device)", notAfter: expiry(of: signed, in: ledger),
                    daysLeft: days, level: level))
        }
        let state = StatusState.worst(canaryStatus: inputs.canaryStatus, items: items)
        let paid = PaidAccountState(canaryStatus: inputs.canaryStatus)
        // The ring follows the soonest free install; the paid state matters only when there is none.
        let icon = MenuIcon.make(
            soonest: soonest, now: now, paid: state, certChanged: ledger.freeSuspended != nil,
            renewing: inputs.renewing, renewFailed: inputs.renewFailed)

        return MenuSnapshot(
            generated: now, state: state, icon: icon,
            strip: MenuStrip(freeInUse: !ledger.freeSigned.isEmpty || !ledger.freeProfiles.isEmpty, paid: paid),
            devices: cards, showsApps: cards.contains { !$0.apps.isEmpty }, showsCertKitExport: paid != .blocked,
            checkingDevices: inputs.probe == .checking, notices: inputs.notices)
    }

    /// The expiry of what is on the device: the signed app's embedded profile. When `provision` has since stored a
    /// profile with the same UUID its record says the same; a different UUID is a newer profile that is not installed
    /// yet, so it does not move the date.
    static func expiry(of signed: LedgerFreeSigned, in ledger: Ledger) -> Date {
        let same = ledger.freeProfiles.first { $0.id == signed.id && $0.profileUuid == signed.profileUuid }
        return same?.expires ?? signed.profileExpires
    }

    private static func presence(of saved: SavedDevice, probe: DeviceProbe) -> MenuPresence {
        switch probe {
        case .checking: return .checking
        case .failed: return .unknown
        case .listed(let devices):
            let listed = DeviceList.findSaved(devices, matching: saved)
            if DeviceList.visibilityOf(listed) == .ok, let listed { return .visible(listed.transport) }
            return .offline(lastSeen: listed?.lastConnection)
        }
    }

    private static func card(alias: String, saved: SavedDevice, inputs: MenuInputs) -> MenuDeviceCard {
        let now = inputs.now
        let presence = presence(of: saved, probe: inputs.probe)
        var offline = false
        if case .offline = presence { offline = true }

        let signed = inputs.ledger.freeSigned.filter { $0.device == alias }.sorted { ($0.app, $0.id) < ($1.app, $1.id) }
        let apps = signed.map { entry -> MenuAppRow in
            let expires = expiry(of: entry, in: inputs.ledger)
            let (days, level) = FreeInstallExpiry.assess(expires: expires, now: now)
            return MenuAppRow(
                id: entry.id, name: MenuFormat.appName(entry.app), daysLeft: days, level: level,
                daysLabel: FreeInstallExpiry.label(expires: expires, now: now),
                barFraction: FreeInstallExpiry.barFraction(expires: expires, now: now),
                barTone: FreeInstallExpiry.barTone(level), textTone: FreeInstallExpiry.textTone(level),
                // Auto-renew shows only as an exception, and only once refresh exists. An offline device says
                // its state once on the card, never per row.
                exception: inputs.autoRefreshAvailable && !offline && !saved.autoRefresh ? "Auto-renew off" : nil)
        }

        // An out-of-range stored reserve (a hand-edited config) says nothing about the slots, like an unreadable ledger.
        let known = inputs.ledgerReadable && saved.freeSlotsReserved != nil
        let reserved = saved.freeSlotsReserved ?? 0
        // `freeSigned` lists what was signed for the device; the slot records list what is used, whatever its state, so a
        // pending or lent slot is never shown free (docs/design.md section 18). An app in both is counted once; one in either
        // is counted, so the number is never more optimistic than the stricter source.
        let view = SlotRule.view(inputs.ledger, alias: alias, now: now)
        let usedApps = Set(signed.map(\.app)).union(view.apps).union(view.app.map { [$0] } ?? [])
        // Unknown slots: none is shown free.
        let free = known ? max(0, MenuSnapshotBuilder.slotLimit - usedApps.count - reserved) : 0
        let reservedRows = (0..<reserved).map { n in reserved == 1 ? "Reserved slot" : "Reserved slot (\(n + 1))" }

        var note: String?
        if case .offline(let lastSeen) = presence {
            let seen = lastSeen.map { "Seen " + MenuFormat.ago(from: $0, now: now) } ?? "Offline"
            if !inputs.autoRefreshAvailable {
                // The card header already says "offline"; the state is shown once. Never seen: no line at all.
                note = lastSeen == nil ? nil : seen
            } else {
                note = seen + " · " + (saved.autoRefresh ? "renews when back on Wi-Fi or USB" : "auto-renew off")
            }
        }

        var menuItems = [MenuRenewMenu.Item(title: "All apps", detail: "\(apps.count)", due: false)]
        menuItems += apps.map { MenuRenewMenu.Item(title: $0.name, detail: nil, due: $0.level != .ok) }

        return MenuDeviceCard(
            alias: alias, presence: presence, connectionLabel: MenuFormat.connection(presence), freeSlots: free,
            slotsLabel: known ? MenuFormat.slots(free) : "slots unknown", offlineNote: note, apps: apps, reservedSlots: reservedRows,
            renew: MenuRenewMenu(enabled: false, tooltip: renewDisabledTooltip, items: menuItems))
    }
}
