import Foundation

/// Expiry maths for a free-team install (design section 18): a development profile lasts 7 days, so the levels are
/// `ok` above 3 days, `warn` at 3 days or less (`due`), `critical` at 1 day or less, then `expired`. The paid thresholds
/// (60 and 14) stay in `ExpiryItems`. Pure.
public enum FreeInstallExpiry {
    public static let windowDays = 7
    public static let warnDays = 3
    public static let criticalDays = 1

    public static let secondsPerDay: TimeInterval = 86_400
    static let window: TimeInterval = Double(windowDays) * secondsPerDay

    /// The level comes from the exact remaining time (`warn` up to and including 3 days, `critical` up to and including
    /// 1 day, `expired` at or past zero), so 3.9 days is still `ok`. `daysLeft` is the floored count the JSON reports;
    /// `label` rounds up.
    public static func assess(expires: Date, now: Date) -> (daysLeft: Int, level: ExpiryItem.Level) {
        let seconds = expires.timeIntervalSince(now)
        let days = Int((seconds / secondsPerDay).rounded(.down))
        if seconds <= 0 { return (days, .expired) }
        if seconds <= Double(criticalDays) * secondsPerDay { return (days, .critical) }
        if seconds <= Double(warnDays) * secondsPerDay { return (days, .warn) }
        return (days, .ok)
    }

    /// Time left over the 7-day window, clamped to 0...1 (a profile with more than 7 days left is full).
    public static func barFraction(expires: Date, now: Date) -> Double {
        min(max(expires.timeIntervalSince(now) / window, 0), 1)
    }

    /// The bar is green in the good zone and orange once due; expired is red (and empty).
    public static func barTone(_ level: ExpiryItem.Level) -> MenuTone {
        switch level {
        case .ok: .good
        case .warn, .critical: .due
        case .expired: .failed
        }
    }

    /// The days-left text stays plain until due.
    public static func textTone(_ level: ExpiryItem.Level) -> MenuTone {
        switch level {
        case .ok: .plain
        case .warn, .critical: .due
        case .expired: .failed
        }
    }

    /// "7 d", "3 d · due", "24 h · due" (a day or less) or "expired". Days and hours round up, so a fresh 7-day profile reads
    /// "7 d" and turns "6 d" exactly when it becomes renewable (`RefreshPolicy.maxWithin`). `assess`'s floored `daysLeft`
    /// stays what the JSON reports.
    public static func label(expires: Date, now: Date) -> String {
        let (_, level) = assess(expires: expires, now: now)
        if level == .expired { return "expired" }
        let due = level == .ok ? "" : " · due"
        let seconds = expires.timeIntervalSince(now)
        if seconds <= secondsPerDay {
            return (seconds < 3_600 ? "<1 h" : "\(Int((seconds / 3_600).rounded(.up))) h") + due
        }
        return "\(Int((seconds / secondsPerDay).rounded(.up))) d" + due
    }
}

enum MenuFormat {
    /// "just now", "12 min", "3 h", "4 d": the span since `date`, for "Seen … ago". A future date reads as "just now".
    static func ago(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 48 * 3_600 { return "\(Int(seconds / 3_600)) h ago" }
        return "\(Int(seconds / FreeInstallExpiry.secondsPerDay)) d ago"
    }

    /// "apollo" is Apollo; both Stremio builds are Stremio; anything else is capitalised.
    static func appName(_ app: String) -> String {
        if app.hasPrefix("stremio") { return "Stremio" }
        return capitalised(app)
    }

    static func capitalised(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// "45.2 MB": decimal units, one decimal.
    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1f MB", value / 1e6) }
        return String(format: "%.1f KB", value / 1e3)
    }

    static func slots(_ n: Int) -> String {
        switch n {
        case ...0: "no free slots"
        case 1: "1 free slot"
        default: "\(n) free slots"
        }
    }

    static func connection(_ presence: MenuPresence) -> String {
        switch presence {
        case .checking: "checking…"
        case .unknown: "status unknown"
        case .offline: "offline"
        case .visible(let transport):
            switch transport {
            case .network: "Wi-Fi"
            case .wired: "USB"
            case .unknown: "Visible"
            }
        }
    }
}
