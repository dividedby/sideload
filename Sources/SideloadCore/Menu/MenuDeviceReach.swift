import Foundation

/// What a saved device that is not reachable shows on its card: one line (what the list says, when it was last seen, what
/// the auto-renew setting means for it) and, for a state the owner can act on, one fix. Pure: it maps what
/// `devicectl list devices` already said and runs nothing.
///
/// The wording never says a device is broken. A paired Wi-Fi device can read `unavailable` until something opens a tunnel,
/// and a sleeping Apple TV can read it and still answer, so "unavailable" is "can't reach it right now", not a fault.
/// "Not paired" is the one firm state: it happens after an OS update, and only Xcode can pair again (nothing here pairs).
public struct MenuDeviceReach: Sendable, Equatable {
    /// "Can't reach it right now · Seen 3 h ago · renews when back on Wi-Fi or USB".
    public var line: String
    /// What to do about it ("Pair it in Xcode."); nil when there is nothing to do.
    public var fix: String?

    public static let notPaired = "No longer paired"
    public static let unreachable = "Can't reach it right now"
    public static let notSeen = "Not seen by this Mac"
    public static let pairFix = "Pair it in Xcode."
    public static let iosFix = "Unlock it, or connect it to the Mac or the same Wi-Fi."
    public static let tvAsleepFix = "It may just be asleep."
    public static let tvRenewsFix = "It may just be asleep; renewals will try again."

    /// The headline for a state; nil for a paired, reachable device.
    public static func headline(_ visibility: DeviceVisibility) -> String? {
        switch visibility {
        case .ok: nil
        case .unpaired: notPaired
        case .unavailable: unreachable
        case .absent: notSeen
        }
    }

    /// The fix for a state. An Apple TV is usually asleep, not away, so it is told to wait and (only when the card's
    /// renewal wording is on and auto-renew is) that renewals try again; anything else is the iOS wording.
    public static func fix(
        _ visibility: DeviceVisibility, platform: String?, autoRenew: Bool,
        autoRefreshAvailable: Bool
    ) -> String? {
        switch visibility {
        case .ok: return nil
        case .unpaired: return pairFix
        case .unavailable, .absent:
            guard platform == "tvos" else { return iosFix }
            return autoRenew && autoRefreshAvailable ? tvRenewsFix : tvAsleepFix
        }
    }

    /// The line and fix for a saved device in the list's answer; nil for a paired, reachable one. A failed list is not a
    /// state of the device: the caller passes no visibility for it and the card says "status unknown".
    ///
    /// With `autoRefreshAvailable` false there is no auto-renew wording at all. An Apple TV's renewal wording is in its
    /// fix, so its line does not repeat it.
    public static func of(
        _ visibility: DeviceVisibility, platform: String?, autoRenew: Bool,
        autoRefreshAvailable: Bool, lastSeen: Date?, now: Date
    ) -> MenuDeviceReach? {
        guard let headline = headline(visibility) else { return nil }
        var parts = [headline]
        if let lastSeen { parts.append("Seen " + MenuFormat.ago(from: lastSeen, now: now)) }
        if autoRefreshAvailable {
            switch (visibility, autoRenew, platform == "tvos") {
            case (_, false, _): parts.append("auto-renew off")
            case (.unpaired, true, _): parts.append("renews once paired again")
            case (_, true, false): parts.append("renews when back on Wi-Fi or USB")
            case (_, true, true): break
            }
        }
        return MenuDeviceReach(
            line: parts.joined(separator: " · "),
            fix: fix(
                visibility, platform: platform, autoRenew: autoRenew,
                autoRefreshAvailable: autoRefreshAvailable))
    }
}
