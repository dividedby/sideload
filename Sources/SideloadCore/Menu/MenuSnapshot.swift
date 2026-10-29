import Foundation

// The menu bar app's view of the world (design sections 12 and 18), built here so it is testable and UI-free:
// `SideloadMenu` only draws these values. Colours are semantic names (`MenuTone`); the app maps them to SwiftUI
// colours. Nothing in a snapshot is a UDID, a CoreDevice ID, a device name or an identity name: devices are
// shown by their saved alias.

/// How a value is coloured. Colour marks only what is due or failed.
public enum MenuTone: String, Sendable, Equatable {
    /// Default text colour.
    case plain
    /// The good zone (green bar).
    case good
    /// Due: 3 days or fewer left (orange).
    case due
    /// Expired or failed (red).
    case failed
    /// Secondary information (grey).
    case neutral
}

/// The menu bar icon (design section 12): the countdown ring. The ring is the time left of the soonest-expiring free
/// install over its 7-day window; the centre says what is wrong. `SideloadMenu` only draws these values.
public struct MenuIcon: Sendable, Equatable {
    /// Worst wins; the declaration order is the precedence, highest first.
    public enum State: String, Sendable, Equatable, CaseIterable {
        /// The free identity set changed (`freeSuspended`): a solid red ring and a red "!".
        case certChanged
        /// A free install is past its profile: a dashed red ring and a red cross.
        case expired
        /// 1 day or less: red ring and arrow.
        case critical
        /// A renewal failed: the ring at its value plus a red cross badge.
        case renewFailed
        /// 3 days or less: orange ring.
        case due
        /// A renewal is running: a blue arc and arrow.
        case renewing
        /// More than 3 days: monochrome.
        case ok
        /// No data at all: a dashed grey ring and a grey "?".
        case unknown
    }

    public var state: State
    /// The ring's remaining fraction, 0...1: the soonest free install's time left over 7 days, from the exact time
    /// (`FreeInstallExpiry.barFraction`). With no free install it is 1 for `ok`, `renewFailed` and `certChanged`, and
    /// 0 for `unknown`. The drawing ignores it for `certChanged`, `expired`, `renewing` and `unknown`.
    public var fraction: Double
    /// Time left on the soonest free install, for the accessibility text; nil with no free install.
    public var remaining: TimeInterval?

    /// Whether the assessed level is due (orange), which `renewFailed` and `renewing` would otherwise hide. Set only
    /// by `make`, from the assessed level; never inferred from `remaining`.
    public var ringIsDue: Bool

    public init(state: State, fraction: Double, remaining: TimeInterval? = nil, ringIsDue: Bool = false) {
        self.state = state
        self.fraction = min(max(fraction, 0), 1)
        self.remaining = remaining
        self.ringIsDue = ringIsDue
    }

    public static let unknown = MenuIcon(state: .unknown, fraction: 0)

    /// - Parameters:
    ///   - soonest: when the soonest-expiring free install (across every saved device) expires; nil with none.
    ///   - paid: the paid-side state, used only when there is no free install, always as a full ring: `ok` is ok,
    ///     `warn` is due, `critical` (which includes expired) is critical, anything else is unknown. The paid state
    ///     never drives the icon while free installs exist.
    ///   - certChanged: the ledger's `freeSuspended` is set.
    ///   - renewing: a Renew from the menu is running (`MenuLoader.panel(renewing:)`).
    ///   - renewFailed: an install's last refresh failed (the builder derives it from the rows).
    public static func make(
        soonest: Date?, now: Date, paid: StatusState, certChanged: Bool, renewing: Bool = false,
        renewFailed: Bool = false
    ) -> MenuIcon {
        var state: State
        var fraction = 0.0
        var remaining: TimeInterval?
        var due = false
        if let soonest {
            remaining = soonest.timeIntervalSince(now)
            fraction = FreeInstallExpiry.barFraction(expires: soonest, now: now)
            switch FreeInstallExpiry.assess(expires: soonest, now: now).level {
            case .expired: state = .expired
            case .critical: state = .critical
            case .warn: (state, due) = (.due, true)
            case .ok: state = .ok
            }
        } else {
            // No free install: the paid-side state, always a full ring (a paid window has no 7-day fraction).
            switch paid {
            case .ok: (state, fraction) = (.ok, 1)
            case .warn: (state, fraction, due) = (.due, 1, true)
            case .critical: (state, fraction) = (.critical, 1)
            case .blocked, .unknown: state = .unknown
            }
        }
        // cert changed > expired > critical > renew failed > due > renewing > ok > unknown.
        if certChanged {
            state = .certChanged
            if soonest == nil { fraction = 1 }
        } else if renewFailed, [.due, .renewing, .ok, .unknown].contains(state) {
            state = .renewFailed
            if soonest == nil { fraction = 1 }
        } else if renewing, [.ok, .unknown].contains(state) {
            state = .renewing
        }
        return MenuIcon(state: state, fraction: fraction, remaining: remaining, ringIsDue: due)
    }

    /// "sideload: 2 days left, due"; hours under a day.
    public var accessibilityLabel: String {
        let left = remaining.map(Self.timeLeft)
        switch state {
        case .certChanged: return "sideload: certificate changed, renewal suspended"
        case .expired: return "sideload: expired"
        case .critical: return left.map { "sideload: \($0) left, critical" } ?? "sideload: a paid item is expiring or expired"
        case .renewFailed: return "sideload: renewal failed" + (left.map { ", \($0) left" } ?? "")
        case .due: return left.map { "sideload: \($0) left, due" } ?? "sideload: a paid item is due"
        case .renewing: return "sideload: renewing" + (left.map { ", \($0) left" } ?? "")
        case .ok: return "sideload: " + (left.map { "\($0) left, " } ?? "") + "all good"
        case .unknown: return "sideload: status unknown"
        }
    }

    /// "7 days", "24 hours", "1 hour", "under 1 hour": from the exact remaining time, rounded up like the rows'
    /// `FreeInstallExpiry.label`.
    static func timeLeft(_ seconds: TimeInterval) -> String {
        switch FreeInstallExpiry.timeLeft(seconds) {
        case .days(let days): "\(days) days"
        case .hours(let hours): hours == 1 ? "1 hour" : "\(hours) hours"
        case .underAnHour: "under 1 hour"
        }
    }
}

/// A failure or notice with the output contract's three parts.
public struct MenuIssue: Sendable, Equatable {
    public var code: String
    public var message: String
    public var fix: String?

    public init(code: String, message: String, fix: String? = nil) {
        self.code = code
        self.message = Redactor.redactPatterns(message)
        self.fix = fix.map(Redactor.redactPatterns)
    }

    init(_ error: any Error) {
        if let e = error as? SideloadError {
            self.init(code: e.code, message: e.message, fix: e.fix)
        } else {
            self.init(
                code: "INTERNAL_ERROR", message: "sideload could not read its state.",
                fix: "Run `sideload status` in a terminal to see the cause.")
        }
    }
}

/// The paid team, from the last canary run.
public enum PaidAccountState: String, Sendable, Equatable {
    case blocked, working
    /// No canary run yet, or a run that proved nothing (`error`, `skipped`, a status this version does not know).
    case unknown

    public init(canaryStatus: String?) {
        switch canaryStatus {
        case "blocked": self = .blocked
        case "working": self = .working
        default: self = .unknown
        }
    }
}

/// The one line under the header: "Free account in use · Paid account blocked".
public struct MenuStrip: Sendable, Equatable {
    public var freeInUse: Bool
    public var paid: PaidAccountState

    public var freeText: String { freeInUse ? "Free account in use" : "Free account not in use" }

    public var paidText: String {
        switch paid {
        case .blocked: "Paid account blocked"
        case .working: "Paid account working"
        case .unknown: "Paid account not checked"
        }
    }

    public var line: String { freeText + " · " + paidText }
}

/// What the panel knows about one app on a device. A row is a countdown only for `installed` and `unconfirmed`.
public enum AppPresence: String, Sendable, Equatable {
    /// Seen on the device (the live app list, or a hand-installed app signed by sideload).
    case installed
    /// Signed and recorded, but the live app list does not show it: no countdown, out of the ring.
    case notInstalled
    /// Lent to the lab: the app is off the device and the slot is the lab's.
    case lent
    /// A device operation on the app is in flight (or ended unknown): it may or may not be there.
    case pending
    /// Not read from the device (it is offline, locked or not asked): the ledger's record is shown.
    case unconfirmed
    /// The device is being read right now.
    case checking

    /// What is, or may be, on the device: the rows that count in the ring, the Renew items and the failure line.
    public var isLive: Bool {
        switch self {
        case .installed, .unconfirmed, .checking, .pending: true
        case .notInstalled, .lent: false
        }
    }
}

/// One app on a device's card.
public struct MenuAppRow: Sendable, Equatable, Identifiable {
    public var id: String
    /// The app key the commands take ("stremio-ios").
    public var app: String
    public var name: String
    public var presence: AppPresence
    public var daysLeft: Int
    public var level: ExpiryItem.Level
    /// "6 d", "2 d · due", "5 h · due" or "expired" for a countdown; the state in words otherwise ("Signed · not
    /// installed", "Lent to lab", "Change in progress", "checking…").
    public var daysLabel: String
    /// Time left over the 7-day signing window, 0...1.
    public var barFraction: Double
    public var barTone: MenuTone
    public var textTone: MenuTone
    /// Only a countdown draws the bar.
    public var showsBar: Bool
    /// Only an exception shows under a row ("Auto-renew off"); nil otherwise.
    public var exception: String?
    /// "Renewal failed · REFRESH_X" from the install's last refresh result; drawn red under the row. nil otherwise.
    public var failure: String?
    /// The exact expiry behind the countdown (`installs[]`, or the signed app's profile for a hand-installed one); nil
    /// for a row without a countdown.
    public var expires: Date?
    /// There is an `installs[]` record (false: installed by hand).
    public var recorded: Bool
    /// The expiry of the signed build `sign` left for this app on this device (`freeSigned`); nil when none.
    public var signedExpires: Date?
    /// The signed build is a different, longer-lived profile than the installed one (more than a day later, not expired):
    /// installing it is an update. Always false without an `installs[]` record.
    public var newerSigned: Bool
    /// Removing the app takes the developer trust with it (`AppCommand`'s LAST_FREE_APP_REMOVED rule). Set only for an
    /// installed row on a live read.
    public var removalClearsTrust: Bool
}

/// How a saved device shows up right now.
public enum MenuPresence: Sendable, Equatable {
    /// `devicectl` has not answered yet.
    case checking
    /// `devicectl` failed, so nothing is known (never shown as offline).
    case unknown
    case visible(DeviceTransport)
    case offline(lastSeen: Date?)

    public var isVisible: Bool {
        if case .visible = self { return true }
        return false
    }
}

/// The "Renew…" menu's items: the rows with a countdown, and a lent app that has a signed build. Whether each is
/// available is `MenuActions.availability`.
public struct MenuRenewMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var title: String
        /// The count for "All apps", as "(2)"; nil when it would renew none.
        public var detail: String?
        public var due: Bool
        /// The app key; nil for "All apps".
        public var app: String?
    }

    /// "All apps" first, then one item per app; reserved slots are never listed.
    public var items: [Item]
}

/// One app a Renew of "All apps" would touch: what `refresh` itself selects for the device (`RefreshPolicy.decide`).
public struct MenuRefreshTarget: Sendable, Equatable {
    public var app: String
    /// The app is lent: provisioned and signed, not installed.
    public var lent: Bool
}

/// One app "Add app…" offers on a device: an approved source with no row on it.
public struct MenuAddOption: Sendable, Equatable, Hashable {
    public var app: String
    public var name: String
    /// Where the download comes from: "github.com", "dl.strem.io (third-party index)".
    public var source: String
    /// Adding it registers a new App ID (the bundle ID has no live epoch in the ledger).
    public var newAppId: Bool
    /// A new App ID fits the budget (`FreeAppIdBudget.evaluate`); always true when the App ID is reused.
    public var appIdAllowed: Bool
}

/// An approved, fetchable catalog app, whatever the device (`config.approvedSources` over `FetchCatalog`; never the filler).
public struct MenuAddSource: Sendable, Equatable {
    public var app: String
    public var name: String
    public var source: String
    /// The saved device `platform` it runs on.
    public var platform: String
    /// A third-party index, which vouches for the file less than the publisher does.
    public var thirdParty: Bool
}

/// What the device's own app list said, for the card's actions (they need a successful read).
public enum MenuLiveRead: Sendable, Equatable {
    /// Not asked, or the device is not visible.
    case none
    case checking
    /// Locked, timed out or unreadable.
    case failed
    case read
}

public struct MenuDeviceCard: Sendable, Equatable, Identifiable {
    public var alias: String
    public var id: String { alias }
    public var presence: MenuPresence
    /// "Wi-Fi", "USB", "offline", "checking…".
    public var connectionLabel: String
    public var freeSlots: Int
    /// "1 free slot", "2 free slots", "no free slots".
    public var slotsLabel: String
    /// The one line an offline device shows ("Seen 3 h ago · renews when back on Wi-Fi or USB"); nil otherwise.
    public var offlineNote: String?
    /// The one line a visible device shows when its app list could not be read ("Couldn't check apps (device locked) ·
    /// showing last known"); nil otherwise. "Not checked live" is said once per card, never per row.
    public var appsNote: String?
    public var apps: [MenuAppRow]
    /// Grey rows for slots the owner reserved for apps sideload does not manage.
    public var reservedSlots: [String]
    public var renew: MenuRenewMenu
    /// The saved device's `platform` ("ios", "tvos"); nil when not recorded.
    public var platform: String?
    /// `freeSlots` is a real count (the ledger is readable and the stored reserve is in range).
    public var slotsKnown: Bool
    /// The app the lab may borrow the slot of (`device lendable`); nil for none.
    public var lendableApp: String?
    /// Every app `refresh --force` would touch on this device, in its order (soonest expiry first), from the same facts and
    /// rules it uses. Includes an installed app with its signed copy fresh, which `refresh` reinstalls to record it, and an
    /// app that is due but cannot be reached right now: "All apps" lists exactly this set.
    public var refreshSet: [MenuRefreshTarget]
    /// An app on the card has a device operation in flight (or ended unknown).
    public var hasPending: Bool
    /// What the device's app list said, while the device is visible.
    public var liveRead: MenuLiveRead
    /// The apps "Add app…" lists: approved sources for this platform with no row on the card.
    public var addable: [MenuAddOption] = []
    /// The device's OS (`devicectl list devices`) while it is visible; nil when not known.
    public var osVersion: String?

    /// The row of one app, by its app key.
    public func row(for app: String) -> MenuAppRow? { apps.first { $0.app == app } }

    /// The status dot is filled when the device is visible, hollow otherwise.
    public var dotFilled: Bool { presence.isVisible }
}

/// The free team's App ID budget as the confirm text states it ("3 of 10 used in 7 days, 4 reserved").
public struct MenuAppIds: Sendable, Equatable {
    public var recent: Int
    public var reserved: Int
}

/// Everything the loaded panel draws.
public struct MenuSnapshot: Sendable, Equatable {
    public var generated: Date
    /// The worst of the canary and every expiry (the paid-side mapping; the menu bar icon is `icon`).
    public var state: StatusState
    /// The menu bar icon: the countdown ring of the soonest free install.
    public var icon: MenuIcon
    public var strip: MenuStrip
    public var devices: [MenuDeviceCard]
    /// The Apps section stays hidden until something is installed.
    public var showsApps: Bool
    /// The Feather cert kit Export is hidden while the paid account is blocked.
    public var showsCertKitExport: Bool
    /// True while `devicectl` has not answered.
    public var checkingDevices: Bool
    /// True while a visible device's app list is being read.
    public var checkingApps: Bool
    /// Unreadable sources (an invalid ledger or canary log); the rest of the panel still draws.
    public var notices: [MenuIssue]
    /// `ledger.json` could be read; the free actions are off while it cannot.
    public var ledgerReadable: Bool
    /// The free team's App ID count; nil when the ledger or the stored `freeTeam.reservedAppIds` cannot be read.
    public var appIds: MenuAppIds?
    /// The free identity set changed (`icon.state == .certChanged`): the free actions stop.
    public var suspended: Bool
    /// Every approved source "Add app…" could offer, on any platform.
    public var addSources: [MenuAddSource] = []
}

/// The panel's states (design section 12). An action's own states (confirm, running, result) are `MenuActionState`.
public enum MenuPanel: Sendable, Equatable {
    case loading
    case loaded(MenuSnapshot)
    case failed(MenuIssue)
    /// No `config.json` yet: carries the doctor's fix text.
    case firstRun(MenuIssue)

    /// The icon for this panel: unknown until something loaded.
    public var icon: MenuIcon {
        if case .loaded(let snapshot) = self { return snapshot.icon }
        return .unknown
    }
}
