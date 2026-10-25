import Foundation

/// The pre-install guard (design section 10). Nothing touches
/// the device unless `codesign` shows the locked team on the built app and its embedded profile names that
/// team and this device's UDID.
public struct Guard: Sendable, Equatable {
    public let passed: Bool
    /// When not passed: `GUARD_FAILED`, `FREE_TEAM_SELECTED`, `WRONG_TEAM` or `DEVICE_NOT_IN_PROFILE`; in the
    /// free context also `BUNDLE_ID_NOT_ALLOWED`, `PROFILE_INVALID`, `PROFILE_CERT_MISMATCH` or `EXTENSION_REMAINS`.
    public let code: String?
    public let reason: String?
    /// What the guard saw, as far as it got, for the canary evidence bundle. Not part of equality.
    public let facts: Facts?

    /// Non-secret facts read from the built app and its embedded profile. Nil where the guard stopped first.
    public struct Facts: Sendable, Equatable {
        public var signedTeam: String?
        public var profileTeam: String?
        public var profileCreated: Date?
        public var profileExpires: Date?
        public var deviceCount: Int?
        public var deviceIncluded: Bool?
        /// The certificate is listed in the profile's `DeveloperCertificates`: the keychain certificate passed to
        /// `run` (paid, informational, never a failure), or the pinned free certificate (free context, where a
        /// miss is `PROFILE_CERT_MISMATCH`).
        public var signingCertInProfile: Bool?

        public init(
            signedTeam: String? = nil, profileTeam: String? = nil, profileCreated: Date? = nil,
            profileExpires: Date? = nil, deviceCount: Int? = nil, deviceIncluded: Bool? = nil,
            signingCertInProfile: Bool? = nil
        ) {
            self.signedTeam = signedTeam
            self.profileTeam = profileTeam
            self.profileCreated = profileCreated
            self.profileExpires = profileExpires
            self.deviceCount = deviceCount
            self.deviceIncluded = deviceIncluded
            self.signingCertInProfile = signingCertInProfile
        }
    }

    init(passed: Bool, code: String?, reason: String?, facts: Facts? = nil) {
        self.passed = passed
        self.code = code
        self.reason = reason
        self.facts = facts
    }

    public static func == (a: Guard, b: Guard) -> Bool {
        a.passed == b.passed && a.code == b.code && a.reason == b.reason
    }

    public static let pass = Guard(passed: true, code: nil, reason: nil)

    static func fail(_ code: String, _ reason: String, facts: Facts? = nil) -> Guard {
        Guard(passed: false, code: code, reason: reason, facts: facts)
    }

    static let toolTimeout = Duration.seconds(30)

    /// The team and device list of a decoded provisioning profile.
    struct Profile: Equatable {
        /// First entry of `TeamIdentifier`; nil when absent.
        var team: String?
        /// `ProvisionedDevices`, lowercased.
        var devices: [String]
        var creation: Date?
        var expiration: Date?
        /// Upper-case hex SHA-1 of each `DeveloperCertificates` entry (the same form as `KeychainCertificate.reference`).
        var certFingerprints: [String] = []
        /// `Entitlements` > `application-identifier`; nil when absent.
        var applicationIdentifier: String?
    }

    /// Reads the XML plist `security cms -D` prints. Nil when it is not a plist dictionary. Only the top-level keys are read, so a nested `TeamIdentifier`
    /// or `<string>` cannot be mistaken for them.
    static func parseProfile(_ xml: String) -> Profile? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil),
            let dict = plist as? [String: Any]
        else { return nil }
        let team = (dict["TeamIdentifier"] as? [Any])?.first as? String
        let devices = (dict["ProvisionedDevices"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() } ?? []
        let certs = (dict["DeveloperCertificates"] as? [Any])?.compactMap { ($0 as? Data).map(CertificateReader.sha1Hex) } ?? []
        let appId = (dict["Entitlements"] as? [String: Any])?["application-identifier"] as? String
        return Profile(
            team: team, devices: devices, creation: dict["CreationDate"] as? Date,
            expiration: dict["ExpirationDate"] as? Date, certFingerprints: certs, applicationIdentifier: appId)
    }

    /// `TeamIdentifier=` from `codesign -dvv` output (stderr first, as codesign writes there). `not set`
    /// (an ad-hoc or unsigned build) is no team.
    static func signedTeam(stderr: String, stdout: String) -> String? {
        guard let team = firstMatch(#"^TeamIdentifier=(\S+)"#, in: "\(stderr)\n\(stdout)") else { return nil }
        return team == "not" ? nil : team
    }

    /// The paid guard: `run(context: .paid, ...)`, unchanged.
    public static func run(runner: any Runner, app: String, udid: String, signingCert: String? = nil) async -> Guard {
        await run(context: .paid, runner: runner, app: app, udid: udid, signingCert: signingCert)
    }

    /// Runs the guard for `context`. `signingCert` applies to the paid context only; the free context checks
    /// its own pinned certificate.
    public static func run(
        context: SigningContext, runner: any Runner, app: String, udid: String, signingCert: String? = nil
    ) async -> Guard {
        switch context {
        case .paid: return await runPaid(runner: runner, app: app, udid: udid, signingCert: signingCert)
        case .free(let free): return await runFree(free, runner: runner, app: app, udid: udid)
        }
    }

    /// `signingCert` is the keychain certificate's `reference` (SHA-1); when given, the profile's
    /// `DeveloperCertificates` is checked for it and recorded in `facts` (informational, never a failure).
    private static func runPaid(runner: any Runner, app: String, udid: String, signingCert: String?) async -> Guard {
        let cs = await runner.run(
            CommandSpec(executable: "/usr/bin/codesign", args: ["-dvv", app], timeout: toolTimeout))
        guard cs.code == 0, let team = signedTeam(stderr: cs.stderr, stdout: cs.stdout) else {
            return .fail("GUARD_FAILED", "codesign could not read a team identifier from the built app.")
        }
        var facts = Facts(signedTeam: team)
        if Team.denied.contains(team) {
            return .fail("FREE_TEAM_SELECTED", "The built app is signed by the deny-listed free team.", facts: facts)
        }
        if team != Team.id {
            return .fail("WRONG_TEAM", "The built app is signed by a different team than the locked one.", facts: facts)
        }
        let prof = await runner.run(
            CommandSpec(
                executable: "/usr/bin/security", args: ["cms", "-D", "-i", app + "/embedded.mobileprovision"],
                timeout: toolTimeout))
        guard prof.code == 0, let profile = parseProfile(prof.stdout) else {
            return .fail("GUARD_FAILED", "The embedded provisioning profile could not be decoded.", facts: facts)
        }
        facts.profileTeam = profile.team
        facts.profileCreated = profile.creation
        facts.profileExpires = profile.expiration
        facts.deviceCount = profile.devices.count
        facts.deviceIncluded = profile.devices.contains(udid.lowercased())
        facts.signingCertInProfile = signingCert.map { cert in
            profile.certFingerprints.contains { $0.caseInsensitiveCompare(cert) == .orderedSame }
        }
        if profile.team != Team.id {
            return .fail(
                profile.team.map { Team.denied.contains($0) } == true ? "FREE_TEAM_SELECTED" : "WRONG_TEAM",
                "The embedded profile belongs to a different team than the locked one.", facts: facts)
        }
        if facts.deviceIncluded != true {
            return .fail(
                "DEVICE_NOT_IN_PROFILE", "The device is not in the profile ProvisionedDevices list.", facts: facts)
        }
        return Guard(passed: true, code: nil, reason: nil, facts: facts)
    }

    // MARK: Free context (design section 18)

    private static func runFree(_ free: FreeSigning, runner: any Runner, app: String, udid: String) async -> Guard {
        // Pure checks first: a non-allowlisted ID never reaches a subprocess.
        guard Config.isFreeBundleId(free.bundleId, prefix: free.bundleIdPrefix) else {
            return .fail(
                "BUNDLE_ID_NOT_ALLOWED", "The free team may only sign IDs under the configured <prefix>.free. namespace.")
        }
        let cs = await runner.run(
            CommandSpec(executable: "/usr/bin/codesign", args: ["-dvv", app], timeout: toolTimeout))
        guard cs.code == 0, let team = signedTeam(stderr: cs.stderr, stdout: cs.stdout) else {
            return .fail("GUARD_FAILED", "codesign could not read a team identifier from the built app.")
        }
        var facts = Facts(signedTeam: team)
        if team != Team.free {
            return .fail("WRONG_TEAM", "The built app is not signed by the free team.", facts: facts)
        }
        // The caller's bundle ID is not trusted: the app must say the same thing itself (all `GUARD_FAILED`).
        if signedIdentifier(stderr: cs.stderr, stdout: cs.stdout) != free.bundleId {
            return .fail("GUARD_FAILED", "The signed identifier of the built app is not this bundle ID.", facts: facts)
        }
        let prof = await runner.run(
            CommandSpec(
                executable: "/usr/bin/security", args: ["cms", "-D", "-i", app + "/embedded.mobileprovision"],
                timeout: toolTimeout))
        guard prof.code == 0, let profile = parseProfile(prof.stdout) else {
            return .fail("GUARD_FAILED", "The embedded provisioning profile could not be decoded.", facts: facts)
        }
        facts.profileTeam = profile.team
        facts.profileCreated = profile.creation
        facts.profileExpires = profile.expiration
        facts.deviceCount = profile.devices.count
        facts.deviceIncluded = profile.devices.contains(udid.lowercased())
        facts.signingCertInProfile = profile.certFingerprints.contains {
            $0.caseInsensitiveCompare(free.pinnedCertificate.hex) == .orderedSame
        }
        if profile.team != Team.free {
            return .fail("WRONG_TEAM", "The embedded profile does not belong to the free team.", facts: facts)
        }
        // Fail closed on a missing or past expiry (the clock is the caller's, `FreeSigning.now`).
        guard let expires = profile.expiration, free.now < expires else {
            return .fail("PROFILE_INVALID", "The embedded profile has expired or has no expiry date.", facts: facts)
        }
        // A free team has no wildcard profile: the exact App ID or nothing.
        if profile.applicationIdentifier != free.applicationIdentifier {
            return .fail(
                "PROFILE_INVALID", "The embedded profile's application-identifier is not the free team and this bundle ID.",
                facts: facts)
        }
        if facts.deviceIncluded != true {
            return .fail(
                "DEVICE_NOT_IN_PROFILE", "The device is not in the profile ProvisionedDevices list.", facts: facts)
        }
        if facts.signingCertInProfile != true {
            return .fail(
                "PROFILE_CERT_MISMATCH", "The pinned free certificate is not in the profile DeveloperCertificates list.",
                facts: facts)
        }
        if await !signedWithPinnedCertificate(free, runner: runner, app: app) {
            return .fail(
                "GUARD_FAILED", "The app was not signed with the pinned free certificate, or its signature could not be read.",
                facts: facts)
        }
        if let mismatch = await identityMismatch(free, runner: runner, app: app) {
            return .fail("GUARD_FAILED", mismatch, facts: facts)
        }
        switch scanBundle(app) {
        case .extensionFound:
            return .fail("EXTENSION_REMAINS", "The app bundle still contains an app extension (.appex).", facts: facts)
        case .unsafeLink(let path):
            return .fail(
                "GUARD_FAILED", "The app bundle has a symlink that is dangling or leaves the bundle: \(path).", facts: facts)
        case .unreadable:
            return .fail("GUARD_FAILED", "The app bundle could not be read.", facts: facts)
        case .clean:
            return Guard(passed: true, code: nil, reason: nil, facts: facts)
        }
    }

    /// Whether the app's signature leaf (`cert0` from `codesign -d --extract-certificates`) is exactly the pinned
    /// certificate, by SHA-1 of its DER. The listing in the profile is not proof of what signed the app. The
    /// certificate is extracted into a 0700 scratch directory that is removed on every path; its subject is
    /// never read. Any failure, including a scratch directory that cannot be made, is a no.
    private static func signedWithPinnedCertificate(_ free: FreeSigning, runner: any Runner, app: String) async -> Bool {
        guard let scratch = try? ScratchDirectory.create(under: free.scratchRoot, registry: .shared) else { return false }
        defer { scratch.remove() }
        let prefix = scratch.path + "/cert"
        let result = await runner.run(
            CommandSpec(
                executable: "/usr/bin/codesign", args: ["-d", "--extract-certificates=" + prefix, app],
                timeout: toolTimeout))
        guard result.code == 0, let der = FileManager.default.contents(atPath: prefix + "0"), !der.isEmpty else {
            return false
        }
        return CertificateReader.sha1Hex(der).caseInsensitiveCompare(free.pinnedCertificate.hex) == .orderedSame
    }

    /// `Identifier=` from `codesign -dvv` output (the signed bundle identifier); nil when absent.
    static func signedIdentifier(stderr: String, stdout: String) -> String? {
        firstMatch(#"^Identifier=(\S+)"#, in: "\(stderr)\n\(stdout)")
    }

    /// Why the app's own identity disagrees with `free.bundleId`, or nil when it agrees. `Info.plist`
    /// `CFBundleIdentifier` must equal it (unreadable fails closed). The signed entitlements' `application-identifier`
    /// must be `6ZU5Z6ZKK7.<id>` when `codesign` can print them; an empty or unparsable print is skipped, since the
    /// profile check has already pinned the same value.
    private static func identityMismatch(_ free: FreeSigning, runner: any Runner, app: String) async -> String? {
        let infoURL = URL(fileURLWithPath: app).appendingPathComponent("Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any],
            let bundleId = info["CFBundleIdentifier"] as? String
        else { return "The built app's Info.plist has no readable CFBundleIdentifier." }
        if bundleId != free.bundleId { return "The built app's CFBundleIdentifier is not this bundle ID." }
        let ent = await runner.run(
            CommandSpec(
                executable: "/usr/bin/codesign", args: ["-d", "--entitlements", "-", "--xml", app], timeout: toolTimeout))
        guard
            ent.code == 0,
            let plist = try? PropertyListSerialization.propertyList(from: Data(ent.stdout.utf8), options: [], format: nil),
            let entitlements = plist as? [String: Any]
        else { return nil }
        if entitlements["application-identifier"] as? String != free.applicationIdentifier {
            return "The signed entitlements' application-identifier is not the free team and this bundle ID."
        }
        return nil
    }

    private enum BundleScan: Equatable {
        case clean, extensionFound, unreadable
        /// The bundle-relative path of a symlink that is dangling, loops, or resolves outside the bundle.
        case unsafeLink(String)
    }

    /// Walks `app` without following symlinks. An entry named `*.appex` (case-insensitive; a symlink counts)
    /// is `extensionFound`. A symlink that does not resolve (dangling or a loop) or whose fully resolved target
    /// is outside the bundle (an absolute target, a `..` escape, a symlinked `PlugIns/`, `Extensions/` or
    /// `Watch/`) is `unsafeLink` with its relative path; links that resolve inside the bundle (a framework's
    /// `Versions/Current`) are allowed. An extension outranks a link problem.
    private static func scanBundle(_ app: String) -> BundleScan {
        let url = URL(fileURLWithPath: app, isDirectory: true)
        guard let root = realPath(url.path) else { return .unreadable }
        var failed = false
        guard
            let walk = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failed = true; return true })
        else { return .unreadable }
        var badLink: String?
        for case let entry as URL in walk {
            // Name suffix, not `pathExtension`: an entry named exactly ".appex" has an empty extension.
            if entry.lastPathComponent.lowercased().hasSuffix(".appex") { return .extensionFound }
            guard badLink == nil,
                (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) != nil
            else { continue }
            if let target = realPath(entry.path), target == root || target.hasPrefix(root + "/") { continue }
            badLink = entry.pathComponents.suffix(walk.level).joined(separator: "/")
        }
        if failed { return .unreadable }
        return badLink.map(BundleScan.unsafeLink) ?? .clean
    }

    /// `realpath(3)`: every symlink resolved; nil when the path does not resolve.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Which team's rules the guard applies (design sections 10 and 18). Chosen per app, never by fallback.
public enum SigningContext: Sendable, Equatable {
    /// The locked paid team: the guard exactly as it was.
    case paid
    /// The free team, for one allowlisted bundle ID and its pinned certificate.
    case free(FreeSigning)
}

/// What the free guard checks the built app against.
public struct FreeSigning: Sendable, Equatable {
    /// The bundle ID the app was signed as; must be `<bundleIdPrefix>.free.<name>`.
    public let bundleId: String
    /// The config `bundleIdPrefix`; nil or invalid allows nothing.
    public let bundleIdPrefix: String?
    /// The pinned identity's SHA-1 (`freeTeam.certFp8` resolved through `CertCheck.pinnedFree`).
    public let pinnedCertificate: CertReference
    /// The current time (`Services.clock.now()`), for the profile's expiry.
    public let now: Date
    /// A writable directory for the 0700 scratch folder the signing-certificate check extracts into
    /// (`$SIDELOAD_HOME/tmp`).
    public let scratchRoot: String

    public init(
        bundleId: String, bundleIdPrefix: String?, pinnedCertificate: CertReference, now: Date, scratchRoot: String
    ) {
        self.bundleId = bundleId
        self.bundleIdPrefix = bundleIdPrefix
        self.pinnedCertificate = pinnedCertificate
        self.now = now
        self.scratchRoot = scratchRoot
    }

    /// The `application-identifier` the profile and the signed entitlements must carry: a free team has no
    /// wildcard, so `6ZU5Z6ZKK7.<bundleId>` exactly.
    public var applicationIdentifier: String { Team.free + "." + bundleId }
}
