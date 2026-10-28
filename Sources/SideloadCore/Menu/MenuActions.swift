import Foundation

// The menu's mutating actions (design section 12): which are available, why not, and what the inline confirm says. The
// snapshot builder emits facts; the rules are here. Nothing runs from this file. Text never carries a device name, a
// UDID, a CoreDevice ID or an identity name: a device is its saved alias, an app is its display name.

public enum MenuAction: Hashable, Sendable {
    /// `app` nil is "All apps".
    case renew(device: String, app: String?)
    case install(device: String, app: String)
    case remove(device: String, app: String)
    /// `app` nil is none: the lab may not borrow a slot.
    case lendable(device: String, app: String?)

    public var device: String {
        switch self {
        case .renew(let device, _), .install(let device, _), .remove(let device, _), .lendable(let device, _): device
        }
    }
}

public enum MenuAvailability: Sendable, Equatable {
    case enabled
    /// The reason, drawn as the control's help text.
    case disabled(String)

    public var isEnabled: Bool { self == .enabled }

    public var reason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

/// The inline confirm: nothing runs until the owner clicks `confirmLabel` (that click is the owner's `--yes`).
public struct MenuPrompt: Sendable, Equatable {
    public var title: String
    public var lines: [String]
    public var confirmLabel: String
    public var destructive: Bool
    /// What the card says while the action runs ("Renewing Stremio on iphone…").
    public var runningLabel: String
    /// The apps a Renew runs, in order: the one app, or every app the confirm lists for "All apps". The run uses exactly
    /// this list, never what `refresh` would select by itself. Empty for the other actions.
    public var apps: [String]
}

/// One button a row offers.
public struct MenuOffer: Sendable, Equatable {
    public var action: MenuAction
    public var label: String
    public var availability: MenuAvailability
    public var destructive: Bool
}

public enum MenuActions {
    /// Renew takes an app only when this many days or fewer are left (`RefreshPolicy.maxWithin`).
    static let renewWindowDays = RefreshPolicy.maxWithin
    static let renewWindow = Double(RefreshPolicy.maxWithin) * FreeInstallExpiry.secondsPerDay

    /// Install, Remove and Renew stop for the owner's Cancel; saving the lendable setting is instant.
    public static func cancellable(_ action: MenuAction) -> Bool {
        if case .lendable = action { return false }
        return true
    }

    /// "Stremio", "Apollo": how the panel names an app key.
    public static func displayName(_ app: String) -> String { MenuFormat.appName(app) }

    // MARK: availability

    public static func availability(_ action: MenuAction, in snapshot: MenuSnapshot, now: Date) -> MenuAvailability {
        guard let card = snapshot.devices.first(where: { $0.alias == action.device }) else {
            return .disabled("Device not found")
        }
        switch action {
        case .lendable(_, let app): return lendable(app, card: card, snapshot: snapshot)
        case .renew(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return renew(app, card: card, now: now)
        case .install(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return install(app, card: card, now: now)
        case .remove(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return remove(app, card: card)
        }
    }

    /// The rules every free action shares, first match wins.
    private static func freeStop(card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuAvailability? {
        if snapshot.suspended { return .disabled("Free certificate changed") }
        if !snapshot.ledgerReadable { return .disabled("Can't read the ledger") }
        if card.hasPending { return .disabled("Change in progress on \(card.alias)") }
        return nil
    }

    /// A visible device with a successful live read, which Renew and Install and Remove need.
    private static func deviceStop(card: MenuDeviceCard) -> MenuAvailability? {
        switch card.presence {
        case .offline: return .disabled("Connect \(card.alias) over Wi-Fi or USB")
        case .checking: return .disabled("Checking apps…")
        case .unknown: return .disabled("Couldn't check apps")
        case .visible: break
        }
        switch card.liveRead {
        case .read: return nil
        case .failed: return .disabled("Couldn't check apps")
        case .checking, .none: return .disabled("Checking apps…")
        }
    }

    private static func why(_ presence: AppPresence) -> String {
        switch presence {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .lent: "Lent to lab"
        case .pending: "Change in progress"
        case .unconfirmed: "Not confirmed on the device"
        case .checking: "Checking apps…"
        }
    }

    /// "All apps" is `refresh --force` with no app, which touches `card.refreshSet`: every one of them must be available, or
    /// the confirm would promise less than the run does. One app is available when it is in that set and reachable.
    private static func renew(_ app: String?, card: MenuDeviceCard, now: Date) -> MenuAvailability {
        guard let app else {
            guard !card.refreshSet.isEmpty else {
                return .disabled(card.renew.items.contains { $0.app != nil } ? notDue : "No apps to renew")
            }
            for member in card.refreshSet {
                let each = renew(member.app, card: card, now: now)
                if !each.isEnabled { return each }
            }
            return .enabled
        }
        let member = card.refreshSet.first { $0.app == app }
        let row = card.apps.first { $0.app == app }
        if row?.presence == .lent {
            // A lent app is provisioned and signed without the device.
            guard row?.signedExpires != nil else { return .disabled("No signed build") }
            return member != nil ? .enabled : .disabled(notDue)
        }
        if row == nil, member == nil { return .disabled("Not on \(card.alias)") }
        if let stop = deviceStop(card: card) { return stop }
        guard let row else { return .disabled("Not on \(card.alias)") }
        guard row.presence == .installed else { return .disabled(why(row.presence)) }
        return member != nil ? .enabled : .disabled(notDue)
    }

    static let notDue = "renewable at \(renewWindowDays) d left"

    private static func install(_ app: String, card: MenuDeviceCard, now: Date) -> MenuAvailability {
        guard let row = card.apps.first(where: { $0.app == app }) else { return .disabled("Not on \(card.alias)") }
        if row.presence == .lent { return .disabled(why(.lent)) }
        if let stop = deviceStop(card: card) { return stop }
        switch row.presence {
        case .notInstalled:
            guard card.slotsKnown else { return .disabled("Slots unknown") }
            guard card.freeSlots > 0 else { return .disabled("No free slot: remove an app first") }
        case .installed:
            guard row.newerSigned else { return .disabled("Already installed") }
        default: return .disabled(why(row.presence))
        }
        guard let signed = row.signedExpires, signed > now else {
            let steps = ProvisionApp.resignSteps(app: app, device: card.alias)
            return .disabled("The signed build has expired: run \(steps) in a terminal")
        }
        return .enabled
    }

    private static func remove(_ app: String, card: MenuDeviceCard) -> MenuAvailability {
        guard let row = card.apps.first(where: { $0.app == app }) else { return .disabled("Not on \(card.alias)") }
        if row.presence == .lent { return .disabled(why(.lent)) }
        if let stop = deviceStop(card: card) { return stop }
        return row.presence == .installed ? .enabled : .disabled(why(row.presence))
    }

    /// The lab's borrowing is a setting; it changes nothing on the device. It stays put while an app is lent or changing,
    /// because the lab repeats `slot lend` and a different `lendableApp` mid-lend would fail it with ALREADY_LENT.
    private static func lendable(_ app: String?, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuAvailability {
        // Without the ledger the rows cannot say whether an app is lent.
        if !snapshot.ledgerReadable { return .disabled("Can't read the ledger") }
        if card.apps.contains(where: { $0.presence == .lent || $0.presence == .pending }) {
            return .disabled("An app is lent or changing on \(card.alias)")
        }
        if app == card.lendableApp { return .disabled("Already set") }
        if let app, !lendableChoices(card).contains(app) {
            return .disabled("\(MenuFormat.appName(app)) does not run on \(card.alias)")
        }
        return .enabled
    }

    /// The apps that run on the card's platform, in the order `device lendable` names them.
    public static func lendableChoices(_ card: MenuDeviceCard) -> [String] {
        ProvisionApp.allCases.filter { $0.devicePlatform == card.platform }.map(\.rawValue)
    }

    // MARK: row buttons

    /// Retry on a failed renewal, Install (or Install update) and Remove, each with its availability.
    public static func rowOffers(_ row: MenuAppRow, card: MenuDeviceCard, snapshot: MenuSnapshot, now: Date) -> [MenuOffer] {
        var offers: [MenuOffer] = []
        func offer(_ action: MenuAction, _ label: String, destructive: Bool = false) {
            offers.append(
                MenuOffer(
                    action: action, label: label, availability: availability(action, in: snapshot, now: now),
                    destructive: destructive))
        }
        if row.failure != nil { offer(.renew(device: card.alias, app: row.app), "Retry") }
        if row.presence == .notInstalled { offer(.install(device: card.alias, app: row.app), "Install") }
        if row.presence == .installed, row.newerSigned { offer(.install(device: card.alias, app: row.app), "Install update") }
        if row.presence != .notInstalled { offer(.remove(device: card.alias, app: row.app), "Remove", destructive: true) }
        return offers
    }

    // MARK: confirm

    /// The confirm for an available action; nil when it is not available (or the card is gone).
    public static func prompt(for action: MenuAction, in snapshot: MenuSnapshot, now: Date) -> MenuPrompt? {
        guard availability(action, in: snapshot, now: now).isEnabled,
            let card = snapshot.devices.first(where: { $0.alias == action.device })
        else { return nil }
        switch action {
        case .renew(_, let app): return renewPrompt(app, card: card, snapshot: snapshot, now: now)
        case .install(_, let app): return installPrompt(app, card: card)
        case .remove(_, let app): return removePrompt(app, card: card)
        case .lendable(_, let app): return lendablePrompt(app, card: card)
        }
    }

    private static let keychain = "macOS may ask for keychain access"

    private static func slotArithmetic(_ card: MenuDeviceCard, delta: Int) -> String? {
        guard card.slotsKnown else { return nil }
        let used = MenuSnapshotBuilder.slotLimit - card.freeSlots
        return "\(used)/\(MenuSnapshotBuilder.slotLimit) → \(used + delta)/\(MenuSnapshotBuilder.slotLimit)"
    }

    private static func renewPrompt(_ app: String?, card: MenuDeviceCard, snapshot: MenuSnapshot, now: Date) -> MenuPrompt {
        let alias = card.alias
        let qualifying = app.map { [$0] } ?? card.refreshSet.map(\.app)
        let lent = Set(card.refreshSet.filter(\.lent).map(\.app)).union(card.apps.filter { $0.presence == .lent }.map(\.app))
        var lines: [String] = []
        if app == nil {
            lines.append("Re-signs and reinstalls on \(alias):")
            for key in qualifying {
                let name = MenuFormat.appName(key)
                lines.append(lent.contains(key) ? "\(name): re-signed only, not installed (lent to the lab)" : name)
            }
        } else if let key = qualifying.first {
            let name = MenuFormat.appName(key)
            lines.append(
                lent.contains(key)
                    ? "Re-signs \(name) for \(alias): re-signed only, not installed (lent to the lab)"
                    : "Re-signs and reinstalls \(name) on \(alias)")
            if card.apps.first(where: { $0.app == key })?.recorded == false {
                lines.append("Installed by hand: this records the install")
            }
        }
        var portal = "Portal: profiles only, normally no new App ID"
        if let ids = snapshot.appIds {
            portal += " (\(ids.recent) of \(FreeAppIdBudget.limit) used in 7 days, \(ids.reserved) reserved)"
        }
        lines.append(portal)
        lines.append("Slots unchanged")
        if qualifying.contains(where: { !lent.contains($0) }) { lines.append("Keep the device unlocked and connected") }
        lines.append(keychain)
        let name = app.map(MenuFormat.appName)
        return MenuPrompt(
            title: name.map { "Renew \($0) on \(alias)" } ?? "Renew all apps on \(alias)", lines: lines,
            confirmLabel: app == nil ? "Renew all" : "Renew", destructive: false,
            runningLabel: name.map { "Renewing \($0) on \(alias)…" } ?? "Renewing all apps on \(alias)…",
            apps: qualifying)
    }

    private static func installPrompt(_ app: String, card: MenuDeviceCard) -> MenuPrompt {
        let alias = card.alias
        let name = MenuFormat.appName(app)
        let update = card.apps.first(where: { $0.app == app })?.presence == .installed
        var lines = [update ? "Installs the newer signed build of \(name) on \(alias)" : "Installs the signed build of \(name) on \(alias)"]
        if update {
            lines.append("Slots unchanged")
        } else if let slots = slotArithmetic(card, delta: 1) {
            lines.append("Slots \(slots)")
        }
        lines.append("Portal: no change")
        lines.append("Keep the device unlocked and connected")
        lines.append(keychain)
        return MenuPrompt(
            title: update ? "Install update of \(name) on \(alias)" : "Install \(name) on \(alias)", lines: lines,
            confirmLabel: update ? "Install update" : "Install", destructive: false,
            runningLabel: "Installing \(name) on \(alias)…", apps: [])
    }

    private static func removePrompt(_ app: String, card: MenuDeviceCard) -> MenuPrompt {
        let alias = card.alias
        let name = MenuFormat.appName(app)
        var lines = ["Deletes \(name) and its data from \(alias), frees a slot" + (slotArithmetic(card, delta: -1).map { " (\($0))" } ?? "")]
        if card.apps.first(where: { $0.app == app })?.removalClearsTrust == true {
            lines.append("Last free app: developer trust is cleared")
        }
        lines.append("Keep the device unlocked and connected")
        lines.append(keychain)
        return MenuPrompt(
            title: "Remove \(name) from \(alias)", lines: lines, confirmLabel: "Remove", destructive: true,
            runningLabel: "Removing \(name) from \(alias)…", apps: [])
    }

    private static func lendablePrompt(_ app: String?, card: MenuDeviceCard) -> MenuPrompt {
        let alias = card.alias
        guard let app else {
            return MenuPrompt(
                title: "Stop lending on \(alias)",
                lines: ["Setting only: the lab may not borrow a slot on \(alias)"], confirmLabel: "Stop lending",
                destructive: false, runningLabel: "Saving…", apps: [])
        }
        let name = MenuFormat.appName(app)
        return MenuPrompt(
            title: "Make \(name) lendable on \(alias)",
            lines: ["Setting only: the lab may uninstall \(name) and put it back"], confirmLabel: "Make lendable",
            destructive: false, runningLabel: "Saving…", apps: [])
    }
}
