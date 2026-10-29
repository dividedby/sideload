import Darwin
import Foundation

/// The `$SIDELOAD_HOME` layout (design section 9): `config.json`, `ledger.json`, `manifest.json`, `secrets/`, `downloads/`,
/// `builds/`, `logs/`, `tmp/` and the three lock files. Directories are 0700, files 0600.
public struct Paths: Sendable, Equatable {
    public static let subdirectories = ["secrets", "downloads", "builds", "logs", "tmp"]

    public let home: String

    public init(home: String) {
        self.home = home
    }

    public var config: String { home + "/config.json" }
    public var secrets: String { home + "/secrets" }
    public var downloads: String { home + "/downloads" }
    public var builds: String { home + "/builds" }
    public var logs: String { home + "/logs" }
    /// Opt-in canary evidence bundles (`canary --evidence`). Created lazily, not part of `subdirectories`.
    public var evidence: String { home + "/evidence" }
    /// Feather kits (`export-cert`). Created lazily, not part of `subdirectories`.
    public var exports: String { home + "/exports" }
    /// The App Store Connect API key for `portal` (`key.json` + the `.p8`). The owner creates it; `ensureHome` does not.
    public var asc: String { home + "/asc" }
    public var tmp: String { home + "/tmp" }
    /// Free-team development profiles `provision` keeps (`profiles/free/<app>/<device>/<uuid>.mobileprovision`, 0600;
    /// they contain device IDs). Created lazily, not part of `subdirectories`.
    public var freeProfiles: String { home + "/profiles/free" }
    /// App-data backups (`backups/<alias>/<app>/<stamp>/`, dirs 0700, files 0600). They hold session tokens: secrets-class,
    /// never printed, logged, in the ledger or the repo. Created lazily, not part of `subdirectories`.
    public var backups: String { home + "/backups" }
    /// The runtime-generated profile-carrier project (`CarrierProject`) and its derived data, both under `builds/`.
    public var carrierProject: String { builds + "/carrier" }
    public var carrierDerivedData: String { builds + "/carrier-dd" }
    /// Free-team re-signed apps `sign` leaves for `install` (`builds/signed/<app>/<device>/<Name>.app`, folders 0700).
    /// Created lazily, not part of `subdirectories`.
    public var signedBuilds: String { builds + "/signed" }
    /// Exported `.p12` masters (`export-cert`), inside `secrets/`. Created lazily.
    public var p12Dir: String { secrets + "/p12" }
    /// Certificate, profile and export history (design section 9). Holds no secrets.
    public var ledger: String { home + "/ledger.json" }
    /// Every IPA `fetch` downloaded: sha256, version, approval (design section 9). Holds no secrets.
    public var manifest: String { home + "/manifest.json" }
    /// What `updates` last saw upstream per source (design section 9). Advisory only; holds no secrets.
    public var updates: String { home + "/updates.json" }
    public var canaryLog: String { logs + "/canary.jsonl" }
    public var commandsLog: String { logs + "/commands.log" }
    /// One JSON line per `refresh --auto` decision and step (design section 18). Aliases, app names, codes and numbers only.
    public var refreshLog: String { logs + "/refresh.jsonl" }
    /// The kill switch: while this file exists, `refresh --auto` does nothing. The owner creates and removes it (`touch`).
    public var refreshDisabled: String { home + "/refresh.disabled" }
    public var configLock: String { home + "/.config.lock" }
    public var opLock: String { home + "/.op.lock" }
    public var ledgerLock: String { home + "/.ledger.lock" }

    var directories: [String] { [home] + Self.subdirectories.map { home + "/" + $0 } }

    /// `$SIDELOAD_HOME` when set and non-empty, else `<homeDirectory>/.sideload`, made absolute and normalised.
    public static func resolveHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> Paths {
        let configured = environment["SIDELOAD_HOME"] ?? ""
        return Paths(home: resolvePath(configured.isEmpty ? homeDirectory + "/.sideload" : configured))
    }

    /// Walks up from the nearest existing ancestor looking for a `.git` entry (directory or worktree file).
    /// Pure filesystem walk: no `git` subprocess.
    public func findGitWorkTree() throws -> String? {
        try Self.gitWorkTree(containing: home)
    }

    /// The same walk for any path (`export-cert --out`): the nearest existing ancestor, then up to a `.git` entry.
    public static func gitWorkTree(containing path: String) throws -> String? {
        var dir = resolvePath(path)
        while try !pathExists(dir) {
            let parent = parentPath(dir)
            if parent == dir { return nil }
            dir = parent
        }
        guard let real = realpath(dir, nil) else { throw ioError("realpath") }
        defer { free(real) }
        dir = String(cString: real)
        // A file (or anything that is not a directory) cannot hold `.git`: start from its folder.
        var st = stat()
        if stat(dir, &st) == 0, st.st_mode & S_IFMT != S_IFDIR { dir = parentPath(dir) }
        while true {
            if try pathExists(dir + "/.git") { return dir }
            let parent = parentPath(dir)
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// Refuses a home inside a git work tree, then creates the home and its subdirectories as 0700
    /// (repairing loose modes). Nothing is created when the home is refused.
    public func ensureHome() throws {
        if try findGitWorkTree() != nil {
            throw SideloadError(
                "HOME_IN_GIT_WORKTREE",
                "SIDELOAD_HOME is inside a git work tree; secrets could be committed.",
                fix: "Set SIDELOAD_HOME to a directory outside any repository (default: ~/.sideload).")
        }
        for dir in directories {
            try makeDirectories(dir, mode: 0o700)
            if chmod(dir, 0o700) != 0 { throw ioError("chmod") }
        }
    }

    public struct ModeProblem: Sendable, Equatable {
        public let path: String
        public let mode: Int
        public let want: Int
    }

    /// Reports (does not fix) loose permissions under the home: group/other bits on a directory or config.json.
    public func checkModes() -> [ModeProblem] {
        var problems: [ModeProblem] = []
        for dir in directories {
            var st = stat()
            if stat(dir, &st) == 0, st.st_mode & 0o077 != 0 {
                problems.append(ModeProblem(path: dir, mode: Int(st.st_mode & 0o777), want: 0o700))
            }
        }
        var st = stat()
        if stat(config, &st) == 0, st.st_mode & 0o077 != 0 {
            problems.append(ModeProblem(path: config, mode: Int(st.st_mode & 0o777), want: 0o600))
        }
        return problems
    }
}
