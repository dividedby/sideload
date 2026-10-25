import Foundation

/// Free space on the `$SIDELOAD_HOME` volume. Fails below `minFreeGB` (default 2), warns below max(5, minFreeGB).
public struct DiskCheck: Check {
    public let id = "disk"

    public init() {}

    public func run(_ services: Services) async throws -> [CheckResult] {
        let config = try services.store.load()
        let failBelow = config.minFreeGB > 0 ? config.minFreeGB : 2
        let warnBelow = max(5, failBelow)
        let bytes = try services.fs.freeBytes(at: services.home.home)
        let freeGB = Double(bytes) / Double(1 << 30)
        let message = "\(Self.oneDecimal(freeGB)) GB free on the sideload volume."
        if freeGB < failBelow {
            return [
                CheckResult(
                    id: id, severity: .fail, message: message,
                    fix: "Free up space; at least \(Self.number(failBelow)) GB is required.")
            ]
        }
        if freeGB < warnBelow {
            return [
                CheckResult(
                    id: id, severity: .warn, message: message,
                    fix: "Free up space; builds need headroom (warning below \(Self.number(warnBelow)) GB).")
            ]
        }
        return [CheckResult(id: id, severity: .ok, message: message)]
    }

    /// JavaScript's `toFixed(1)`: the exact binary value, rounded half up. printf rounds exact ties to even
    /// (12.25 gives 12.2), JavaScript gives 12.3; only multiples of .25 can be exact ties.
    static func oneDecimal(_ value: Double) -> String {
        let quarters = value * 4
        let isTie = quarters == quarters.rounded() && Int(quarters) % 2 != 0
        return String(format: "%.1f", isTie ? value + 0.01 : value)
    }

    /// A number as JavaScript prints it in a template string: `2`, `2.5`.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
