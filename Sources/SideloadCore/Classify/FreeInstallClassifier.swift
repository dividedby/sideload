import Foundation

/// A failed free-team `devicectl` call (install, uninstall or `device info apps`), with the words the owner needs.
public struct FreeInstallFailure: Sendable, Equatable {
    public let code: String
    public let reason: String
    public let fix: String
    /// A raw `0x…` device code, kept because it carries no identifiers.
    public let deviceCode: String?
}

/// Maps a free-team `devicectl` result to a stable code (design section 18) on top of `InstallClassifier`, which does
/// the text matching (`FREE_APP_LIMIT`, `DEVICE_LOCKED`, `UNTRUSTED_DEVELOPER`, `DEVICE_NOT_PAIRED`, `TIMEOUT`, ...).
/// Pure: no I/O, and nothing from the tool's output is echoed except a raw `0x` code.
public enum FreeInstallClassifier {
    public enum Operation: Sendable, Equatable {
        case install, uninstall, snapshot

        var failedCode: String {
            switch self {
            case .install: "INSTALL_FAILED"
            case .uninstall: "UNINSTALL_FAILED"
            case .snapshot: "SNAPSHOT_FAILED"
            }
        }
    }

    /// Fix texts shared with the canary's table.
    static let pairFix = "Pair the device with this Mac in Xcode › Window › Devices and Simulators (owner action; agents never pair), then retry."
    static let trustFix = "On the device: Settings › General › VPN & Device Management › tap the developer under Developer App and trust it, then retry."

    /// Nil when the call worked. For an install that means devicectl exited 0 and reported the bundle ID installed;
    /// an exit 0 that did not name it is `INSTALL_UNCONFIRMED`, which a caller may settle with a snapshot.
    public static func failure(
        _ operation: Operation, exitCode: Int32?, json: JSONValue?, stderr: String, timedOut: Bool, overflow: Bool,
        spawnError: String? = nil, bundleId: String
    ) -> FreeInstallFailure? {
        if spawnError != nil {
            return FreeInstallFailure(
                code: "TOOL_FAILED", reason: "xcrun devicectl could not be started.",
                fix: "Check that Xcode is installed (`xcrun devicectl --version`).", deviceCode: nil)
        }
        let verdict = InstallClassifier.classify(
            .init(
                exitCode: exitCode, json: json, stderr: stderr, timedOut: timedOut, overflow: overflow,
                guardPassed: true, bundleId: bundleId, freeTeam: true))
        let succeeded: Bool
        switch operation {
        case .install: succeeded = verdict.code == "INSTALLED"
        case .uninstall, .snapshot: succeeded = exitCode == 0 && !timedOut && !overflow && !reportedFailed(json)
        }
        if succeeded { return nil }

        switch verdict.code {
        case "FREE_APP_LIMIT":
            return FreeInstallFailure(
                code: "FREE_APP_LIMIT", reason: verdict.reason,
                fix: "The owner frees a slot with `sideload app remove`, or corrects `device slots --reserved` if it is too high.",
                deviceCode: nil)
        case "DEVICE_LOCKED":
            return FreeInstallFailure(
                code: "DEVICE_LOCKED", reason: verdict.reason, fix: "Unlock the device and retry.", deviceCode: nil)
        case "DEVICE_NOT_CONNECTED":
            return FreeInstallFailure(
                code: "DEVICE_NOT_CONNECTED", reason: verdict.reason,
                fix: "Wake the device and connect it by USB or put it on the same Wi-Fi, then retry.", deviceCode: nil)
        case "DEVICE_NOT_PAIRED":
            return FreeInstallFailure(
                code: "DEVICE_NOT_PAIRED", reason: verdict.reason,
                fix: pairFix, deviceCode: nil)
        case "UNTRUSTED_DEVELOPER":
            return FreeInstallFailure(
                code: "UNTRUSTED_DEVELOPER", reason: verdict.reason,
                fix: trustFix, deviceCode: nil)
        case "TIMEOUT":
            return FreeInstallFailure(
                code: "TIMEOUT", reason: verdict.reason,
                fix: operation == .install
                    ? "The install may have landed. Keep the device awake and nearby and run install again (a reinstall is slot-neutral)."
                    : "Keep the device awake and nearby and retry.",
                deviceCode: nil)
        case "DISK_FULL":
            return FreeInstallFailure(
                code: "DISK_FULL", reason: verdict.reason, fix: "Free storage on the device and retry.", deviceCode: nil)
        case "OUTPUT_LIMIT":
            return FreeInstallFailure(
                code: "OUTPUT_LIMIT", reason: verdict.reason, fix: "Retry; if it repeats, run devicectl by hand.", deviceCode: nil)
        case "INSTALL_UNCONFIRMED":
            return FreeInstallFailure(
                code: "INSTALL_UNCONFIRMED", reason: "devicectl exited 0 but did not report the app as installed.",
                fix: "Run install again; a reinstall is slot-neutral.", deviceCode: nil)
        default:
            let raw = verdict.code.hasPrefix("0x") ? verdict.code : nil
            return FreeInstallFailure(
                code: operation.failedCode, reason: "devicectl reported a failure it could not classify.",
                fix: "Run the same command by hand with `xcrun devicectl` to see the reason, or retry.", deviceCode: raw)
        }
    }

    private static func reportedFailed(_ json: JSONValue?) -> Bool {
        guard case .object(let top)? = json, case .object(let info)? = top["info"], case .string(let outcome)? = info["outcome"]
        else { return false }
        return outcome == "failed"
    }
}
