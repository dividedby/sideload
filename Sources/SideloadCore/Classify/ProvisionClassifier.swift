import Foundation

/// Pure classification of a failed `provision` `xcodebuild` run (design section 18). It reads the build output
/// for the failures the owner can act on; anything else is `PROVISION_FAILED`. The matched phrases are
/// Xcode's wording as far as it is known and are unverified until the first owner run (S2), so an unrecognised
/// message degrades to `PROVISION_FAILED` with a redacted tail, never to a wrong code.
public enum ProvisionClassifier {
    public struct Failure: Sendable, Equatable {
        public let code: String
        public let message: String
        public let fix: String
    }

    /// Nil when the build succeeded.
    public static func classify(_ input: BuildClassifier.Input, registerDevice: Bool) -> Failure? {
        if input.overflow {
            return Failure(
                code: "OUTPUT_LIMIT", message: "xcodebuild produced more output than the safety limit and was stopped.",
                fix: "Retry; if it repeats, run the command by hand to see what is flooding the output.")
        }
        if input.timedOut {
            return Failure(
                code: "BUILD_TIMEOUT", message: "xcodebuild timed out.",
                fix: "Retry with the device connected and unlocked; if it repeats, open the carrier project in Xcode once.")
        }
        if let spawn = input.spawnError, !spawn.isEmpty {
            return Failure(
                code: "PROVISION_FAILED", message: "xcodebuild could not be started.",
                fix: "Run `sideload doctor`; check that Xcode is installed and selected.")
        }
        if input.exitCode == 0 { return nil }

        let log = "\(input.stderr)\n\(input.stdout)".lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { log.contains($0) } }

        if has("no account for team", "no accounts with", "add a new account", "session has expired", "sign in to your apple") {
            return Failure(
                code: "ACCOUNT_NOT_SIGNED_IN", message: "Xcode has no signed-in account for the free team.",
                fix:
                    "In Xcode > Settings > Accounts, sign in with the free Apple ID (owner action; sideload never takes a password), then retry.")
        }
        if has(
            "maximum number of app ids", "cannot register more than", "more than 10 app ids", "app id limit",
            "maximum number of registered app ids")
        {
            return Failure(
                code: "FREE_APP_ID_LIMIT", message: "Apple refused a new App ID: the free team's App ID limit is reached.",
                fix: "Wait for the 7-day window to pass; the limit is shared with Xcode and the lab. Nothing was registered.")
        }
        if has(
            "has no devices from which to generate", "include the currently selected device", "device is not registered")
        {
            return Failure(
                code: "DEVICE_NOT_REGISTERED",
                message: "The device is not registered with the free team (or not in the profile).",
                fix: registerDevice
                    ? "Connect the device, unlock it and retry; check that Developer Mode is on."
                    : "The owner registers it once: sideload provision --app <app> --device <alias> --register-device --yes.")
        }
        if has("device is locked", "unlock your device", "unlock the device") {
            return Failure(
                code: "DEVICE_LOCKED", message: "The device is locked.", fix: "Unlock the device and retry.")
        }
        if has("no signing certificate", "no valid signing identit") {
            return Failure(
                code: "FREE_IDENTITY_MISSING",
                message: "Xcode found no usable free-team signing certificate with its private key.",
                fix: "Check Xcode > Settings > Accounts > Manage Certificates (owner action). sideload never creates one.")
        }
        return Failure(
            code: "PROVISION_FAILED",
            message: "xcodebuild failed with exit code \(input.exitCode.map { String($0) } ?? "null").",
            fix: "See `logTail`; open the carrier project in Xcode once to see the signing error.")
    }

    /// The last lines of the build output (stderr then stdout), each cut to 300 characters, for the owner.
    /// `redact` runs on every line before it is kept.
    public static func tail(
        stderr: String, stdout: String, lines limit: Int = 20, redact: (String) -> String
    ) -> String {
        let all = "\(stdout)\n\(stderr)".split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        return all.suffix(limit)
            .map { redact(String($0.trimmingCharacters(in: .whitespaces).prefix(300))) }
            .joined(separator: "\n")
    }
}
