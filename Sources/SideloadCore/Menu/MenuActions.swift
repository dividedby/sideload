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
    /// Add app, stage 1: `fetch` downloads and checks an approved source's latest release. Nothing is signed or installed.
    case addFetch(device: String, app: String)
    /// Add app, stage 2: approve exactly `fetched`, then provision, sign and install it.
    case addApprove(device: String, app: String, fetched: MenuFetched)

    /// Add app's fetch downloads and checks a file; it changes neither the device nor the ledger, so the model neither
    /// cancels a load for it nor reads the device again when it ends.
    public var isFetchStage: Bool {
        if case .addFetch = self { return true }
        return false
    }

    public var device: String {
        switch self {
        case .renew(let device, _), .install(let device, _), .remove(let device, _), .lendable(let device, _),
            .addFetch(let device, _), .addApprove(let device, _, _):
            device
        }
    }
}

/// What stage 1 of Add app fetched and checked: the facts the second confirm shows, and the exact version and file the owner
/// approves. The runner approves nothing whose manifest entry has a different SHA-256.
public struct MenuFetched: Sendable, Hashable {
    public var version: String
    public var build: String?
    /// The full SHA-256 of the file.
    public var sha256: String
    public var size: Int64
    /// The stricter of the source's declared minimum OS and the one the binary says; nil when neither is known.
    public var minOS: String?
    /// Extensions `sign` will strip.
    public var extensionCount: Int
    /// The version was approved before this fetch.
    public var alreadyApproved: Bool
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
    /// Indexes into `lines` drawn monospaced and selectable (a SHA-256 to compare by eye).
    public var monospacedLines: Set<Int> = []
}

public enum MenuOfferKind: Sendable, Equatable {
    case retry, install, installUpdate, remove
}

/// One button a row offers.
public struct MenuOffer: Sendable, Equatable {
    public var kind: MenuOfferKind
    public var action: MenuAction
    public var label: String
    public var availability: MenuAvailability
    public var destructive: Bool
}

public enum MenuActions {
    /// Renew takes an app only when this many days or fewer are left (`RefreshPolicy.maxWithin`).
    static let renewWindowDays = RefreshPolicy.maxWithin

    /// Reasons more than one rule gives, and the view model's.
    public static let checkingApps = "Checking apps…"
    public static let couldntCheckApps = "Couldn't check apps"
    public static let controlsBusy = "Another action is in progress"
    static let ledgerUnreadable = "Can't read the ledger"
    static func lentOrChanging(_ alias: String) -> String { "An app is lent or changing on \(alias)" }

    /// Install, Remove, Renew and both Add app stages stop for the owner's Cancel; saving the lendable setting is instant.
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
            return renew(app, card: card)
        case .install(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return install(app, card: card, now: now)
        case .remove(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return remove(app, card: card)
        case .addFetch(_, let app):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            return add(app, card: card, snapshot: snapshot)
        case .addApprove(_, let app, let fetched):
            if let stop = freeStop(card: card, snapshot: snapshot) { return stop }
            if let stop = add(app, card: card, snapshot: snapshot).reason { return .disabled(stop) }
            return minimumOS(app, fetched: fetched, card: card)
        }
    }

    /// The rules every free action shares, first match wins.
    private static func freeStop(card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuAvailability? {
        if snapshot.suspended { return .disabled("Free certificate changed") }
        if !snapshot.ledgerReadable { return .disabled(ledgerUnreadable) }
        if card.hasPending { return .disabled("Change in progress on \(card.alias)") }
        return nil
    }

    /// A visible device with a successful live read, which Renew and Install and Remove need.
    private static func deviceStop(card: MenuDeviceCard) -> MenuAvailability? {
        switch card.presence {
        case .offline: return .disabled("Connect \(card.alias) over Wi-Fi or USB")
        case .checking: return .disabled(checkingApps)
        case .unknown: return .disabled(couldntCheckApps)
        case .visible: break
        }
        switch card.liveRead {
        case .read: return nil
        case .failed: return .disabled(couldntCheckApps)
        case .checking, .none: return .disabled(checkingApps)
        }
    }

    private static func why(_ presence: AppPresence) -> String {
        switch presence {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .lent: "Lent to lab"
        case .pending: "Change in progress"
        case .unconfirmed: "Not confirmed on the device"
        case .checking: checkingApps
        }
    }

    /// One app is available when `refresh` would select it (it is in `card.refreshSet`) and it is reachable. "All apps" runs
    /// the available apps of that set, one `refresh --app` each, so it is enabled when at least one is; when none is, it
    /// shows the first blocked app's reason.
    private static func renew(_ app: String?, card: MenuDeviceCard) -> MenuAvailability {
        guard let app else {
            guard !card.refreshSet.isEmpty else {
                return .disabled(card.renew.items.contains { $0.app != nil } ? notDue : "No apps to renew")
            }
            let each = card.refreshSet.map { renew($0.app, card: card) }
            return each.contains(.enabled) ? .enabled : each[0]
        }
        let member = card.refreshSet.first { $0.app == app }
        let row = card.row(for: app)
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

    /// What "All apps" runs and what it leaves out (with why), in `refresh`'s order.
    private static func renewPlan(_ card: MenuDeviceCard) -> (included: [MenuRefreshTarget], excluded: [(app: String, reason: String)]) {
        var included: [MenuRefreshTarget] = []
        var excluded: [(app: String, reason: String)] = []
        for member in card.refreshSet {
            if let reason = renew(member.app, card: card).reason {
                excluded.append((member.app, reason))
            } else {
                included.append(member)
            }
        }
        return (included, excluded)
    }

    static let notDue = "renewable at \(renewWindowDays) d left"

    private static func install(_ app: String, card: MenuDeviceCard, now: Date) -> MenuAvailability {
        guard let row = card.row(for: app) else { return .disabled("Not on \(card.alias)") }
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
        guard let signed = row.signedExpires else {
            // The text `install` gives for NOT_SIGNED.
            let sign = ProvisionApp(rawValue: app)?.signStep(device: card.alias) ?? "`sideload sign`"
            return .disabled("Not signed yet: the owner runs \(sign) first")
        }
        guard signed > now else {
            let steps = ProvisionApp.resignSteps(app: app, device: card.alias)
            return .disabled("The signed build has expired: run \(steps) in a terminal")
        }
        return .enabled
    }

    private static func remove(_ app: String, card: MenuDeviceCard) -> MenuAvailability {
        guard let row = card.row(for: app) else { return .disabled("Not on \(card.alias)") }
        if row.presence == .lent { return .disabled(why(.lent)) }
        if let stop = deviceStop(card: card) { return stop }
        return row.presence == .installed ? .enabled : .disabled(why(row.presence))
    }

    /// Add app, first match wins: an approved source, the platform, no row yet, a readable device, a free slot, an App ID.
    private static func add(_ app: String, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuAvailability {
        guard let source = snapshot.addSources.first(where: { $0.app == app }) else { return .disabled("Not an approved source") }
        guard let platform = card.platform else { return .disabled("\(card.alias) has no recorded platform") }
        guard source.platform == platform else { return .disabled("\(source.name) does not run on \(card.alias)") }
        if let row = card.row(for: app) {
            switch row.presence {
            case .installed: return .disabled("Already installed")
            case .notInstalled: return .disabled("Signed · not installed: use Install")
            case .lent: return .disabled(why(.lent))
            case .pending: return .disabled(why(.pending))
            case .unconfirmed: return .disabled("Already recorded on \(card.alias)")
            case .checking: return .disabled(checkingApps)
            }
        }
        if let stop = deviceStop(card: card) { return stop }
        guard card.slotsKnown else { return .disabled("Slots unknown") }
        guard card.freeSlots > 0 else { return .disabled("No free slot: remove an app first") }
        guard let option = card.addable.first(where: { $0.app == app }) else { return .disabled("Bundle ID prefix is not set") }
        // A reused App ID costs none, so only a new one is gated on the budget.
        guard option.newAppId else { return .enabled }
        guard let ids = snapshot.appIds else { return .disabled("App ID budget unknown") }
        if !option.appIdAllowed {
            return .disabled("App ID limit: \(ids.recent) of \(FreeAppIdBudget.limit) used in 7 days, \(ids.reserved) reserved")
        }
        return .enabled
    }

    /// `sign` refuses a build the device's OS is too old for, after `provision` has spent the App ID: the confirm says so first.
    private static func minimumOS(_ app: String, fetched: MenuFetched, card: MenuDeviceCard) -> MenuAvailability {
        guard let need = fetched.minOS, let have = card.osVersion, OSVersion.isAtLeast(have, need) == false else { return .enabled }
        return .disabled("\(MenuFormat.appName(app)) \(fetched.version) needs \(osName(card)) \(need) or later; \(card.alias) runs \(have)")
    }

    private static func osName(_ card: MenuDeviceCard) -> String { card.platform == "tvos" ? "tvOS" : "iOS" }

    /// The lab's borrowing is a setting; it changes nothing on the device. It stays put while an app is lent or changing,
    /// because the lab repeats `slot lend` and a different `lendableApp` mid-lend would fail it with ALREADY_LENT.
    private static func lendable(_ app: String?, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuAvailability {
        // Without the ledger the rows cannot say whether an app is lent.
        if !snapshot.ledgerReadable { return .disabled(ledgerUnreadable) }
        if card.apps.contains(where: { $0.presence == .lent || $0.presence == .pending }) {
            return .disabled(lentOrChanging(card.alias))
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
        func offer(_ kind: MenuOfferKind, _ action: MenuAction, _ label: String, destructive: Bool = false) {
            offers.append(
                MenuOffer(
                    kind: kind, action: action, label: label, availability: availability(action, in: snapshot, now: now),
                    destructive: destructive))
        }
        if row.failure != nil { offer(.retry, .renew(device: card.alias, app: row.app), "Retry") }
        if row.presence == .notInstalled { offer(.install, .install(device: card.alias, app: row.app), "Install") }
        if row.presence == .installed, row.newerSigned {
            offer(.installUpdate, .install(device: card.alias, app: row.app), "Install update")
        }
        if row.presence != .notInstalled {
            offer(.remove, .remove(device: card.alias, app: row.app), "Remove", destructive: true)
        }
        return offers
    }

    // MARK: confirm

    /// The confirm for an available action; nil when it is not available (or the card is gone).
    public static func prompt(for action: MenuAction, in snapshot: MenuSnapshot, now: Date) -> MenuPrompt? {
        guard availability(action, in: snapshot, now: now).isEnabled,
            let card = snapshot.devices.first(where: { $0.alias == action.device })
        else { return nil }
        switch action {
        case .renew(_, let app): return renewPrompt(app, card: card, snapshot: snapshot)
        case .install(_, let app): return installPrompt(app, card: card)
        case .remove(_, let app): return removePrompt(app, card: card)
        case .lendable(_, let app): return lendablePrompt(app, card: card)
        case .addFetch(_, let app): return addFetchPrompt(app, card: card, snapshot: snapshot)
        case .addApprove(_, let app, let fetched): return addApprovePrompt(app, fetched: fetched, card: card, snapshot: snapshot)
        }
    }

    /// What the click on the confirm button does, decided from the confirm the owner saw and the panel as it is now.
    public enum Reconfirm: Sendable, Equatable {
        /// The same confirm: run it.
        case run(MenuPrompt)
        /// The confirm changed while it was open (any line, or the list of apps): show the new one, run nothing.
        case show(MenuPrompt)
        /// No longer available: show why, run nothing.
        case blocked(String)
    }

    public static func reconfirm(_ action: MenuAction, shown: MenuPrompt, in snapshot: MenuSnapshot, now: Date) -> Reconfirm {
        guard let current = prompt(for: action, in: snapshot, now: now) else {
            return .blocked(availability(action, in: snapshot, now: now).reason ?? "It is no longer available.")
        }
        return current == shown ? .run(current) : .show(current)
    }

    private static let keychain = "macOS may ask for keychain access"

    private static func slotArithmetic(_ card: MenuDeviceCard, delta: Int) -> String? {
        guard card.slotsKnown else { return nil }
        let used = MenuSnapshotBuilder.slotLimit - card.freeSlots
        return "\(used)/\(MenuSnapshotBuilder.slotLimit) → \(used + delta)/\(MenuSnapshotBuilder.slotLimit)"
    }

    private static func renewPrompt(_ app: String?, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuPrompt {
        let alias = card.alias
        let plan = renewPlan(card)
        let qualifying = app.map { [$0] } ?? plan.included.map(\.app)
        let lent = Set(card.refreshSet.filter(\.lent).map(\.app)).union(card.apps.filter { $0.presence == .lent }.map(\.app))
        var lines: [String] = []
        if app == nil {
            lines.append("Re-signs and reinstalls on \(alias):")
            for key in qualifying {
                let name = MenuFormat.appName(key)
                lines.append(lent.contains(key) ? "\(name): re-signed only, not installed (lent to the lab)" : name)
            }
            for (key, reason) in plan.excluded { lines.append("Not included: \(MenuFormat.appName(key)) (\(reason))") }
        } else if let key = qualifying.first {
            let name = MenuFormat.appName(key)
            lines.append(
                lent.contains(key)
                    ? "Re-signs \(name) for \(alias): re-signed only, not installed (lent to the lab)"
                    : "Re-signs and reinstalls \(name) on \(alias)")
            if card.row(for: key)?.recorded == false { lines.append("Installed by hand: this records the install") }
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
        let update = card.row(for: app)?.presence == .installed
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
        if card.row(for: app)?.removalClearsTrust == true {
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

    private static func addFetchPrompt(_ app: String, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuPrompt {
        let alias = card.alias
        let name = MenuFormat.appName(app)
        let source = snapshot.addSources.first { $0.app == app }?.source ?? "its source"
        return MenuPrompt(
            title: "Fetch \(name) for \(alias)",
            lines: [
                "Downloads the latest \(name) release from \(source) and checks it",
                "Nothing is signed or installed; \(alias) and the portal are unchanged",
            ], confirmLabel: "Fetch", destructive: false, runningLabel: "Fetching \(name)…", apps: [])
    }

    private static func addApprovePrompt(_ app: String, fetched: MenuFetched, card: MenuDeviceCard, snapshot: MenuSnapshot) -> MenuPrompt {
        let alias = card.alias
        let name = MenuFormat.appName(app)
        let thirdParty = snapshot.addSources.first { $0.app == app }?.thirdParty == true
        var facts = "\(name) \(fetched.version)"
        if let build = fetched.build { facts += " (build \(build))" }
        facts += " · " + MenuFormat.size(fetched.size)
        if let minOS = fetched.minOS { facts += " · \(osName(card)) \(minOS) or later" }
        var lines = [facts, "SHA-256 \(fetched.sha256)"]
        let hashLine = lines.count - 1
        lines.append(
            thirdParty
                ? "Matches the index's; a third party, so this guards against corruption, not a bad index"
                : "Matches the publisher's")
        if fetched.extensionCount > 0 {
            lines.append("\(fetched.extensionCount) extension\(fetched.extensionCount == 1 ? "" : "s") will be removed")
        }
        lines.append("Approves this exact version for signing" + (fetched.alreadyApproved ? " (approved earlier)" : ""))
        let option = card.addable.first { $0.app == app }
        var portal: String
        if option?.newAppId == false {
            portal = "Portal: reuses the existing App ID, profile only"
        } else {
            portal = "Portal: creates one App ID and a 7-day profile"
            if let ids = snapshot.appIds {
                portal += " (\(ids.recent) of \(FreeAppIdBudget.limit) used in 7 days, \(ids.reserved) reserved)"
            }
        }
        lines.append(portal)
        if let slots = slotArithmetic(card, delta: 1) { lines.append("Slots \(slots)") }
        lines.append("Keep the device unlocked and connected")
        lines.append(keychain)
        return MenuPrompt(
            title: "Approve and install \(name) \(fetched.version) on \(alias)", lines: lines,
            confirmLabel: "Approve and install", destructive: false,
            runningLabel: "Adding \(name) \(fetched.version) to \(alias)…", apps: [], monospacedLines: [hashLine])
    }
}
