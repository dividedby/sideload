import Darwin
import Foundation
import SystemConfiguration

/// Wall-clock time, injectable so expiry maths is testable.
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}

/// The filesystem facts commands need beyond the config store.
public protocol FileSystem: Sendable {
    /// Bytes available to unprivileged users on the volume holding `path` (`statfs` `f_bavail * f_bsize`).
    func freeBytes(at path: String) throws -> UInt64
}

public struct SystemFileSystem: FileSystem {
    public init() {}

    public func freeBytes(at path: String) throws -> UInt64 {
        var st = statfs()
        guard statfs(path, &st) == 0 else { throw ioError("statfs") }
        return UInt64(st.f_bavail) * UInt64(st.f_bsize)
    }
}

/// Who is running sideload, for the evidence bundle: no word of the login name, the full name, the home directory
/// or this Mac's names may appear in it. Injectable so tests can use any of them.
public struct LocalUser: Sendable, Equatable {
    public var login: String
    public var fullName: String
    public var homeDirectory: String
    /// System Settings > General > About > Name (`ComputerName`), and the Bonjour host name (`LocalHostName`).
    public var computerName: String
    public var localHostName: String

    public init(
        login: String, fullName: String = "", homeDirectory: String = "", computerName: String = "",
        localHostName: String = ""
    ) {
        self.login = login
        self.fullName = fullName
        self.homeDirectory = homeDirectory
        self.computerName = computerName
        self.localHostName = localHostName
    }

    /// The account only; this Mac's names are looked up on demand (`Services.machineNames`).
    public static var current: LocalUser {
        LocalUser(login: NSUserName(), fullName: NSFullUserName(), homeDirectory: NSHomeDirectory())
    }

    /// `ComputerName` and `LocalHostName` from SystemConfiguration (empty when unavailable).
    public static func systemMachineNames() -> (computerName: String, localHostName: String) {
        (
            SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "",
            SCDynamicStoreCopyLocalHostName(nil) as String? ?? ""
        )
    }
}

/// Everything a command needs from the outside world (design section 3). The CLI builds the live set; tests
/// build fakes. `http` is the App Store Connect client for `portal`; the default throws, so nothing reaches the
/// network unless the live set wires a real transport.
public struct Services: Sendable {
    public var runner: any Runner
    public var fs: any FileSystem
    public var clock: any WallClock
    public var keychain: any KeychainClient
    public var home: Paths
    /// Progress lines (`canary: preflight`). The live one writes redacted lines to stderr and `logs/commands.log`.
    public var log: @Sendable (String) -> Void
    /// The canary Xcode project; nil means the repo's `canary/Canary.xcodeproj` (see `CanaryCommand`).
    public var canaryProject: String?
    public var localUser: LocalUser
    /// This Mac's names, asked for only when a canary run needs them (the evidence bundle and the install log).
    public var machineNames: @Sendable () -> (computerName: String, localHostName: String)
    /// Provisioning profiles (design section 8, `ledger refresh`). The default is inert, so a test that forgets
    /// to inject a source can never read the real Xcode profile folders.
    public var profiles: any ProfileSource
    /// Private-key export, the password item and .p12 verification (design section 6). The defaults are inert and
    /// throw `KEYCHAIN_UNAVAILABLE`, so a test that forgets a fake can never touch the real keychain.
    public var identityExporter: any IdentityExporter
    public var secrets: any SecretStore
    public var p12Verifier: any P12Verifier
    /// Where `export-cert --copy-password` puts the password. Inert by default (Core has no windowing framework): the `sideload`
    /// CLI wires the macOS pasteboard, so a test can never touch the real pasteboard.
    public var pasteboard: any SecretPasteboard
    public var http: any HTTPTransport
    /// Waits between retries of a failed `GET`. Throws `CancellationError` when the run is cancelled; tests pass a no-op.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Lets SIGINT/SIGTERM/SIGHUP end the `--copy-password` hold early (the CLI wires its signal handlers to it).
    /// The default is never tripped, so a hold simply runs its full length.
    public var holdSignal: HoldSignal
    /// What the running command wants in the `INTERRUPTED` object (`provision --renew` registers what it moved). The
    /// default is inert until a command sets it; the CLI shares one instance with its signal handlers.
    public var interruptReport: InterruptReport
    /// Work to run after the command's one stdout object was fully written (`provision` settles its ledger record of
    /// the moves the envelope reported). The default is inert; the CLI runs it from `main.swift`.
    public var postEmit: PostEmit
    /// Xcode's provisioning-profile folders, which `provision --renew` may move sideload's own cached profile out
    /// of (design section 18). Empty by default, so a test that forgets to set it can never touch the real folders.
    public var xcodeProfileDirectories: [String]
    /// Test hook for crash injection: called with a write-point name (`lend.intent`, `return.final`, ...) right after the
    /// slot state machine's ledger write is durable. A throw simulates the process dying there. Always nil in the CLI.
    public var afterDurableWrite: (@Sendable (String) throws -> Void)?

    public init(
        runner: any Runner, fs: any FileSystem, clock: any WallClock, keychain: any KeychainClient, home: Paths,
        log: @escaping @Sendable (String) -> Void = { _ in }, canaryProject: String? = nil,
        localUser: LocalUser = .current,
        machineNames: @escaping @Sendable () -> (computerName: String, localHostName: String) = { ("", "") },
        profiles: any ProfileSource = UnavailableProfileSource(),
        identityExporter: any IdentityExporter = UnavailableIdentityExporter(),
        secrets: any SecretStore = UnavailableSecretStore(),
        p12Verifier: any P12Verifier = UnavailableP12Verifier(),
        pasteboard: any SecretPasteboard = UnavailableSecretPasteboard(),
        http: any HTTPTransport = DisabledTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        holdSignal: HoldSignal = HoldSignal(), interruptReport: InterruptReport = InterruptReport(),
        postEmit: PostEmit = PostEmit(),
        xcodeProfileDirectories: [String] = [],
        afterDurableWrite: (@Sendable (String) throws -> Void)? = nil
    ) {
        self.runner = runner
        self.fs = fs
        self.clock = clock
        self.keychain = keychain
        self.home = home
        self.log = log
        self.canaryProject = canaryProject
        self.localUser = localUser
        self.machineNames = machineNames
        self.profiles = profiles
        self.identityExporter = identityExporter
        self.secrets = secrets
        self.p12Verifier = p12Verifier
        self.pasteboard = pasteboard
        self.http = http
        self.sleep = sleep
        self.holdSignal = holdSignal
        self.interruptReport = interruptReport
        self.postEmit = postEmit
        self.xcodeProfileDirectories = xcodeProfileDirectories
        self.afterDurableWrite = afterDurableWrite
    }

    /// Real subprocesses, filesystem, clock and login keychain; home from `$SIDELOAD_HOME`.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Services {
        let home = Paths.resolveHome(environment: environment)
        let clock = SystemClock()
        let runner = LoggingRunner(PosixSpawnRunner(), log: ProgressLog.makeFileOnly(home: home, clock: clock))
        return Services(
            runner: runner,
            fs: SystemFileSystem(), clock: clock,
            keychain: SecurityKeychain(), home: home, log: ProgressLog.make(home: home, clock: clock),
            machineNames: LocalUser.systemMachineNames,
            profiles: XcodeManagedProfileSource(
                runner: runner, directories: XcodeManagedProfileSource.defaultDirectories(homeDirectory: NSHomeDirectory())),
            identityExporter: SecurityIdentityExporter(), secrets: SecurityKeychainSecretStore(),
            p12Verifier: SecurityP12Verifier(), http: URLSessionTransport(),
            xcodeProfileDirectories: XcodeManagedProfileSource.defaultDirectories(homeDirectory: NSHomeDirectory()))
    }

    public var store: ConfigStore { ConfigStore(paths: home) }

    public var deviceCtl: DeviceCtl { DeviceCtl(runner: runner, store: store) }

    public var ledgerStore: LedgerStore { LedgerStore(paths: home) }
}
