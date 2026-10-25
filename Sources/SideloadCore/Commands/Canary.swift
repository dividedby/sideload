import Foundation

/// Options for `canary`.
public struct CanaryOptions: Sendable, Equatable {
    public var device: String?
    /// Owner confirmation (design section 8); agents must not pass it.
    public var yes: Bool
    /// Leave the canary installed.
    public var keep: Bool
    /// Write an evidence bundle for a `blocked` or `error` result (opt-in; never automatic).
    public var evidence: Bool

    public init(device: String? = nil, yes: Bool = false, keep: Bool = false, evidence: Bool = false) {
        self.device = device
        self.yes = yes
        self.keep = keep
        self.evidence = evidence
    }
}

/// `canary`: build, sign and install a capability-free app with the paid team to see whether Apple has fixed
/// the 0xe8008018 install block (design section 10). The owner
/// has confirmed it creates a portal App ID and development profile and may register the device;
/// sideload never deletes portal objects, and it uninstalls only `<prefix>.sideload.canary`, only when this
/// run added it. `ok` is true for both `working` and `blocked`.
public enum CanaryCommand {
    static let command = "canary"
    static let buildTimeout = Duration.seconds(10 * 60)
    static let buildOutputCap = 128 * 1024 * 1024

    /// The repo's `canary/Canary.xcodeproj`, located from this source file. A packaged app will need to carry its own copy.
    static let defaultProject: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("canary/Canary.xcodeproj").path
    }()

    static let fixes: [String: String] = [
        "PRECHECK_FAILED": "Run `sideload doctor` and fix the failing checks.",
        "SNAPSHOT_FAILED": "Unlock the device, keep it connected, and retry.",
        "BUILD_FAILED":
            "Check that Xcode holds the paid-team account (Settings > Accounts) and the device is registered, then retry.",
        "OUTPUT_LIMIT": "Retry; if it repeats, run the command by hand to see what is flooding the output.",
        "BUILD_TIMEOUT": "Retry; if it repeats, open the project in Xcode once to see the signing error.",
        "BUILD_PRODUCT_MISSING": "The build reported success but produced no app; retry.",
        "GUARD_FAILED": "The built app is unsigned or has no embedded profile; check automatic signing for the paid team.",
        "WRONG_TEAM": "The build was not signed by team \(Team.id). Nothing was installed.",
        "FREE_TEAM_SELECTED":
            "The build was signed by the free team. Nothing was installed; check DEVELOPMENT_TEAM resolves to \(Team.id).",
        "DEVICE_NOT_IN_PROFILE":
            "The profile does not include this device. Register it in Xcode (build once from the IDE) and retry.",
        "TIMEOUT": "Retry with the device unlocked and connected.",
        "DEVICE_LOCKED": "Unlock the device and retry.",
        "DEVICE_NOT_CONNECTED": "Connect the device by USB and retry.",
        "DISK_FULL": "Free storage on the device and retry.",
        "DEVICE_NOT_PAIRED": FreeInstallClassifier.pairFix,
        "UNTRUSTED_DEVELOPER": FreeInstallClassifier.trustFix,
    ]

    static func fix(for code: String) -> String {
        fixes[code] ?? "See logs/canary-install-*.json for the scrubbed devicectl output."
    }

    static func isValidPrefix(_ prefix: String) -> Bool {
        prefix.wholeMatch(of: /[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*/) != nil
    }

    static func warning(_ code: String, _ message: String, _ fix: String) -> JSONValue {
        ["code": .string(code), "message": .string(message), "fix": .string(fix)]
    }

    public static func run(_ services: Services, _ options: CanaryOptions) async -> Envelope {
        do {
            return try await execute(services, options)
        } catch {
            return .from(error, command: command)
        }
    }

    private static func execute(_ services: Services, _ options: CanaryOptions) async throws -> Envelope {
        guard let alias = options.device, !alias.isEmpty else {
            return .fail(
                command, code: "USAGE", message: "canary needs --device <alias>.",
                fix: "sideload canary --device iphone --yes")
        }
        let config = try services.store.load()
        guard let prefix = config.bundleIdPrefix, isValidPrefix(prefix) else {
            return .fail(
                command, code: "CONFIG_MISSING", message: "bundleIdPrefix is missing or invalid in config.json.",
                fix:
                    "Add \"bundleIdPrefix\": \"com.yourname\" to $SIDELOAD_HOME/config.json. It becomes portal-visible (App ID <prefix>.sideload.canary).")
        }
        let dev = try config.requireDevice(alias)
        let bundleId = prefix + ".sideload.canary"
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED",
                message:
                    "The canary has portal side effects: Xcode will create the App ID and a development profile for the canary bundle ID in the paid team, and may register this device. It then installs and removes the canary on the device.",
                fix: "The owner confirms by re-running with --yes. Agents must not pass --yes on their own.",
                data: ["bundleId": .string(bundleId), "device": .string(alias)])
        }
        guard let udid = dev.udid, !udid.isEmpty else {
            return .fail(
                command, code: "DEVICE_NOT_SAVED", message: "The saved device has no UDID, which the profile guard needs.",
                fix: "Re-save it: sideload device save --alias <alias> --match <device name> --platform ios --yes")
        }

        let lock = try OperationLock.acquire(paths: services.home)
        defer { lock.release() }
        var run = CanaryRun(
            services: services, options: options, config: config, alias: alias, udid: udid, bundleId: bundleId)
        return try await run.execute()
    }
}

/// One canary run: the state shared by its steps.
private struct CanaryRun {
    let services: Services
    let options: CanaryOptions
    let config: Config
    let alias: String
    let udid: String
    let bundleId: String

    let started: Date
    var guardRecord = "skipped"
    var xcodeVersion: String?
    var before: [String]?
    var after: [String]?
    var warnings: [JSONValue] = []

    /// The keychain's selected paid certificate, read once at the start (log and evidence).
    var signingCert: KeychainCertificate?
    /// Common names of every identity the keychain read returned, for redaction only. Never printed.
    var identityNames: [String] = []
    var guardFacts: Guard.Facts?
    var installOutcome: Outcome?
    var installCode: String?
    /// One `devicectl list devices` per run, fetched lazily and only after the guard passed.
    var listedMemo: [ListedDevice]??
    /// The scrubbed devicectl document for the local log (`canary-install-*.json`); never used by the evidence bundle.
    var scrubbedLogMemo: JSONValue?

    init(services: Services, options: CanaryOptions, config: Config, alias: String, udid: String, bundleId: String) {
        self.services = services
        self.options = options
        self.config = config
        self.alias = alias
        self.udid = udid
        self.bundleId = bundleId
        started = services.clock.now()
    }

    /// What a `devicectl` call came to. An `OUTPUT_LIMIT` throw becomes a failed result: after the install
    /// step it must never skip the snapshot, cleanup or log.
    struct Outcome {
        var code: Int32?
        var json: JSONValue?
        var stderr = ""
        var timedOut = false
        var overflow = false
    }

    private func devicectl(_ args: [String], timeoutSec: Int, positional: [String] = []) async throws -> Outcome {
        do {
            let res = try await services.deviceCtl.run(
                args, deviceAlias: alias, timeoutSec: timeoutSec, positional: positional)
            return Outcome(code: res.code, json: res.json, stderr: res.stderr, timedOut: res.timedOut)
        } catch let error as SideloadError where error.code == "OUTPUT_LIMIT" {
            // Only the output-limit failure is a device outcome; an unsaved device or a wrapper misuse still throws.
            return Outcome(overflow: true)
        }
    }

    private func snapshot() async throws -> [String]? {
        let res = try await devicectl(["device", "info", "apps"], timeoutSec: 60)
        guard res.code == 0, let json = res.json else { return nil }
        var ids = Set<String>()
        func visit(_ v: JSONValue) {
            switch v {
            case .array(let items): items.forEach(visit)
            case .object(let fields):
                if case .string(let id)? = fields["bundleIdentifier"] { ids.insert(id) }
                fields.values.forEach(visit)
            default: break
            }
        }
        visit(json)
        return ids.sorted()
    }

    private func uninstall() async throws -> Bool {
        let un = try await devicectl(["device", "uninstall", "app"], timeoutSec: 60, positional: [bundleId])
        return un.code == 0
    }

    private func log(_ message: String) { services.log(message) }

    mutating func execute() async throws -> Envelope {
        // The certificate the keychain would offer Xcode, for the log and the evidence bundle (read-only).
        let now = services.clock.now()
        let identities = (try? services.keychain.developmentIdentities()) ?? []
        signingCert = CertCheck.selectedPaid(identities, now: now)
        identityNames = identities.compactMap(\.commonName)

        // 1. Preflight: cert + this device (a failing check stops everything before any build).
        log("canary: preflight")
        let checks =
            await Doctor.runCheck(CertificateCheck(), services)
            + Doctor.runCheck(DeviceCheck(aliases: [alias]), services)
        let failed = checks.filter { $0.severity == .fail }
        if !failed.isEmpty {
            return try await finish(
                .error, "PRECHECK_FAILED", "Preflight failed: \(failed.map(\.message).joined(separator: " "))",
                extra: ["checks": .array(checks.map(\.json))])
        }
        xcodeVersion = await XcodeCheck.versionLabel(runner: services.runner)

        // 2. Snapshot before.
        log("canary: snapshot before")
        guard let before = try await snapshot() else {
            return try await finish(.error, "SNAPSHOT_FAILED", "Could not list apps on the device.")
        }
        self.before = before

        // 3. Build.
        log("canary: building (up to 10 minutes)")
        let derived = services.home.builds + "/canary"
        let build = await services.runner.run(
            CommandSpec(
                executable: "xcodebuild",
                args: [
                    "-project", services.canaryProject ?? CanaryCommand.defaultProject,
                    "-scheme", "Canary",
                    "-configuration", "Debug",
                    "-destination", "id=\(udid)",
                    "-derivedDataPath", derived,
                    "-allowProvisioningUpdates",
                    "CODE_SIGN_STYLE=Automatic",
                    "DEVELOPMENT_TEAM=\(Team.id)",
                    "CODE_SIGN_IDENTITY=Apple Development",
                    "PRODUCT_BUNDLE_IDENTIFIER=\(bundleId)",
                    "build",
                ],
                timeout: CanaryCommand.buildTimeout, maxOutputBytes: CanaryCommand.buildOutputCap))
        if let failure = BuildClassifier.classify(
            .init(
                exitCode: build.code, stderr: build.stderr, stdout: build.stdout, timedOut: build.timedOut,
                overflow: build.overflow, spawnError: build.spawnError))
        {
            return try await finish(failure.status, failure.code, failure.reason)
        }
        let app = derived + "/Build/Products/Debug-iphoneos/Canary.app"
        guard followsToExisting(app) else {
            return try await finish(.error, "BUILD_PRODUCT_MISSING", "The build succeeded but Canary.app was not found.")
        }

        // 4. Guard: nothing touches the device unless team and profile check out.
        log("canary: pre-install guard")
        let guarded = await Guard.run(
            runner: services.runner, app: app, udid: udid, signingCert: signingCert?.reference)
        guardFacts = guarded.facts
        guardRecord = guarded.passed ? "passed" : "failed:\(guarded.code ?? "")"
        if !guarded.passed {
            return try await finish(.error, guarded.code ?? "GUARD_FAILED", guarded.reason ?? "")
        }

        // 5. Install.
        log("canary: installing")
        let install = try await devicectl(["device", "install", "app"], timeoutSec: 120, positional: [app])
        installOutcome = install

        // 6. Classify.
        let verdict = InstallClassifier.classify(
            .init(
                exitCode: install.code, json: install.json, stderr: install.stderr, timedOut: install.timedOut,
                overflow: install.overflow, guardPassed: true, bundleId: bundleId))
        installCode = verdict.code
        if verdict.status != .working {
            do {
                try await saveScrubbedInstall()
            } catch {
                warnings.append(
                    CanaryCommand.warning(
                        "LOG_WRITE_FAILED", "Could not save the scrubbed devicectl JSON.",
                        "Check permissions on $SIDELOAD_HOME/logs."))
            }
        }

        // 7. Cleanup: after a successful install, only if this run added the canary.
        var uninstallAttempted = false
        if verdict.status == .working && !options.keep && !before.contains(bundleId) {
            uninstallAttempted = true
            log("canary: uninstalling")
            if try await !uninstall() {
                warnings.append(
                    CanaryCommand.warning(
                        "CANARY_LEFT_ON_DEVICE", "Uninstalling \(bundleId) failed; the canary is still on the device.",
                        "Delete the Canary app from the device by hand."))
            }
        }

        // 8. Snapshot after.
        after = try await snapshot()
        if after == nil {
            warnings.append(
                CanaryCommand.warning(
                    "SNAPSHOT_FAILED", "Could not list apps after the install.", "Check the device manually."))
        }

        // 8b. A timed-out or ambiguous install can still land the canary. If the exact canary bundle id is
        // now present and was not before, remove it (that id only) unless --keep.
        if let present = after, !before.contains(bundleId), present.contains(bundleId), !options.keep,
            !uninstallAttempted
        {
            log("canary: removing canary left by an ambiguous install")
            if try await uninstall() {
                warnings.append(
                    CanaryCommand.warning(
                        "CANARY_REMOVED_AFTER_AMBIGUOUS_INSTALL",
                        "The install reported \"\(verdict.code)\" but \(bundleId) was present on the device; it was uninstalled.",
                        "No action needed."))
                after = try await snapshot() ?? present.filter { $0 != bundleId }
            } else {
                warnings.append(
                    CanaryCommand.warning(
                        "CANARY_LEFT_ON_DEVICE",
                        "\(bundleId) is on the device after an ambiguous install and uninstalling it failed.",
                        "Delete the Canary app from the device by hand."))
            }
        }

        // 9. Log + result.
        return try await finish(verdict.status, verdict.code, verdict.reason)
    }

    /// `stat`, not `lstat`: a symlinked app counts when its target exists and a dangling one does not.
    private func followsToExisting(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0
    }

    /// Fetched at most once per run, and only after the guard passed (a failed guard stays at two `xcrun` calls).
    private mutating func listedDevices() async -> [ListedDevice]? {
        if let memo = listedMemo { return memo }
        guard guardRecord == "passed" else { return nil }
        let listed = (try? await services.deviceCtl.listDevicesForScrubbing()) ?? nil
        listedMemo = .some(listed)
        return listed
    }

    /// Who and what must not appear in the saved install JSON or the evidence bundle.
    private mutating func subjects() async -> EvidenceSubjects {
        let user = services.localUser
        let machine = services.machineNames()
        let home = user.homeDirectory.isEmpty ? "" : URL(fileURLWithPath: user.homeDirectory).lastPathComponent
        return EvidenceSubjects(
            ids: [udid] + [config.devices[alias]?.coreDeviceId].compactMap { $0 },
            names: InstallScrubber.literals(config: config, listed: await listedDevices()), login: user.login,
            fullName: user.fullName, identityNames: identityNames,
            computerName: user.computerName.isEmpty ? machine.computerName : user.computerName,
            localHostName: user.localHostName.isEmpty ? machine.localHostName : user.localHostName,
            homeName: home.isEmpty || home == "/" ? nil : home)
    }

    /// The install's devicectl JSON for the local log, with names, hostnames, IDs, the person and the signing
    /// identities masked (a denylist, so good enough for a file that never leaves this Mac). Computed once.
    private mutating func scrubbedInstallLog() async -> JSONValue {
        if let memo = scrubbedLogMemo { return memo }
        let subjects = InstallLogScrubber.Subjects(await subjects())
        let result = InstallLogScrubber.document(
            InstallScrubber.scrubbed(installOutcome?.json, literals: subjects.nameLiterals), subjects)
        scrubbedLogMemo = result
        return result
    }

    private func stamp() -> String {
        ProgressLog.isoTimestamp(services.clock.now()).replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Saves the first non-working install's devicectl JSON, scrubbed. Later runs save nothing.
    private mutating func saveScrubbedInstall() async throws {
        let logs = services.home.logs
        try makeDirectories(logs, mode: 0o700)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: logs)) ?? []
        if existing.contains(where: { $0.hasPrefix("canary-install-") }) { return }
        let scrubbed = await scrubbedInstallLog()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(
            try encoder.encode(scrubbed) + Data("\n".utf8), to: "\(logs)/canary-install-\(stamp()).json")
    }

    /// `/usr/bin/sw_vers` output for the macOS version and build; nil when empty or not shaped like one.
    private func macOS() async -> (version: String?, build: String?) {
        func ask(_ flag: String) async -> String? {
            let res = await services.runner.run(
                CommandSpec(executable: "/usr/bin/sw_vers", args: [flag], timeout: .seconds(10)))
            guard res.code == 0 else { return nil }
            let text = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return (
            DeviceList.validVersion(await ask("-productVersion")), DeviceList.validBuild(await ask("-buildVersion"))
        )
    }

    /// The saved device's OS from the memoized listing; nil unless the guard passed.
    private mutating func iOS() async -> (version: String?, build: String?) {
        guard let saved = config.devices[alias],
            let device = DeviceList.findSaved(await listedDevices() ?? [], matching: saved)
        else { return (nil, nil) }
        return (device.osVersion, device.osBuild)
    }

    private static func clip(_ s: String, _ limit: Int = 64) -> String { String(s.prefix(limit)) }

    /// Reduces, builds, verifies and writes the bundle. Failures are warnings; the canary result never changes.
    private mutating func writeEvidence(
        _ status: Classification.Status, _ code: String, _ reason: String, durationMs: Int,
        macos: (version: String?, build: String?), ios: (version: String?, build: String?)
    ) async -> JSONValue {
        let none: JSONValue = ["written": false, "dir": .null, "files": []]
        guard status != .working else { return none }
        let tokens = SubjectTokens.make(await subjects())
        var install: EvidenceInput.Install?
        if let outcome = installOutcome {
            install = .init(
                classification: installCode, exitCode: outcome.code, timedOut: outcome.timedOut,
                reduction: ErrorChain.reduce(
                    json: outcome.json, stderr: outcome.stderr, tokens: tokens, bundleId: bundleId))
        }
        let input = EvidenceInput(
            generatedAt: services.clock.now(), status: status.rawValue, code: code,
            reason: MessageFilter.admit(reason, tokens: tokens, bundleId: bundleId), guardRecord: guardRecord,
            durationMs: durationMs, bundleId: bundleId, macosVersion: macos.version, macosBuild: macos.build,
            xcode: xcodeVersion, iosVersion: ios.version, iosBuild: ios.build, certificate: signingCert?.info,
            certFp: signingCert.map { EvidenceBuilder.certFp($0.reference) }, guardFacts: guardFacts,
            deviceTail4: Redactor.tail4(udid), install: install, appleCase: config.appleSupportCase)
        switch EvidenceWriter.write(
            EvidenceBuilder.build(input), stamp: stamp(), home: services.home, tokens: tokens, bundleId: bundleId)
        {
        case .written(let dir, let files):
            return ["written": true, "dir": .string(dir), "files": .array(files.map(JSONValue.string))]
        case .redactionFailed:
            warnings.append(
                CanaryCommand.warning(
                    "EVIDENCE_REDACTION_FAILED",
                    "The evidence bundle was not written: a final check found text that must not be in it.",
                    "The canary result is unaffected. Report this; do not attach anything by hand."))
        case .writeFailed:
            warnings.append(
                CanaryCommand.warning(
                    "EVIDENCE_WRITE_FAILED", "Could not write the evidence bundle.",
                    "Check that $SIDELOAD_HOME/evidence is writable and that this run's folder does not already exist."))
        }
        return none
    }

    /// Computes the delta, appends the `canary.jsonl` line, and builds the envelope.
    private mutating func finish(
        _ status: Classification.Status, _ code: String, _ reason: String, extra: [String: JSONValue] = [:]
    ) async throws -> Envelope {
        let durationMs = Int((services.clock.now().timeIntervalSince(started) * 1000).rounded())
        var delta: (added: [String], removed: [String])?
        if let before, let after {
            delta = (after.filter { !before.contains($0) }, before.filter { !after.contains($0) })
        }
        if let delta {
            let allowedAdd = options.keep && status == .working ? [bundleId] : []
            let unexpected = delta.added.filter { !allowedAdd.contains($0) }
            if !unexpected.isEmpty || !delta.removed.isEmpty {
                warnings.append(
                    CanaryCommand.warning(
                        "unexpected-app-delta",
                        "The device app list changed in a way the canary did not cause. Nothing was done about it.",
                        "Review `deviceDelta`; sideload never removes apps it did not install."))
            }
        }
        let macos = await macOS()
        let ios = guardRecord == "passed" ? await iOS() : (version: String?.none, build: String?.none)
        do {
            let line: JSONValue = [
                "ts": .string(ProgressLog.isoTimestamp(services.clock.now())), "status": .string(status.rawValue),
                "code": .string(Self.clip(code)), "device": .string(Redactor.tail4(udid)),
                "xcodeVersion": xcodeVersion.map { .string(Self.clip($0)) } ?? .null, "guard": .string(Self.clip(guardRecord)),
                "durationMs": .number(Double(durationMs)),
                "macosVersion": macos.version.map(JSONValue.string) ?? .null,
                "iosVersion": ios.version.map(JSONValue.string) ?? .null,
                "certFp": signingCert.map { .string(EvidenceBuilder.certFp($0.reference)) } ?? .null,
                "certNotAfter": signingCert?.info.notAfter.map { .string(CertCheck.isoDate($0)) } ?? .null,
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try makeDirectories(services.home.logs, mode: 0o700)
            try AppendFile.appendLine(String(decoding: try encoder.encode(line), as: UTF8.self), to: services.home.canaryLog)
        } catch {
            warnings.append(
                CanaryCommand.warning(
                    "LOG_WRITE_FAILED", "Could not append to logs/canary.jsonl.",
                    "Check permissions on $SIDELOAD_HOME/logs."))
        }
        var evidence: JSONValue?
        if options.evidence {
            evidence = await writeEvidence(status, code, reason, durationMs: durationMs, macos: macos, ios: ios)
        }
        var data: [String: JSONValue] = [
            "status": .string(status.rawValue), "code": .string(code), "reason": .string(reason),
            "bundleId": .string(bundleId), "device": .string(alias),
            "deviceDelta": delta.map { .array($0.added.map(JSONValue.string)) } ?? .null,
            "deviceRemoved": delta.map { .array($0.removed.map(JSONValue.string)) } ?? .null,
            "guard": .string(guardRecord), "xcodeVersion": xcodeVersion.map(JSONValue.string) ?? .null,
            "durationMs": .number(Double(durationMs)), "warnings": .array(warnings),
        ]
        // Only with --evidence, so a run without the flag keeps exactly the pre-evidence envelope.
        data["evidence"] = evidence
        data.merge(extra) { _, new in new }
        if status == .error {
            return .fail(CanaryCommand.command, code: code, message: reason, fix: CanaryCommand.fix(for: code), data: data)
        }
        return .result(CanaryCommand.command, data)
    }
}
