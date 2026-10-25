import CryptoKit
import Darwin
import Foundation
import Security

/// Options for `export-cert`.
public struct ExportCertOptions: Sendable, Equatable {
    public var device: String?
    public var profile: String?
    public var out: String?
    /// Owner confirmation (design section 8); agents must not pass it.
    public var yes: Bool
    /// Put the .p12 password on the pasteboard for `ExportCertCommand.clipboardHold`. Owner only; agents must not pass it.
    public var copyPassword: Bool

    public init(
        device: String? = nil, profile: String? = nil, out: String? = nil, yes: Bool = false, copyPassword: Bool = false
    ) {
        self.device = device
        self.profile = profile
        self.out = out
        self.yes = yes
        self.copyPassword = copyPassword
    }
}

/// `export-cert`: exports the paid team's development identity as a password-protected .p12 and picks the
/// matching development profile, then writes a folder for Feather (design sections 6 and 8). The password lives
/// in the keychain; it is never in the envelope, a log, the ledger or the kit. Order: cheap checks first, the
/// keychain dialog once, then verify, write, record in the ledger, and only then the kit.
public enum ExportCertCommand {
    static let command = "export-cert"
    /// How long `--copy-password` leaves the password on the pasteboard before clearing it (if still ours).
    public static let clipboardHoldSeconds = 90
    public static let clipboardHold = Duration.seconds(clipboardHoldSeconds)
    static let maxProfileBytes = 1 << 20

    public static func run(_ services: Services, _ options: ExportCertOptions) async -> Envelope {
        await run(services, options, ledgerStore: nil)
    }

    /// `ledgerStore` is a test seam (a failing writer, a short lock timeout); nil means `services.ledgerStore`.
    static func run(_ services: Services, _ options: ExportCertOptions, ledgerStore: LedgerStore?) async -> Envelope {
        do {
            return try await execute(services, options, ledgerStore: ledgerStore ?? services.ledgerStore)
        } catch let failure as KeychainFailure {
            return .from(failure.sideloadError, command: command)
        } catch {
            return .from(error, command: command)
        }
    }

    private static func usage(_ message: String) -> Envelope {
        .fail(
            command, code: "USAGE", message: message,
            fix: "sideload export-cert --device <alias> [--profile <uuid>] [--out <dir>] --yes")
    }

    private static func execute(
        _ services: Services, _ options: ExportCertOptions, ledgerStore: LedgerStore
    ) async throws -> Envelope {
        guard let alias = options.device, !alias.isEmpty else { return usage("export-cert needs --device <alias>.") }
        if let uuid = options.profile, UUID(uuidString: uuid) == nil { return usage("--profile must be a profile UUID.") }
        if let out = options.out, out.isEmpty { return usage("--out must not be empty.") }
        let config = try services.store.load()
        let device = try config.requireDevice(alias)
        guard let udid = device.udid, !udid.isEmpty else {
            return .fail(
                command, code: "DEVICE_NOT_SAVED", message: "The saved device has no UDID, which the profile match needs.",
                fix: "Re-save it: sideload device save --alias <alias> --match <device name> --platform ios --yes")
        }
        guard options.yes else { return confirmRequired(alias: alias, copyPassword: options.copyPassword) }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }

        // Everything cheap and fallible comes before the keychain dialog.
        _ = try ledgerStore.load()
        let now = services.clock.now()
        let certificates: [KeychainCertificate]
        do {
            certificates = try services.keychain.developmentIdentities()
        } catch let error as KeychainError {
            throw SideloadError(
                "KEYCHAIN_READ_FAILED", "Could not read signing identities: \(error.message).",
                fix: "Check that the login keychain is unlocked.")
        }
        let scan = try await services.profiles.candidates()
        let plan: ExportPlanner.Plan
        do {
            plan = try ExportPlanner.plan(
                certificates: certificates, profiles: scan.profiles, udid: udid, profileUUID: options.profile, now: now)
        } catch let failure as ExportPlanner.Failure {
            throw failure.sideloadError
        }
        guard let reference = CertReference(plan.certificate.reference), let notAfter = plan.certificate.info.notAfter,
            let profileExpires = plan.profile.expires
        else { throw ExportPlanner.Failure.certNotFound.sideloadError }
        let profileBytes = try readProfile(plan.profile)

        let home = services.home
        let stamp = Self.stamp(now)
        let fp8 = LedgerSync.fp8(reference.hex)
        let masterRelative = "secrets/p12/\(fp8)-\(stamp).p12"
        let master = home.home + "/" + masterRelative
        let destination = try resolveDestination(options.out, home: home, stamp: stamp)
        if try pathExists(master) {
            throw SideloadError(
                "EXPORT_EXISTS", "An export with this timestamp already exists.", fix: "Wait a few seconds and retry.")
        }

        // The password exists in the keychain before the key leaves it, so a .p12 can never be unrecoverable.
        services.log("export-cert: preparing the .p12 password")
        let secrets = services.secrets
        let existing = try await prompted { try secrets.readPassword() }
        let password: String
        let reused: Bool
        if let existing {
            guard !existing.isEmpty else { throw KeychainFailure.passwordUnreadable(errSecDecode) }
            password = existing
            reused = true
        } else {
            let fresh = PasswordGenerator.generate()
            try await prompted { try secrets.addPassword(fresh) }
            password = fresh
            reused = false
        }

        services.log("export-cert: approve the keychain prompt for the private key; choose Allow, not Always Allow")
        let exporter = services.identityExporter
        let p12 = try await prompted { try exporter.exportP12(reference: reference, password: password) }

        let identities: [CertReference]
        do {
            identities = try services.p12Verifier.identityReferences(p12: p12, password: password)
        } catch let failure as KeychainFailure {
            throw failure.sideloadError
        }
        guard identities.contains(reference) else {
            throw SideloadError(
                "P12_VERIFY_FAILED", "The exported file does not contain the expected identity.",
                fix: "Do not use that file; run the export again.")
        }
        let encryption = Pkcs12Inspector.inspect(p12)
        let sha256Prefix = SHA256.hash(data: p12).prefix(4).map { String(format: "%02x", $0) }.joined()

        // From here to the kit being in place every signal is absorbed and this function alone cleans up (the signal
        // handler never touches a file; design section 16). A signal before the ledger write ends in `rollBack()`
        // below; from the ledger write on the move finishes or rolls back. A signal before this point marks the
        // export dead and `beginWriting` then refuses to write anything.
        let holdSignal = services.holdSignal
        try holdSignal.beginWriting()
        defer { holdSignal.finish() }
        try makeDirectories(home.p12Dir, mode: 0o700)
        if chmod(home.p12Dir, 0o700) != 0 { throw ioError("chmod") }
        services.log("export-cert: writing the .p12 and the kit")
        try AtomicFile.write(p12, to: master, mode: 0o600)  // removes its own temp file on failure
        var cleanup: [@Sendable () -> Void] = [{ _ = unlink(master) }]
        func rollBack() { cleanup.reversed().forEach { $0() } }
        services.log("export-cert: wrote the .p12")

        let staged = KitWriter.stagingPath(beside: destination.path)
        cleanup.append { KitWriter.discard(staged: staged) }
        do {
            let readme = KitReadme.text(
                certFp8: fp8, certNotAfter: notAfter, profileExpires: profileExpires,
                legacyEncryption: encryption.isLegacy, wildcard: plan.profile.isWildcard)
            try KitWriter.stage(
                [
                    KitWriter.File(name: KitReadme.p12Name, data: p12, mode: 0o600),
                    KitWriter.File(name: KitReadme.profileName, data: profileBytes, mode: 0o600),
                    KitWriter.File(name: KitReadme.readmeName, data: Data(readme.utf8), mode: 0o600),
                ], at: staged, onFile: { services.log("export-cert: staged \($0)") })
        } catch {
            rollBack()
            throw error
        }
        services.log("export-cert: staged the kit")

        if !holdSignal.beginCommit() {
            rollBack()
            throw SideloadError(
                "INTERRUPTED", "Interrupted before the kit was written; the .p12 and the staged files were removed.",
                fix: "No kit exists yet. Re-run the export.")
        }

        let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let export = LedgerExport(
            id: "export-" + stamp, createdAt: created, certFp8: fp8, profileUuid: plan.profile.uuid,
            p12File: masterRelative, p12Sha256Prefix: sha256Prefix, encryption: encryption.label,
            passwordItem: "keychain", kitPath: destination.display, verified: true)
        do {
            try await ledgerStore.update { ledger in
                LedgerSync.merge(&ledger, certificates: certificates, profiles: scan.profiles, now: now)
                ledger.exports.append(export)
            }
        } catch {
            rollBack()
            throw error
        }

        do {
            if destination.replacesEmptyDirectory, rmdir(destination.path) != 0 { throw ioError("rmdir") }
            try KitWriter.commit(staged: staged, to: destination.path)
        } catch {
            // The ledger must not keep an entry for a kit that does not exist; if taking it back out fails, say so.
            var ledgerFailure: (any Error)?
            do {
                try await ledgerStore.update { $0.exports.removeAll { $0.id == export.id } }
            } catch {
                ledgerFailure = error
            }
            rollBack()
            if let ledgerFailure {
                throw SideloadError(
                    "LEDGER_ROLLBACK_FAILED",
                    "The kit could not be put in place (\(describe(error))) and ledger.json still lists export \(export.id), which has no kit (\(describe(ledgerFailure))).",
                    fix: "Run `sideload ledger refresh`, then remove the \"\(export.id)\" entry from ledger.json by hand; the .p12 and staged kit were removed. Run the export again.")
            }
            throw error
        }
        holdSignal.markCommitted(kit: destination.display)
        lock.release()

        var warnings: [JSONValue] = []
        if encryption.isLegacy {
            warnings.append(
                CanaryCommand.warning(
                    "P12_LEGACY_ENCRYPTION",
                    "The .p12 uses legacy encryption (\(encryption.label)); Feather may not read it.",
                    "If Feather rejects it with the right password, report it; re-encrypting is not built."))
        }
        if plan.warnsNotWildcard {
            warnings.append(
                CanaryCommand.warning(
                    "PROFILE_NOT_WILDCARD", "The profile is not a wildcard profile.",
                    "Feather matches profiles by bundle ID suffix, so it may not sign other apps with this one."))
        }

        var copied = false
        var cleared: Bool?
        var holdInterrupted = false
        if options.copyPassword {
            services.log("export-cert: kit at \(destination.display), recorded in ledger")
        }
        if options.copyPassword, holdSignal.beginCopy() {
            do {
                // Signals during the copy are absorbed (the handler must not clear before the copy lands); the hold
                // below then ends at once and the clear follows.
                let copyResult = Result { try services.pasteboard.copy(password) }
                holdSignal.copyFinished()
                try copyResult.get()
                copied = true
                services.log(
                    "export-cert: the password is on the clipboard (concealed). Paste it into Feather now; it is cleared in \(Self.clipboardHoldSeconds) s (Ctrl-C clears it now)")
                // Cancellation, an interrupted sleep or a signal still ends in the clear below.
                await Self.hold(Self.clipboardHold, services: services, signal: holdSignal)
                holdInterrupted = holdSignal.interrupted
                if holdInterrupted { services.log("export-cert: interrupted; the kit is complete and recorded") }
                cleared = services.pasteboard.clearIfOurs()
                services.log(
                    cleared == true ? "export-cert: clipboard cleared"
                        : "export-cert: clipboard left alone (it changed since, or was already cleared)")
            } catch let error as SideloadError {
                copied = false
                holdInterrupted = holdSignal.interrupted
                cleared = services.pasteboard.clearIfOurs()
                warnings.append(CanaryCommand.warning(error.code, error.message, error.fix ?? ""))
            } catch {
                // The kit exists and is recorded: whatever the pasteboard threw, the result still reports it.
                copied = false
                holdInterrupted = holdSignal.interrupted
                cleared = services.pasteboard.clearIfOurs()
                warnings.append(
                    CanaryCommand.warning(
                        "PASTEBOARD_FAILED", "The clipboard step failed unexpectedly: \(String(describing: error)).",
                        "The kit stands; nothing needs repeating. The password is in the keychain item \(SecurityKeychainSecretStore.service) / \(SecurityKeychainSecretStore.account) (Keychain Access); copy it from there."))
            }
        } else if holdSignal.interrupted {
            holdInterrupted = true
            cleared = true  // never copied: the password is not on the clipboard
            services.log(
                "export-cert: interrupted; the kit at \(destination.display) is complete and recorded in ledger"
                    + (options.copyPassword ? "; the password was not copied" : ""))
        }

        let (days, _) = ExpiryItems.level(notAfter: notAfter, now: now)
        let (profileDays, _) = ExpiryItems.level(notAfter: profileExpires, now: now)
        var data: [String: JSONValue] = [
            "certificate": [
                "fp8": .string(fp8), "team": .string(Team.id),
                "notBefore": plan.certificate.info.notBefore.map { .string(LedgerDates.string($0)) } ?? .null,
                "notAfter": .string(LedgerDates.string(notAfter)), "daysLeft": .number(Double(days)),
            ],
            "profile": [
                "uuid": .string(plan.profile.uuid), "wildcard": .bool(plan.profile.isWildcard),
                "expires": .string(LedgerDates.string(profileExpires)), "daysLeft": .number(Double(profileDays)),
                "deviceCount": .number(Double(plan.profile.devices.count)), "deviceIncluded": true,
            ],
            "p12": [
                "file": .string(masterRelative), "sha256Prefix": .string(sha256Prefix),
                "encryption": .string(encryption.label),
            ],
            "kit": [
                "path": .string(destination.display),
                "files": [.string(KitReadme.p12Name), .string(KitReadme.profileName), .string(KitReadme.readmeName)],
            ],
            "passwordItem": [
                "service": .string(SecurityKeychainSecretStore.service), "account": .string(SecurityKeychainSecretStore.account),
                "reused": .bool(reused),
            ],
            "passwordCopied": .bool(copied),
            "warnings": .array(warnings),
        ]
        if options.copyPassword { data["clipboardHoldInterrupted"] = .bool(holdInterrupted) }
        if options.copyPassword { data["clipboardCleared"] = .bool(cleared ?? false) }
        if copied { data["clipboardHoldSeconds"] = .number(Double(Self.clipboardHoldSeconds)) }
        return .result(command, data)
    }

    /// Waits out the clipboard hold: the timer, or the first signal (`HoldSignal.interrupted` says which). Cancellation
    /// of the run ends it too.
    private static func hold(_ duration: Duration, services: Services, signal: HoldSignal) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await services.sleep(duration) }
            group.addTask { try? await signal.wait() }
            await group.next()
            group.cancelAll()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? SideloadError)?.message ?? String(describing: error)
    }

    private static func confirmRequired(alias: String, copyPassword: Bool) -> Envelope {
        var effects: [String] = [
            "Reads the paid team's certificate and provisioning profiles (public data).",
            "Exports the development private key: macOS shows a keychain dialog (choose Allow, not Always Allow).",
            "Saves a generated .p12 password as a keychain item (service \(SecurityKeychainSecretStore.service), account \(SecurityKeychainSecretStore.account)) if none exists.",
            "Writes the .p12 under secrets/p12/ and a Feather kit folder; records the export in ledger.json.",
        ]
        if copyPassword {
            effects.append(
                "Puts the password on the clipboard (concealed) for \(clipboardHoldSeconds) s, so the command stays running until it is cleared.")
        }
        return .fail(
            command, code: "CONFIRM_REQUIRED",
            message: "export-cert exports a private key from the keychain and writes it, password protected, to disk.",
            fix: "The owner confirms by re-running with --yes. Agents must not pass --yes or --copy-password on their own.",
            data: ["device": .string(alias), "effects": .array(effects.map { .string($0) }), "copyPassword": .bool(copyPassword)])
    }

    /// Runs a keychain call that may raise a dialog under `PromptGuard`; failures become their `{code, message, fix}`.
    private static func prompted<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await PromptGuard.run(body)
        } catch let failure as KeychainFailure {
            throw failure.sideloadError
        }
    }

    private static func readProfile(_ profile: ProvisioningProfile) throws -> Data {
        guard let file = profile.file, let data = try readFile(file), !data.isEmpty, data.count <= maxProfileBytes else {
            throw SideloadError(
                "PROFILE_NOT_FOUND", "The chosen profile's file could not be read.",
                fix: "Run `sideload ledger refresh`, or let Xcode regenerate the profile.")
        }
        return data
    }

    struct Destination {
        var path: String
        /// What the output shows: home-relative when inside the home, else the absolute path.
        var display: String
        /// `--out` is an existing empty folder; it is removed just before the staged kit takes its place.
        var replacesEmptyDirectory: Bool
    }

    /// `--out`, or `exports/feather-<stamp>`: absent or an empty folder, and not inside a git work tree.
    static func resolveDestination(_ out: String?, home: Paths, stamp: String) throws -> Destination {
        let path = out.map(resolvePath) ?? home.exports + "/feather-" + stamp
        if path == "/" || parentPath(path) == path {
            throw SideloadError("OUT_NOT_EMPTY", "--out must be a new folder.", fix: "Choose a new or empty folder.")
        }
        if try Paths.gitWorkTree(containing: path) != nil {
            throw SideloadError(
                "OUT_IN_GIT_WORKTREE", "--out is inside a git work tree; the kit could be committed.",
                fix: "Choose a folder outside any repository.")
        }
        var empty = false
        if try pathExists(path) {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true
            else {
                throw SideloadError(
                    "OUT_NOT_EMPTY", "--out already exists and is not an empty folder.",
                    fix: "Choose a new or empty folder.")
            }
            empty = true
        }
        let prefix = home.home + "/"
        return Destination(
            path: path, display: path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
            replacesEmptyDirectory: empty)
    }

    /// `20261020-170000`, UTC.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
