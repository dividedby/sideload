import Darwin
import Foundation

/// The only way sideload runs `xcrun devicectl` (design section 5; port of `exec.devicectl`).
///
/// - `--device` must be a saved ID: callers pass `deviceAlias`, resolved to the CoreDevice UUID (else UDID).
///   A literal `--device`/`-d` value is accepted only if it is a saved ID.
/// - `--timeout` and `--json-output` are always set here; callers may not pass them.
/// - App installs, uninstalls and launches carry a `Scope` (design section 18). `run` itself classifies the argv, so
///   no caller can reach such a subcommand without the check: in the `free` scope the bundle ID must be
///   `Config.isFreeBundleId` (and match the argv's own ID), in the `paid` scope a free-allowlisted ID is refused,
///   so labelling a free app as paid fails too. Both stop with `BUNDLE_ID_NOT_ALLOWED` before the subprocess.
/// - Output is read from the `--json-output` file only, which is deleted on every path.
public struct DeviceCtl: Sendable {
    public struct Result: Sendable, Equatable {
        public var code: Int32?
        public var timedOut: Bool
        /// The parsed `--json-output` file; nil when devicectl wrote nothing parseable.
        public var json: JSONValue?
        public var stderr: String
        public var spawnError: String?
    }

    /// Whose rules an app-mutating call runs under. The default is `paid` (the canary); `free` names the one
    /// bundle ID the call is about.
    public enum Scope: Sendable, Equatable {
        case paid
        case free(bundleId: String)
    }

    private enum AppMutation {
        case install, uninstall, launch
    }

    private let runner: any Runner
    private let paths: Paths
    private let loadConfig: @Sendable () throws -> Config

    public init(runner: any Runner, paths: Paths, loadConfig: @escaping @Sendable () throws -> Config) {
        self.runner = runner
        self.paths = paths
        self.loadConfig = loadConfig
    }

    public init(runner: any Runner, store: ConfigStore) {
        self.init(runner: runner, paths: store.paths, loadConfig: { try store.load() })
    }

    private static func misuse(_ message: String) -> SideloadError {
        SideloadError("INVALID_ARGUMENT", "devicectl: \(message)")
    }

    /// Values of every `flag value` and `flag=value` occurrence (a trailing bare flag yields "").
    private static func values(of flag: String, in args: [String]) -> [String] {
        var out: [String] = []
        for (i, arg) in args.enumerated() {
            if arg == flag {
                out.append(i + 1 < args.count ? args[i + 1] : "")
            } else if arg.hasPrefix(flag + "=") {
                out.append(String(arg.dropFirst(flag.count + 1)))
            }
        }
        return out
    }

    /// Classifies the argv devicectl will actually receive (after `--device` is stripped). Fails closed: any
    /// `install`, `uninstall` or `launch` word that is not exactly one known subcommand with no other non-flag
    /// word (so no bundle ID or path can ride in `args`) is refused. Nil means the call names no app.
    private static func appMutation(_ normalized: [String]) throws -> AppMutation? {
        let words = normalized.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        guard words.contains(where: { ["install", "uninstall", "launch"].contains($0) }) else { return nil }
        switch words {
        case ["device", "install", "app"]: return .install
        case ["device", "uninstall", "app"]: return .uninstall
        case ["device", "process", "launch"]: return .launch
        default: throw notAllowed("This devicectl command is not a recognised app install, uninstall or launch.")
        }
    }

    /// The one profile call: `devicectl device profile list --device <id> --type provisioning --timeout <n> --json-output <file>`.
    /// `run` adds the device, timeout and output path itself, so the caller's whole argument vector (after `--device` is
    /// stripped) is exactly this, with no positional.
    static let profileListArgs = ["device", "profile", "list", "--type", "provisioning"]

    /// Profiles are read, never written: `device profile` may only be exactly `profileListArgs` with no positional;
    /// `install`, `remove`, `validate` and anything else under it, however the words are split between the flags and the
    /// positionals, is refused before a subprocess.
    private static func requireReadOnlyProfileCall(_ normalized: [String], positional: [String]) throws {
        let words = (normalized + positional).filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        guard words.contains("profile") || words.contains("profiles") else { return }
        guard normalized == profileListArgs, positional.isEmpty else {
            throw notAllowed("Only the read-only `device profile list --type provisioning` may touch profiles.")
        }
    }

    private static func notAllowed(_ message: String) -> SideloadError {
        SideloadError(
            "BUNDLE_ID_NOT_ALLOWED", message,
            fix: "The free team only touches <bundleIdPrefix>.free.* apps; the paid path never touches them.")
    }

    /// The allowlist hook. Runs before any subprocess.
    private static func checkScope(_ scope: Scope, normalized: [String], positional: [String], config: Config) throws {
        // A positional is appended after the flags, so one spelling a subcommand word could complete a split
        // subcommand (`["device"]` + `["uninstall","app",id]`). No positional may be one (a leading "-" is
        // already `INVALID_ARGUMENT` in `run`).
        let reserved: Set<String> = ["install", "uninstall", "launch", "app", "process", "remove", "validate", "profile", "profiles"]
        if positional.contains(where: { reserved.contains($0.lowercased()) }) {
            throw notAllowed("A positional argument may not be a devicectl subcommand word.")
        }
        try requireReadOnlyProfileCall(normalized, positional: positional)
        guard let mutation = try appMutation(normalized) else { return }  // list, info and the like name no app
        // Exactly one positional: the bundle ID (uninstall, launch) or the app path (install).
        guard positional.count == 1 else {
            throw notAllowed("An app install, uninstall or launch takes exactly one positional argument.")
        }
        let argvID = mutation == .install ? nil : positional.first
        switch scope {
        case .free(let bundleId):
            guard Config.isFreeBundleId(bundleId, prefix: config.bundleIdPrefix) else {
                throw notAllowed("This bundle ID is not allowed for the free team.")
            }
            if mutation != .install, argvID != bundleId {
                throw notAllowed("The bundle ID in the command does not match the free scope.")
            }
        case .paid:
            if let argvID, Config.isFreeBundleId(argvID, prefix: config.bundleIdPrefix) {
                throw notAllowed("A free-team app ID cannot be used in a paid-team call.")
            }
        }
    }

    public func run(
        _ args: [String], deviceAlias: String? = nil, timeoutSec: Int = 30, positional: [String] = [],
        scope: Scope = .paid
    ) async throws -> Result {
        guard timeoutSec > 0 else { throw Self.misuse("a positive timeoutSec is required") }
        if positional.contains(where: { $0.hasPrefix("-") }) {
            throw Self.misuse("positional arguments must be strings that do not start with \"-\"")
        }
        for owned in ["--timeout", "--json-output"] where !Self.values(of: owned, in: args).isEmpty {
            throw Self.misuse("\(owned) is set by the wrapper")
        }

        let config = try loadConfig()
        let literal = Self.values(of: "--device", in: args) + Self.values(of: "-d", in: args)
        var rest: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--device" || arg == "-d" {
                i += 1  // drop the value too
            } else if !arg.hasPrefix("--device=") && !arg.hasPrefix("-d=") {
                rest.append(arg)
            }
            i += 1
        }
        // Classify what devicectl will receive: `rest`, not the raw args, so `--device X` cannot split the subcommand.
        try Self.checkScope(scope, normalized: rest, positional: positional, config: config)

        var deviceID: String?
        if let deviceAlias {
            if !literal.isEmpty { throw Self.misuse("pass either deviceAlias or --device, not both") }
            deviceID = try config.requireDevice(deviceAlias).deviceId
        } else if !literal.isEmpty {
            guard literal.count == 1, config.isSavedDeviceID(literal[0]) else {
                throw SideloadError(
                    "DEVICE_NOT_SAVED", "devicectl --device must be a saved device ID.",
                    fix: "Use a saved alias; names, serials and DNS names are never passed to devicectl.")
            }
            deviceID = literal[0]
        }

        try makeDirectories(paths.tmp, mode: 0o700)
        let jsonFile = paths.tmp + "/devicectl-\(randomHex(bytes: 6)).json"
        // devicectl creates the file (not pre-created); the random name sits in the 0700 tmp/.
        defer { unlink(jsonFile) }

        var argv = ["devicectl"] + rest
        if let deviceID { argv += ["--device", deviceID] }
        argv += ["--timeout", String(timeoutSec), "--json-output", jsonFile] + positional

        let res = await runner.run(
            CommandSpec(executable: "xcrun", args: argv, timeout: .seconds(timeoutSec + 15)))
        if res.overflow {
            throw SideloadError(
                "OUTPUT_LIMIT", "devicectl produced more output than the safety limit; it was stopped.",
                fix: "Retry; if it repeats, run the command by hand to see what is flooding.")
        }
        // Missing, empty or unparseable output is nil. Tighten the mode before reading.
        chmod(jsonFile, 0o600)
        var json: JSONValue?
        if let data = try? readFile(jsonFile) { json = try? JSONDecoder().decode(JSONValue.self, from: data) }
        return Result(
            code: res.code, timedOut: res.timedOut, json: json, stderr: String(res.stderr.prefix(4000)),
            spawnError: res.spawnError)
    }
}
