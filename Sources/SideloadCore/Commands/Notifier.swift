import Foundation

/// A macOS notification through `osascript` (design section 18), run by the `Runner` like every subprocess. The text is
/// the script's argument (`on run argv`), never part of the script, so no character of it can be code; it is also cleaned
/// to the characters aliases, app names, numbers and codes are made of. A failure (no notification permission, a timeout,
/// no `osascript`) is only reported to the caller, which logs it: a notification never fails a run.
struct Notifier: Sendable {
    static let executable = "/usr/bin/osascript"
    static let timeout = Duration.seconds(10)
    static let title = "sideload"
    private static let maxLength = 160

    let runner: any Runner

    /// The characters a message may keep; anything else is dropped. A leading `-` would read as an `osascript` option.
    static func sanitised(_ text: String) -> String {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter(isAllowed)))
        return String(kept.drop { $0 == "-" || $0 == " " }.prefix(maxLength))
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true  // 0-9 A-Z a-z
        case 0x20, 0x40, 0x2C, 0x2E, 0x3A, 0x2D, 0x5F: true  // space @ , . : - _
        default: false
        }
    }

    /// The argument vector: the script lines, then the message.
    static func arguments(for message: String) -> [String] {
        [
            "-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"\(title)\"", "-e", "end run",
            sanitised(message),
        ]
    }

    /// True when `osascript` ran and exited 0. Nothing here throws.
    func notify(_ message: String) async -> Bool {
        guard !Self.sanitised(message).isEmpty else { return false }
        let result = await runner.run(
            CommandSpec(
                executable: Self.executable, args: Self.arguments(for: message), timeout: Self.timeout, maxOutputBytes: 4096))
        return result.code == 0 && !result.timedOut && result.spawnError == nil
    }

    // MARK: the texts

    /// "stremio-ios @ iphone refreshed, 7 d left".
    static func refreshed(app: String, alias: String, daysLeft: Int?) -> String {
        "\(app) @ \(alias) refreshed" + left(daysLeft)
    }

    /// "stremio-ios @ iphone failed DEVICE_LOCKED, next 14:30, 4 d left".
    static func failed(app: String, alias: String, code: String, next: String?, daysLeft: Int?) -> String {
        "\(app) @ \(alias) failed \(code)" + (next.map { ", next \($0)" } ?? "") + left(daysLeft)
    }

    /// An install that auto-refresh will not touch again until the owner renews it by hand.
    static func suspended(app: String, alias: String, code: String) -> String {
        "\(app) @ \(alias) suspended after \(code), renew it by hand"
    }

    private static func left(_ days: Int?) -> String { days.map { ", \(max($0, 0)) d left" } ?? "" }
}
