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
    ///   - renewing, renewFailed: nothing sets these in v1 (`refresh` does not exist yet).
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

    /// "6 days", "1 day", "5 hours", "under 1 hour": from the exact remaining time, floored like `daysLeft`.
    static func timeLeft(_ seconds: TimeInterval) -> String {
        let days = Int((seconds / FreeInstallExpiry.secondsPerDay).rounded(.down))
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(max(seconds, 0) / 3_600)
        if hours < 1 { return "under 1 hour" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
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

/// One installed app on a device's card.
public struct MenuAppRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var daysLeft: Int
    public var level: ExpiryItem.Level
    /// "6 d", "2 d · due", "5 h · due" or "expired".
    public var daysLabel: String
    /// Time left over the 7-day signing window, 0...1.
    public var barFraction: Double
    public var barTone: MenuTone
    public var textTone: MenuTone
    /// Only an exception shows under a row ("Auto-renew off"); nil otherwise.
    public var exception: String?
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

/// The "Renew…" menu. Disabled in v1: `refresh` is not built.
public struct MenuRenewMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var title: String
        /// The count for "All apps".
        public var detail: String?
        public var due: Bool
    }

    public var enabled: Bool
    public var tooltip: String?
    /// "All apps" first, then one item per app; reserved slots are never listed.
    public var items: [Item]
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
    public var apps: [MenuAppRow]
    /// Grey rows for slots the owner reserved for apps sideload does not manage.
    public var reservedSlots: [String]
    public var renew: MenuRenewMenu

    /// The status dot is filled when the device is visible, hollow otherwise.
    public var dotFilled: Bool { presence.isVisible }
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
    /// Unreadable sources (an invalid ledger or canary log); the rest of the panel still draws.
    public var notices: [MenuIssue]
}

/// The panel's states (design section 12). `running` does not exist in v1: every mutating action is disabled.
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
