import Darwin
import Foundation
import Security
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// export-cert over fakes only: no keychain, no pasteboard, no ~/Library profiles, no ~/.sideload. Every ID is built
// at runtime. The "p12" is synthetic bytes holding the OIDs the inspector looks for.

private let pkcsArc: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01]

private func p12Bytes(legacy: Bool) -> Data {
    func oid(_ tail: [UInt8]) -> [UInt8] { [0x06, UInt8(pkcsArc.count + tail.count)] + pkcsArc + tail }
    let body = legacy ? oid([0x0C, 0x01, 0x03]) + oid([0x0C, 0x01, 0x06]) : oid([0x05, 0x0D])
    return Data([0x30, 0x82, 0x01, 0x00] + body + [0x04, 0x01, 0x00])
}

private let profileBytes = Data("fake signed profile bytes".utf8)
private let altBytes = Data("another profile".utf8)

/// A secret store that has nothing but cannot add (the read succeeds with "no item").
private final class AddFailingSecretStore: SecretStore {
    func readPassword() throws -> String? { nil }
    func addPassword(_ password: String) throws { throw KeychainFailure.passwordStoreFailed(errSecInteractionNotAllowed) }
}

/// A thread that calls `trip()` in a tight loop, started at most once.
private final class Racer: Sendable {
    private let signal: HoldSignal
    private let stop = Mutex(false)
    private let started = Mutex(false)
    private let finished = Mutex(false)

    init(_ signal: HoldSignal) { self.signal = signal }

    func start(firstSync: Bool, jitter: UInt32 = 0) {
        guard started.withLock({ s in
            defer { s = true }
            return !s
        }) else { return }
        if firstSync { _ = signal.trip() }
        Thread { [self] in
            usleep(jitter)
            while !stop.withLock({ $0 }) { _ = signal.trip() }
            finished.withLock { $0 = true }
        }.start()
    }

    func join() async {
        stop.withLock { $0 = true }
        guard started.withLock({ $0 }) else { return }
        while !finished.withLock({ $0 }) { await Task.yield() }
    }
}

/// The dispositions `trip()` returned, in order.
private final class Trips: Sendable {
    private let results = Mutex<[HoldSignal.Disposition]>([])
    var all: [HoldSignal.Disposition] { results.withLock { $0 } }
    func fire(_ signal: HoldSignal, _ count: Int) {
        for _ in 0..<count { results.withLock { $0.append(signal.trip()) } }
    }
}

private final class Recorder: Sendable {
    private let lines = Mutex<[String]>([])
    private let sleeps = Mutex<[Duration]>([])
    private let order = Mutex<[String]>([])

    func log(_ line: String) { lines.withLock { $0.append(line) } }
    func slept(_ d: Duration) { sleeps.withLock { $0.append(d) } }
    func event(_ name: String) { order.withLock { $0.append(name) } }
    var logged: [String] { lines.withLock { $0 } }
    var sleepsRequested: [Duration] { sleeps.withLock { $0 } }
    var events: [String] { order.withLock { $0 } }
}

private struct Snapshot {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var modes: [String: Int] = [:]

    func children(of dir: String) -> [String] {
        let prefix = dir.isEmpty ? "" : dir + "/"
        let all = Set(files.keys).union(directories)
        return all.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") && $0 != dir }.sorted()
    }

    var allText: [String: String] { files.mapValues { String(decoding: $0, as: UTF8.self) } }
}

private func snapshot(_ home: String) -> Snapshot {
    var snap = Snapshot()
    let walker = FileManager.default.enumerator(atPath: home)
    while let rel = walker?.nextObject() as? String {
        if rel == "tmp" || rel.hasPrefix("tmp/") { continue }
        let full = home + "/" + rel
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
        snap.modes[rel] = modeOf(full)
        if isDir.boolValue {
            snap.directories.insert(rel)
        } else if let data = FileManager.default.contents(atPath: full) {
            snap.files[rel] = data
        }
    }
    return snap
}

private struct World {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var snap: Snapshot
    var paths: Paths
    var recorder: Recorder
    var exporter: FakeIdentityExporter
    var secrets: any SecretStore
    var verifier: FakeP12Verifier
    var backend: FakePasteboardBackend
    var keychain: FakeKeychain
    var source: FakeProfileSource
    var runner: FakeRunner
    var ledger: Ledger?
    var ledgerText: String?
    var code: String? { envelope.errors.first?.code }
    var password: String? { exporter.calls.first?.password }

    func warningCodes() -> [String] { json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? [] }
    var kitDirs: [String] { snap.children(of: "exports").filter { $0.hasPrefix("exports/feather-") } }
    var strayTemps: [String] { snap.children(of: "exports").filter { $0.contains(".tmp") } }
    var p12Masters: [String] { snap.children(of: "secrets/p12") }
}

private struct Setup {
    var certs: [String] = [TestCerts.paid]
    var keychainFailure: (any Error)?
    /// Built from the paid certificate's reference when nil.
    var profiles: (([ProvisioningProfile], KeychainCertificate) -> [ProvisioningProfile])?
    var exporterOutcome: Result<Data, KeychainFailure> = .success(p12Bytes(legacy: true))
    var secrets: (any SecretStore)?
    var verifierReferences: [CertReference]?
    var verifierPassword: String?
    var seedLedger: String?
    var existingPassword: String?
    var hold: (@Sendable (Recorder, FakePasteboardBackend) async throws -> Void)?
    var exporterOnCall: (@Sendable (Recorder) -> Void)?
    var preflight: ((Paths) throws -> Void)?
    var ledgerStore: ((Paths) -> LedgerStore)?
    var home: ((Paths) -> Void)?
    var holdSignal: HoldSignal?
    var onLog: (@Sendable (String) -> Void)?
    var pasteboard: ((ConcealedClipboard) -> any SecretPasteboard)?
}

private func invoke(
    _ options: ExportCertOptions = ExportCertOptions(device: "iphone", yes: true), setup: Setup = Setup()
) async throws -> World {
    try await withTestHome(config: iphoneConfig()) { paths, _ in
        try await execute(paths, options, setup)
    }
}

private func execute(_ paths: Paths, _ options: ExportCertOptions, _ setup: Setup) async throws -> World {
    do {  // one scope for the scratch folder
        let scratch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paid = try keychainCert(TestCerts.paid)
        let recorder = Recorder()
        if let seed = setup.seedLedger { try Data(seed.utf8).write(to: URL(fileURLWithPath: paths.ledger)) }
        try setup.preflight?(paths)

        var profiles = [paidProfile(certs: [paid.reference])]
        if let make = setup.profiles { profiles = make(profiles, paid) }
        // Each profile's original signed bytes live in a scratch file, as in Xcode's folder.
        profiles = try profiles.enumerated().map { i, p in
            var p = p
            let file = scratch.appendingPathComponent("p\(i).mobileprovision")
            try (i == 0 ? profileBytes : altBytes).write(to: file)
            p.file = file.path
            return p
        }

        let keychain = FakeKeychain(try setup.certs.map { try keychainCert($0) }, failure: setup.keychainFailure)
        let source = FakeProfileSource(profiles)
        var onCall: (@Sendable () -> Void)?
        if let hook = setup.exporterOnCall { onCall = { hook(recorder) } }
        let exporter = FakeIdentityExporter(setup.exporterOutcome, onCall: onCall)
        let secrets: any SecretStore = setup.secrets ?? FakeSecretStore(password: setup.existingPassword)
        let verifier = FakeP12Verifier(
            references: setup.verifierReferences ?? [CertReference(paid.reference)!], expectedPassword: setup.verifierPassword)
        let backend = FakePasteboardBackend()
        var (services, runner) = fakeServices(paths, keychain: keychain)
        services.profiles = source
        services.identityExporter = exporter
        services.secrets = secrets
        services.p12Verifier = verifier
        let clipboard = ConcealedClipboard(backend: backend)
        services.pasteboard = setup.pasteboard?(clipboard) ?? clipboard
        let onLog = setup.onLog
        services.log = {
            recorder.log($0)
            onLog?($0)
        }
        if let signal = setup.holdSignal { services.holdSignal = signal }
        let hold = setup.hold
        services.sleep = { duration in
            recorder.slept(duration)
            recorder.event("sleep")
            try await hold?(recorder, backend)
        }
        setup.home?(paths)
        let ledgerStore = setup.ledgerStore?(paths)
        let envelope = await ExportCertCommand.run(services, options, ledgerStore: ledgerStore)
        let (text, json) = try envelope.printed()
        return World(
            envelope: envelope, text: text, json: json, snap: snapshot(paths.home), paths: paths, recorder: recorder,
            exporter: exporter, secrets: secrets, verifier: verifier, backend: backend, keychain: keychain, source: source,
            runner: runner, ledger: try? LedgerStore(paths: paths).load(),
            ledgerText: try? String(contentsOfFile: paths.ledger, encoding: .utf8))
    }
}

private func fp8(_ cert: String) throws -> String { LedgerSync.fp8(try keychainCert(cert).reference) }

@Suite("export-cert")
struct ExportCertTests {
    // MARK: usage and confirmation

    @Test("without --yes nothing is read, asked, written or copied")
    func confirmRequired() async throws {
        let w = try await invoke(ExportCertOptions(device: "iphone", copyPassword: true))
        #expect(w.code == "CONFIRM_REQUIRED" && !w.envelope.ok)
        #expect(w.json["device"] == "iphone" && w.json["copyPassword"] == true)
        let effects = w.json["effects"]?.array?.compactMap(\.string) ?? []
        #expect(effects.count == 5 && effects.contains { $0.contains("clipboard") })
        #expect(w.keychain.readCount == 0 && w.source.readCount == 0)
        #expect(w.exporter.calls.isEmpty && w.verifier.callCount == 0)
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.reads == 0)
        #expect((w.secrets as? FakeSecretStore)?.events == [])
        #expect(w.recorder.sleepsRequested.isEmpty && w.recorder.logged.isEmpty)
        #expect(w.ledgerText == nil && w.p12Masters.isEmpty && w.snap.children(of: "exports").isEmpty)
        #expect(w.runner.calls.isEmpty)
    }

    @Test("usage errors come before anything else")
    func usageErrors() async throws {
        for options in [
            ExportCertOptions(yes: true), ExportCertOptions(device: "", yes: true),
            ExportCertOptions(device: "iphone", profile: "not-a-uuid", yes: true),
            ExportCertOptions(device: "iphone", out: "", yes: true),
        ] {
            let w = try await invoke(options)
            #expect(w.code == "USAGE", "\(options)")
            #expect(w.keychain.readCount == 0 && w.exporter.calls.isEmpty)
        }
    }

    @Test("an unsaved alias is DEVICE_NOT_SAVED")
    func unsavedAlias() async throws {
        let w = try await invoke(ExportCertOptions(device: "nope", yes: true))
        #expect(w.code == "DEVICE_NOT_SAVED")
        #expect(w.keychain.readCount == 0 && w.exporter.calls.isEmpty)
    }

    @Test("a second concurrent run is OPERATION_IN_PROGRESS and touches nothing")
    func operationLocked() async throws {
        var held: OperationLock?
        var setup = Setup()
        setup.preflight = { held = try OperationLock.acquire(paths: $0) }
        let w = try await invoke(setup: setup)
        withExtendedLifetime(held) {}
        #expect(w.code == "OPERATION_IN_PROGRESS")
        #expect(w.keychain.readCount == 0 && w.exporter.calls.isEmpty)
    }

    // MARK: the happy path

    @Test("exports, verifies, records and writes the kit")
    func happyPath() async throws {
        let w = try await invoke()
        #expect(w.envelope.ok, "\(w.text)")
        let id = try fp8(TestCerts.paid)
        let kit = try #require(w.kitDirs.first)
        #expect(w.kitDirs == ["exports/feather-20261019-120000"])
        #expect(w.json["kit"]?["path"] == .string(kit))

        // exactly the three files, 0600; folders 0700
        #expect(w.snap.children(of: kit) == ["\(kit)/README.txt", "\(kit)/sideload-dev.mobileprovision", "\(kit)/sideload-dev.p12"])
        for file in w.snap.children(of: kit) { #expect(w.snap.modes[file] == 0o600, "\(file)") }
        for dir in [kit, "exports", "secrets/p12", "secrets"] { #expect(w.snap.modes[dir] == 0o700, "\(dir)") }
        #expect(w.strayTemps.isEmpty)

        // the original signed profile bytes, the verified p12, and the master copy
        #expect(w.snap.files["\(kit)/sideload-dev.mobileprovision"] == profileBytes)
        #expect(w.snap.files["\(kit)/sideload-dev.p12"] == p12Bytes(legacy: true))
        let master = "secrets/p12/\(id)-20261019-120000.p12"
        #expect(w.p12Masters == [master] && w.snap.files[master] == p12Bytes(legacy: true) && w.snap.modes[master] == 0o600)

        // the exporter saw only the paid reference and the stored password
        let paid = try keychainCert(TestCerts.paid)
        #expect(w.exporter.calls.count == 1 && w.exporter.calls[0].reference.hex == paid.reference)
        let password = try #require(w.password)
        #expect(password.count == 24 && (w.secrets as? FakeSecretStore)?.stored == password)
        #expect(w.verifier.callCount == 1)

        // envelope
        #expect(w.json["command"] == "export-cert")
        #expect(w.json["certificate"]?["fp8"] == .string(id))
        #expect(w.json["certificate"]?["team"] == "7AGMPUPP64")
        #expect(w.json["certificate"]?["notAfter"] == "2027-10-16T22:39:42Z")
        #expect(w.json["certificate"]?["daysLeft"] == 362)
        #expect(w.json["profile"]?["wildcard"] == true && w.json["profile"]?["deviceIncluded"] == true)
        #expect(w.json["profile"]?["deviceCount"] == 1 && w.json["profile"]?["daysLeft"] == 335)
        #expect(w.json["p12"]?["encryption"] == "pkcs12-3des+pkcs12-rc2-40")
        #expect(w.json["p12"]?["file"] == .string(master))
        #expect(w.json["p12"]?["sha256Prefix"]?.string?.count == 8)
        #expect(w.json["passwordItem"] == ["service": "io.github.dividedby.sideload", "account": "p12", "reused": false])
        #expect(w.json["passwordCopied"] == false && w.json["clipboardCleared"] == nil)
        #expect(w.warningCodes() == ["P12_LEGACY_ENCRYPTION"])
        #expect(w.runner.calls.isEmpty, "profiles and the keychain come from the fakes; no subprocess")
        #expect(w.backend.snapshot.reads == 0 && w.backend.snapshot.contents == nil, "the pasteboard is untouched")
        #expect(w.recorder.sleepsRequested.isEmpty)

        // ledger
        let ledger = try #require(w.ledger)
        #expect(ledger.exports.count == 1)
        let export = ledger.exports[0]
        #expect(export.id == "export-20261019-120000" && export.certFp8 == id && export.profileUuid == w.ledger?.profiles.first?.uuid)
        #expect(export.p12File == master && export.p12Sha256Prefix == w.json["p12"]?["sha256Prefix"]?.string)
        #expect(export.encryption == "pkcs12-3des+pkcs12-rc2-40" && export.passwordItem == "keychain")
        #expect(export.kitPath == kit && export.verified)
        #expect(ledger.certificates.map(\.fp8) == [id] && ledger.certificates[0].present)
        #expect(ledger.profiles.count == 1 && ledger.profiles[0].present)
        #expect(w.snap.modes["ledger.json"] == 0o600)
    }

    @Test("a PBES2 p12 raises no legacy warning")
    func modernEncryption() async throws {
        var setup = Setup()
        setup.exporterOutcome = .success(p12Bytes(legacy: false))
        let w = try await invoke(setup: setup)
        #expect(w.envelope.ok && w.json["p12"]?["encryption"] == "pbes2")
        #expect(w.warningCodes().isEmpty)
        let readme = try #require(w.snap.allText["\(w.kitDirs[0])/README.txt"])
        #expect(!readme.contains("Legacy encryption"))
    }

    @Test("the password item is added before the key leaves the keychain")
    func addBeforeExport() async throws {
        var setup = Setup()
        let store = FakeSecretStore()
        setup.secrets = store
        setup.exporterOnCall = { recorder in
            recorder.event(store.stored == nil ? "export-before-add" : "export-after-add")
        }
        let w = try await invoke(setup: setup)
        #expect(w.envelope.ok)
        #expect(w.recorder.events == ["export-after-add"])
        #expect(store.events.count == 2 && store.events[0] == .read)
    }

    @Test("an existing password is reused, never overwritten")
    func reusesPassword() async throws {
        var setup = Setup()
        setup.existingPassword = "ABCD-EFGH-JKMN-PQRS-TVWX"
        setup.verifierPassword = "ABCD-EFGH-JKMN-PQRS-TVWX"
        let w = try await invoke(setup: setup)
        #expect(w.envelope.ok)
        #expect(w.password == "ABCD-EFGH-JKMN-PQRS-TVWX")
        #expect((w.secrets as? FakeSecretStore)?.events == [.read])
        #expect(w.json["passwordItem"]?["reused"] == true)
    }

    @Test("the kit README: import steps, password sources, dates, no secrets")
    func readme() async throws {
        let w = try await invoke()
        let kit = try #require(w.kitDirs.first)
        let readme = try #require(w.snap.allText["\(kit)/README.txt"])
        for must in [
            "Feather", "Certificates", "sideload-dev.p12", "sideload-dev.mobileprovision", "--copy-password",
            "io.github.dividedby.sideload", "\"p12\"", "Keychain Access", "90 seconds", "Legacy encryption", "3DES and RC2-40",
            "expires 2027-10-16", try fp8(TestCerts.paid),
        ] {
            #expect(readme.contains(must), "README lacks \(must)")
        }
        let profileExpiry = CertCheck.isoDate(daysFromNow(335))
        #expect(readme.contains("Profile expires \(profileExpiry)"))
        let password = try #require(w.password)
        #expect(!readme.contains(password) && !readme.contains("/Users") && !readme.contains(savedUdid("1")))
        #expect(!readme.contains("Test 00000") && !readme.contains(w.paths.home))
    }

    @Test("an explicit-only profile warns PROFILE_NOT_WILDCARD and the README says so")
    func explicitProfile() async throws {
        var setup = Setup()
        setup.profiles = { _, paid in
            [paidProfile(applicationIdentifier: Team.id + ".io.example.app", certs: [paid.reference])]
        }
        let w = try await invoke(setup: setup)
        #expect(w.envelope.ok && w.warningCodes() == ["P12_LEGACY_ENCRYPTION", "PROFILE_NOT_WILDCARD"])
        #expect(w.json["profile"]?["wildcard"] == false)
        #expect(w.snap.allText["\(w.kitDirs[0])/README.txt"]?.contains("not a wildcard") == true)
    }

    @Test("--profile selects that profile and its bytes")
    func profileOverride() async throws {
        let target = "AAAAAAAA-0000-0000-0000-000000000009"
        var setup = Setup()
        setup.profiles = { existing, paid in
            existing + [paidProfile(uuid: target, applicationIdentifier: Team.id + ".io.example.app", certs: [paid.reference])]
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", profile: target.lowercased(), yes: true), setup: setup)
        #expect(w.envelope.ok)
        #expect(w.snap.files["\(w.kitDirs[0])/sideload-dev.mobileprovision"] == altBytes)
        #expect(w.ledger?.exports.first?.profileUuid == target)
    }

    // MARK: --out

    @Test("--out an absent folder outside any repo, or an empty existing one")
    func outFolder() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let absent = base.appendingPathComponent("kit-a").path
        let a = try await invoke(ExportCertOptions(device: "iphone", out: absent, yes: true))
        #expect(a.envelope.ok && a.kitDirs.isEmpty)
        #expect(a.json["kit"]?["path"]?.string == resolvePath(absent))
        #expect(a.ledger?.exports.first?.kitPath == resolvePath(absent))
        #expect(listing(absent).sorted() == ["README.txt", "sideload-dev.mobileprovision", "sideload-dev.p12"])
        #expect(modeOf(absent) == 0o700 && modeOf(absent + "/sideload-dev.p12") == 0o600)
        #expect(listing(base.path) == ["kit-a"], "no temp folder left beside it")

        let empty = base.appendingPathComponent("kit-b").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: false)
        let b = try await invoke(ExportCertOptions(device: "iphone", out: empty, yes: true))
        #expect(b.envelope.ok && listing(empty).count == 3 && modeOf(empty) == 0o700)
    }

    @Test("--out that exists and is not empty, or is a file, is OUT_NOT_EMPTY and nothing is asked")
    func outNotEmpty() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let full = base.appendingPathComponent("full").path
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: full + "/keep.txt"))
        let file = base.appendingPathComponent("file").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        for out in [full, file, "/"] {
            let w = try await invoke(ExportCertOptions(device: "iphone", out: out, yes: true))
            #expect(w.code == "OUT_NOT_EMPTY", "\(out)")
            #expect(w.exporter.calls.isEmpty && (w.secrets as? FakeSecretStore)?.events == [])
        }
        #expect(listing(full) == ["keep.txt"])
    }

    @Test("--out inside a git work tree is OUT_IN_GIT_WORKTREE before any prompt")
    func outInGit() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(atPath: base.path + "/.git", withIntermediateDirectories: false)
        let w = try await invoke(ExportCertOptions(device: "iphone", out: base.path + "/deep/kit", yes: true))
        #expect(w.code == "OUT_IN_GIT_WORKTREE")
        #expect(w.exporter.calls.isEmpty && (w.secrets as? FakeSecretStore)?.events == [])
        #expect(listing(base.path) == [".git"])
    }

    // MARK: selection errors

    @Test("selection failures stop before the keychain is asked for anything")
    func selectionErrors() async throws {
        let paid = try keychainCert(TestCerts.paid)
        func fails(_ code: String, _ setup: Setup, _ options: ExportCertOptions = ExportCertOptions(device: "iphone", yes: true))
            async throws
        {
            let w = try await invoke(options, setup: setup)
            #expect(w.code == code, "\(code): \(w.text)")
            #expect(w.exporter.calls.isEmpty && w.verifier.callCount == 0)
            #expect((w.secrets as? FakeSecretStore)?.events == [], "\(code): password item untouched")
            #expect(w.kitDirs.isEmpty && w.p12Masters.isEmpty && w.ledgerText == nil)
        }
        var noCert = Setup()
        noCert.certs = [TestCerts.free, TestCerts.expired]
        try await fails("CERT_NOT_FOUND", noCert)
        var noProfile = Setup()
        noProfile.profiles = { _, _ in [] }
        try await fails("PROFILE_NOT_FOUND", noProfile)
        var noDevice = Setup()
        noDevice.profiles = { _, paid in [paidProfile(devices: [savedUdid("2")], certs: [paid.reference])] }
        try await fails("DEVICE_NOT_IN_PROFILE", noDevice)
        var mismatch = Setup()
        mismatch.profiles = { _, _ in [paidProfile(certs: [String(repeating: "A", count: 40)])] }
        try await fails("PROFILE_CERT_MISMATCH", mismatch)
        var unknown = Setup()
        unknown.profiles = nil
        try await fails(
            "PROFILE_NOT_FOUND", unknown,
            ExportCertOptions(device: "iphone", profile: "BBBBBBBB-0000-0000-0000-000000000001", yes: true))
        _ = paid
    }

    @Test("a free-team-only keychain never reaches the exporter")
    func freeTeamOnly() async throws {
        var setup = Setup()
        setup.certs = [TestCerts.free]
        let w = try await invoke(setup: setup)
        #expect(w.code == "CERT_NOT_FOUND" && w.exporter.calls.isEmpty)
    }

    @Test("the exporter is only ever called with the paid reference, even when the free cert is listed first")
    func exporterGetsPaidReference() async throws {
        var setup = Setup()
        setup.certs = [TestCerts.free, TestCerts.paid]
        let w = try await invoke(setup: setup)
        #expect(w.envelope.ok)
        #expect(w.exporter.calls.map(\.reference.hex) == [try keychainCert(TestCerts.paid).reference])
    }

    @Test("an unreadable keychain is KEYCHAIN_READ_FAILED")
    func keychainReadFailure() async throws {
        var setup = Setup()
        setup.keychainFailure = KeychainError("locked")
        let w = try await invoke(setup: setup)
        #expect(w.code == "KEYCHAIN_READ_FAILED" && w.exporter.calls.isEmpty)
    }

    @Test("a corrupt ledger stops before the profile read and the exporter, and is never echoed")
    func corruptLedger() async throws {
        var setup = Setup()
        setup.seedLedger = #"{"schema": 1, "secret-ish": "do-not-echo""#
        let w = try await invoke(setup: setup)
        #expect(w.code == "LEDGER_INVALID")
        #expect(!w.text.contains("do-not-echo"))
        #expect(w.keychain.readCount == 0 && w.source.readCount == 0 && w.exporter.calls.isEmpty)
        #expect(w.ledgerText == #"{"schema": 1, "secret-ish": "do-not-echo""#, "left alone")
    }

    // MARK: keychain failures

    @Test("each keychain failure has its own code, and leaves no p12, kit or ledger entry")
    func keychainFailures() async throws {
        let cases: [(KeychainFailure, String)] = [
            (.denied, "KEYCHAIN_DENIED"), (.promptTimeout, "KEYCHAIN_PROMPT_TIMEOUT"),
            (.notPaidTeam, "IDENTITY_NOT_PAID_TEAM"), (.notFound, "CERT_NOT_FOUND"),
            (.status(-1), "KEYCHAIN_READ_FAILED"), (.unavailable, "KEYCHAIN_UNAVAILABLE"),
        ]
        for (failure, code) in cases {
            var setup = Setup()
            setup.exporterOutcome = .failure(failure)
            let w = try await invoke(setup: setup)
            #expect(w.code == code, "\(failure)")
            #expect(w.exporter.calls.count == 1)
            #expect(w.kitDirs.isEmpty && w.strayTemps.isEmpty && w.p12Masters.isEmpty, "\(code): no partial output")
            #expect(w.ledger?.exports.isEmpty == true && w.ledgerText == nil, "\(code): ledger not written")
            #expect(w.backend.snapshot.reads == 0)
        }
    }

    @Test("password item failures: unreadable stops, a failed add stops before the export")
    func passwordFailures() async throws {
        var unreadable = Setup()
        unreadable.secrets = FakeSecretStore(failure: .passwordUnreadable(-25308))
        let u = try await invoke(setup: unreadable)
        #expect(u.code == "PASSWORD_UNREADABLE" && u.exporter.calls.isEmpty)

        var denied = Setup()
        denied.secrets = FakeSecretStore(failure: .denied)
        #expect(try await invoke(setup: denied).code == "KEYCHAIN_DENIED")

        var cannotAdd = Setup()
        cannotAdd.secrets = AddFailingSecretStore()
        let a = try await invoke(setup: cannotAdd)
        #expect(a.code == "PASSWORD_STORE_FAILED" && a.exporter.calls.isEmpty && a.p12Masters.isEmpty && a.kitDirs.isEmpty)
        #expect(a.envelope.errors[0].message.contains("OSStatus"))

        var emptyStored = Setup()
        emptyStored.existingPassword = ""
        let e = try await invoke(setup: emptyStored)
        #expect(e.code == "PASSWORD_UNREADABLE" && e.exporter.calls.isEmpty)
    }

    @Test("verification: a wrong password or a different identity is P12_VERIFY_FAILED and nothing is kept")
    func verifyFailures() async throws {
        var wrongPassword = Setup()
        wrongPassword.verifierPassword = "NOT-THE-GENERATED-ONE"
        let w = try await invoke(setup: wrongPassword)
        #expect(w.code == "P12_VERIFY_FAILED" && w.verifier.callCount == 1)
        #expect(w.kitDirs.isEmpty && w.p12Masters.isEmpty && w.ledgerText == nil)

        var otherIdentity = Setup()
        otherIdentity.verifierReferences = [CertReference(String(repeating: "B", count: 40))!]
        let o = try await invoke(setup: otherIdentity)
        #expect(o.code == "P12_VERIFY_FAILED" && o.kitDirs.isEmpty && o.p12Masters.isEmpty && o.ledgerText == nil)

        var empty = Setup()
        empty.verifierReferences = []
        #expect(try await invoke(setup: empty).code == "P12_VERIFY_FAILED")
    }

    @Test("a master with the same timestamp already there is EXPORT_EXISTS before any prompt")
    func exportExists() async throws {
        var setup = Setup()
        let name = try fp8(TestCerts.paid)
        setup.preflight = { paths in
            try makeDirectories(paths.p12Dir, mode: 0o700)
            try Data("old".utf8).write(to: URL(fileURLWithPath: "\(paths.p12Dir)/\(name)-20261019-120000.p12"))
        }
        let w = try await invoke(setup: setup)
        #expect(w.code == "EXPORT_EXISTS" && w.exporter.calls.isEmpty)
        #expect(w.snap.files["secrets/p12/\(name)-20261019-120000.p12"] == Data("old".utf8))
    }

    // MARK: ledger failures roll the export back

    @Test("a ledger that cannot be written fails with LEDGER_WRITE_FAILED and leaves no kit or p12")
    func ledgerWriteFailure() async throws {
        var setup = Setup()
        setup.ledgerStore = { paths in
            LedgerStore(paths: paths) { _, _ in throw SideloadError("IO_ERROR", "disk") }
        }
        let w = try await invoke(setup: setup)
        #expect(w.code == "LEDGER_WRITE_FAILED")
        #expect(w.exporter.calls.count == 1)
        #expect(w.kitDirs.isEmpty && w.strayTemps.isEmpty && w.p12Masters.isEmpty && w.ledgerText == nil)
    }

    @Test("a busy ledger lock is BUSY and rolls back")
    func ledgerBusy() async throws {
        var setup = Setup()
        var held: FileLock?
        setup.ledgerStore = { paths in
            held = try? FileLock.tryAcquire(path: paths.ledgerLock)
            return LedgerStore(paths: paths, lockTimeout: .milliseconds(60), retryInterval: .milliseconds(10))
        }
        let w = try await invoke(setup: setup)
        withExtendedLifetime(held) {}
        #expect(w.code == "BUSY" && w.kitDirs.isEmpty && w.strayTemps.isEmpty && w.p12Masters.isEmpty)
    }

    @Test("a kit folder that cannot be moved into place is removed from the ledger and the disk again")
    func commitFailure() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // The destination appears between the check and the rename (a race the pre-check cannot close).
        let dest = base.appendingPathComponent("kit").path
        var setup = Setup()
        setup.ledgerStore = { paths in
            LedgerStore(paths: paths) { data, path in
                try AtomicFile.write(data, to: path)
                try? FileManager.default.createDirectory(atPath: dest + "/sub", withIntermediateDirectories: true)
            }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", out: dest, yes: true), setup: setup)
        #expect(!w.envelope.ok)
        #expect(w.p12Masters.isEmpty)
        #expect(w.ledger?.exports.isEmpty == true, "the export entry was taken back out")
        #expect(listing(base.path) == ["kit"], "only the intruder, no staged temp folder")
    }

    @Test("a failed ledger rollback after a failed kit move is LEDGER_ROLLBACK_FAILED, not silence")
    func rollbackFailure() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("kit").path
        let writes = Mutex(0)
        var setup = Setup()
        setup.ledgerStore = { paths in
            LedgerStore(paths: paths) { data, path in
                // The first write records the export (and the kit destination appears, so the move fails);
                // the second, the rollback, fails.
                let n = writes.withLock { n -> Int in
                    n += 1
                    return n
                }
                if n > 1 { throw SideloadError("LEDGER_WRITE_FAILED", "disk full") }
                try AtomicFile.write(data, to: path)
                try? FileManager.default.createDirectory(atPath: dest + "/sub", withIntermediateDirectories: true)
            }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", out: dest, yes: true), setup: setup)
        #expect(!w.envelope.ok && w.code == "LEDGER_ROLLBACK_FAILED")
        let error = try #require(w.envelope.errors.first)
        #expect(error.message.contains("export-20261019-120000") && error.message.contains("could not be written"))
        #expect(error.fix?.contains("ledger") == true && !(error.fix ?? "").isEmpty)
        #expect(w.ledger?.exports.map(\.id) == ["export-20261019-120000"], "the dangling entry is real, and now reported")
        #expect(w.p12Masters.isEmpty, "the rest was still rolled back")
        #expect(listing(base.path) == ["kit"], "no staged temp folder")
    }

    // MARK: --copy-password

    @Test("--copy-password: on the clipboard during the hold, concealed, cleared after 90 s")
    func copyPassword() async throws {
        var setup = Setup()
        let seen = Mutex<(contents: String?, markers: [String])>((nil, []))
        setup.hold = { _, backend in
            let s = backend.snapshot
            seen.withLock { $0 = (s.contents, s.markers) }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok)
        let password = try #require(w.password)
        #expect(seen.withLock { $0.contents } == password, "the password was on the clipboard while the command waited")
        #expect(seen.withLock { $0.markers }.sorted() == ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
        #expect(w.recorder.sleepsRequested == [.seconds(90)])
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.clears == 1, "cleared afterwards")
        #expect(w.json["passwordCopied"] == true && w.json["clipboardCleared"] == true)
        #expect(w.json["clipboardHoldSeconds"] == 90)
        let progress = w.recorder.logged.joined(separator: "\n")
        #expect(progress.contains("clipboard") && progress.contains("Paste it into Feather now") && progress.contains("90 s"))
        #expect(progress.contains("Allow, not Always Allow"))
    }

    @Test("the clipboard is left alone when the owner copied something else during the hold")
    func clipboardChanged() async throws {
        var setup = Setup()
        setup.hold = { _, backend in backend.userCopies("my own text") }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok && w.json["clipboardCleared"] == false && w.json["passwordCopied"] == true)
        #expect(w.backend.snapshot.contents == "my own text" && w.backend.snapshot.clears == 0)
    }

    // MARK: signals (design section 16): the handler only calls trip(); the main flow does all cleanup

    @Test("a signal while idle (before any file) marks the export dead: beginWriting refuses, nothing is written")
    func signalWhileIdle() async throws {
        let signal = HoldSignal()
        let results = Trips()
        var setup = Setup()
        setup.holdSignal = signal
        setup.exporterOnCall = { _ in results.fire(signal, 1) }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(results.all == [.notAbsorbed(kit: nil)])
        #expect(!w.envelope.ok && w.code == "INTERRUPTED" && signal.phase == .dead)
        #expect(w.p12Masters.isEmpty && w.kitDirs.isEmpty && w.strayTemps.isEmpty && w.ledgerText == nil)
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.reads == 0)
    }

    @Test("two signals at any point before the ledger write: main removes the .p12, its temp files and the staging folder")
    func signalsBeforeLedgerWrite() async throws {
        let markers = [
            "writing the .p12", "wrote the .p12", "staged sideload-dev.p12", "staged sideload-dev.mobileprovision",
            "staged the kit",
        ]
        for marker in markers {
            for beside in [false, true] {
                let base = try makeTempDir()
                defer { try? FileManager.default.removeItem(at: base) }
                let impatient = Mutex(0)
                let signal = HoldSignal(onImpatient: { impatient.withLock { $0 += 1 } })
                let results = Trips()
                var setup = Setup()
                setup.holdSignal = signal
                setup.onLog = { line in if line.contains(marker) { results.fire(signal, 2) } }
                let out = beside ? base.appendingPathComponent("kit").path : nil
                let w = try await invoke(
                    ExportCertOptions(device: "iphone", out: out, yes: true, copyPassword: true), setup: setup)
                let context = "\(marker), beside: \(beside)"
                #expect(results.all == [.absorbed, .absorbed], "\(context)")
                #expect(impatient.withLock { $0 } == 1, "the second signal tells the owner once: \(context)")
                #expect(!w.envelope.ok && w.code == "INTERRUPTED", "\(context): \(w.text)")
                #expect(w.p12Masters.isEmpty && w.kitDirs.isEmpty && w.strayTemps.isEmpty, "\(context)")
                #expect(w.ledgerText == nil, "\(context)")
                #expect(listing(base.path).isEmpty, "nothing beside --out: \(context)")
                #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.reads == 0, "\(context)")
                #expect(signal.phase == .done(nil), "\(context)")
            }
        }
    }

    @Test("signals during the ledger write are absorbed: the kit lands, the entry stays, the hold is skipped",
        arguments: [true, false])
    func signalsDuringLedgerWrite(copyPassword: Bool) async throws {
        let signal = HoldSignal()
        let results = Trips()
        var setup = Setup()
        setup.holdSignal = signal
        setup.ledgerStore = { paths in
            LedgerStore(paths: paths) { data, path in
                try AtomicFile.write(data, to: path)
                results.fire(signal, 2)
            }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: copyPassword), setup: setup)
        #expect(results.all == [.absorbed, .absorbed])
        #expect(w.envelope.ok && w.envelope.errors.isEmpty, "\(w.text)")
        let kit = try #require(w.kitDirs.first)
        #expect(w.snap.children(of: kit).count == 3 && w.ledger?.exports.first?.kitPath == kit && w.p12Masters.count == 1)
        #expect(w.json["passwordCopied"] == false)
        #expect(copyPassword ? w.json["clipboardHoldInterrupted"] == true : w.json["clipboardHoldInterrupted"] == nil)
        #expect(copyPassword ? w.json["clipboardCleared"] == true : w.json["clipboardCleared"] == nil, "never copied: not on the clipboard")
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.reads == 0 && w.recorder.sleepsRequested.isEmpty)
        for surface in [w.text] + w.recorder.logged {
            #expect(!surface.lowercased().contains("re-run") && !surface.contains("INTERRUPTED"), "\(surface)")
        }
        #expect(signal.phase == .done(kit))
    }

    @Test("signals during the ledger write with a failed kit move: the move rolls back completely")
    func signalsDuringFailedMove() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dest = base.appendingPathComponent("kit").path
        let signal = HoldSignal()
        let results = Trips()
        let writes = Mutex(0)
        var setup = Setup()
        setup.holdSignal = signal
        setup.ledgerStore = { paths in
            LedgerStore(paths: paths) { data, path in
                try AtomicFile.write(data, to: path)
                let n = writes.withLock { n -> Int in
                    n += 1
                    return n
                }
                guard n == 1 else { return }  // the rollback write goes through
                results.fire(signal, 2)
                try? FileManager.default.createDirectory(atPath: dest + "/sub", withIntermediateDirectories: true)
            }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", out: dest, yes: true), setup: setup)
        #expect(results.all == [.absorbed, .absorbed])
        #expect(!w.envelope.ok && w.code != "LEDGER_ROLLBACK_FAILED")
        #expect(w.p12Masters.isEmpty && w.ledger?.exports.isEmpty == true)
        #expect(listing(base.path) == ["kit"] && listing(dest) == ["sub"], "only the intruder, no staging folder")
        #expect(signal.phase == .done(nil))
    }

    @Test("with the kit in place the first signal skips the hold, a second is not absorbed and names the kit")
    func signalAfterCommit() async throws {
        let signal = HoldSignal()
        let results = Trips()
        var setup = Setup()
        setup.holdSignal = signal
        setup.onLog = { line in if line.hasPrefix("export-cert: kit at") { results.fire(signal, 2) } }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        let kit = try #require(w.kitDirs.first)
        #expect(results.all == [.absorbed, .notAbsorbed(kit: kit)])
        #expect(w.envelope.ok && w.json["passwordCopied"] == false && w.json["clipboardHoldInterrupted"] == true)
        #expect(w.json["clipboardCleared"] == true, "always present with --copy-password; true: the password is not on it")
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.reads == 0)
        #expect(w.kitDirs.count == 1 && w.p12Masters.count == 1 && w.ledger?.exports.count == 1)
    }

    @Test("two signals while the password is being copied are absorbed: the hold ends at once and the clipboard is clear at exit",
        .timeLimit(.minutes(1)))
    func signalsDuringCopy() async throws {
        let signal = HoldSignal()
        let results = Trips()
        var setup = Setup()
        setup.holdSignal = signal
        // The signals arrive before the write lands. Were one not absorbed, the handler would clear (nothing yet) and
        // exit, and the copy that follows would stay on the clipboard.
        setup.pasteboard = { clipboard in
            SignallingPasteboard(inner: clipboard) {
                results.fire(signal, 2)
            }
        }
        setup.hold = { _, _ in try await Task.sleep(for: .seconds(600)) }  // only the signal can end this
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(results.all == [.absorbed, .absorbed], "no signal reaches the handler path")
        #expect(w.envelope.ok, "\(w.text)")
        #expect(w.json["passwordCopied"] == true && w.json["clipboardCleared"] == true)
        #expect(w.json["clipboardHoldInterrupted"] == true)
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.clears == 1, "main cleared after the copy")
    }

    @Test("a signal during the hold ends it early: clipboard cleared, normal success envelope, no re-run advice")
    func interruptedHold() async throws {
        let signal = HoldSignal()
        let results = Trips()
        var setup = Setup()
        setup.holdSignal = signal
        let seen = Mutex<String?>(nil)
        setup.hold = { _, backend in
            seen.withLock { $0 = backend.snapshot.contents }
            results.fire(signal, 2)
            try await Task.sleep(for: .seconds(60))  // would be the 90 s wait; the signal must end it
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        let kit = try #require(w.kitDirs.first)
        #expect(results.all == [.absorbed, .notAbsorbed(kit: kit)])
        #expect(w.envelope.ok && w.envelope.exitCode == 0 && w.envelope.errors.isEmpty, "\(w.text)")
        let password = try #require(w.password)
        #expect(seen.withLock { $0 } == password)
        #expect(w.json["passwordCopied"] == true && w.json["clipboardCleared"] == true)
        #expect(w.json["clipboardHoldInterrupted"] == true)
        #expect(w.backend.snapshot.contents == nil && w.backend.snapshot.clears == 1)
        #expect(w.kitDirs.count == 1 && w.ledger?.exports.count == 1)

        // Before the hold, stderr says the kit exists and is recorded; nothing anywhere says to re-run.
        let progress = w.recorder.logged
        let heldAt = try #require(progress.firstIndex { $0.contains("Paste it into Feather now") })
        #expect(progress[..<heldAt].contains { $0.contains(kit) && $0.contains("recorded in ledger") })
        for surface in [w.text] + progress {
            #expect(!surface.lowercased().contains("re-run") && !surface.lowercased().contains("rerun"), "\(surface)")
            #expect(!surface.contains("INTERRUPTED"))
        }
    }

    @Test("after the command finished a signal is not absorbed; INTERRUPTED reports the kit and never says to re-run")
    func signalAfterFinish() async throws {
        let signal = HoldSignal()
        var setup = Setup()
        setup.holdSignal = signal
        let ok = try await invoke(setup: setup)
        let kit = try #require(ok.kitDirs.first)
        let disposition = signal.trip()
        #expect(disposition == .notAbsorbed(kit: kit))
        guard case .notAbsorbed(let reported) = disposition else { return }
        let object = Interrupt.interrupted(name: "SIGINT", kit: reported, clipboardCleared: true)
        let entry = try #require(object.errors.first)
        #expect(entry.code == "INTERRUPTED" && entry.message.contains(kit) && entry.message.contains("ledger.json"))
        for text in [entry.message, entry.fix ?? ""] { #expect(!text.lowercased().contains("re-run")) }

        // A failed export has no kit: the generic object (which does say to re-run) is right there.
        let failing = HoldSignal()
        var failedSetup = Setup()
        failedSetup.holdSignal = failing
        failedSetup.exporterOutcome = .failure(.denied)
        _ = try await invoke(setup: failedSetup)
        #expect(failing.trip() == .notAbsorbed(kit: nil))
    }

    @Test("HoldSignal phase table")
    func holdSignalPhaseTable() async throws {
        // idle: the one handler transition is idle -> dead; beginWriting then refuses
        let idle = HoldSignal()
        #expect(idle.trip() == .notAbsorbed(kit: nil) && idle.phase == .dead)
        #expect(idle.trip() == .notAbsorbed(kit: nil) && idle.phase == .dead)
        #expect(throws: SideloadError.self) { try idle.beginWriting() }
        idle.finish()
        #expect(idle.phase == .dead)

        // writing: everything is absorbed; beginCommit then refuses; the impatient hook fires once, at the second
        let calls = Mutex(0)
        let writing = HoldSignal(onImpatient: { calls.withLock { $0 += 1 } })
        try writing.beginWriting()
        #expect(writing.phase == .writing && !writing.interrupted)
        #expect(writing.trip() == .absorbed && calls.withLock { $0 } == 0)
        #expect(writing.trip() == .absorbed && writing.trip() == .absorbed && calls.withLock { $0 } == 1)
        #expect(writing.interrupted && !writing.beginCommit() && writing.phase == .writing)
        writing.finish()
        #expect(writing.phase == .done(nil) && writing.trip() == .notAbsorbed(kit: nil))

        // committing: absorbed; markCommitted is unconditional and the hold is then skipped
        let committing = HoldSignal()
        try committing.beginWriting()
        #expect(committing.beginCommit() && committing.phase == .committing)
        #expect(committing.trip() == .absorbed && committing.trip() == .absorbed)
        committing.markCommitted(kit: "k")
        #expect(committing.phase == .committed("k") && !committing.beginCopy())
        #expect(committing.trip() == .notAbsorbed(kit: "k"), "a signal that was already absorbed is not a first signal")

        // committed: the first signal is absorbed, a later one is not
        let committed = HoldSignal()
        try committed.beginWriting()
        #expect(committed.beginCommit())
        committed.markCommitted(kit: "k")
        #expect(committed.trip() == .absorbed && committed.interrupted)
        #expect(committed.trip() == .notAbsorbed(kit: "k") && !committed.beginCopy())

        // copying: everything is absorbed (the handler must not clear before the copy lands); copyFinished wakes the hold
        let copying = HoldSignal()
        try copying.beginWriting()
        #expect(copying.beginCommit())
        copying.markCommitted(kit: "k")
        #expect(copying.beginCopy() && copying.phase == .copying("k") && !copying.interrupted)
        #expect(copying.trip() == .absorbed && copying.trip() == .absorbed && copying.trip() == .absorbed)
        copying.copyFinished()
        #expect(copying.phase == .holding("k"))
        try await copying.wait()  // the signals absorbed while copying end the hold at once
        copying.finish()
        #expect(copying.phase == .done("k"))

        // holding: the first signal wakes the wait (also when it came before the wait), a later one is not absorbed
        let holding = HoldSignal()
        try holding.beginWriting()
        #expect(holding.beginCommit())
        holding.markCommitted(kit: "k")
        #expect(holding.beginCopy())
        holding.copyFinished()
        #expect(holding.phase == .holding("k") && !holding.interrupted)
        #expect(holding.trip() == .absorbed)
        try await holding.wait()
        #expect(holding.trip() == .notAbsorbed(kit: "k"))
        holding.finish()
        holding.finish()
        #expect(holding.phase == .done("k") && holding.trip() == .notAbsorbed(kit: "k"))

        // wait() is cancellable
        let quiet = HoldSignal()
        let waiter = Task { try await quiet.wait() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test("stress: 500 runs against a racing trip() loop end with a full export or with nothing at all, in every outcome class",
        .timeLimit(.minutes(5)))
    func stress() async throws {
        enum Outcome: Hashable { case diedBeforeWriting, cutOffAfterWriting, finishedWithCopy, finishedWithoutCopy }
        let writingMarkers = [
            "writing the .p12", "wrote the .p12", "staged sideload-dev.p12", "staged sideload-dev.mobileprovision",
            "staged the kit",
        ]
        var counts: [Outcome: Int] = [:]
        for i in 0..<500 {
            // The racing loop starts at a forced point (with a first signal sent inline, so the outcome class is certain)
            // or at a random time; kinds 3 and 5 reach the hold.
            let kind = i % 6
            let signal = HoldSignal()
            let racer = Racer(signal)
            var setup = Setup()
            setup.holdSignal = signal
            switch kind {
            case 0: setup.exporterOnCall = { _ in racer.start(firstSync: true) }
            case 1:
                let marker = writingMarkers[(i / 6) % writingMarkers.count]
                setup.onLog = { if $0.contains(marker) { racer.start(firstSync: true) } }
            case 2: setup.onLog = { if $0.hasPrefix("export-cert: kit at") { racer.start(firstSync: true) } }
            case 3:
                setup.hold = { _, _ in
                    racer.start(firstSync: false)
                    try await Task.sleep(for: .milliseconds(1))
                }
            case 4: racer.start(firstSync: false, jitter: UInt32.random(in: 0...4000))
            default: break
            }
            let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
            await racer.join()
            let context = "run \(i) (kind \(kind)): \(w.text)"
            #expect(w.strayTemps.isEmpty, "\(context)")
            #expect(w.backend.snapshot.contents == nil, "the password is never left on the clipboard: \(context)")
            let outcome: Outcome
            if w.envelope.ok {
                let kit = try #require(w.kitDirs.first, "\(context)")
                #expect(w.kitDirs.count == 1 && w.snap.children(of: kit).count == 3, "\(context)")
                #expect(w.ledger?.exports.count == 1 && w.p12Masters.count == 1, "\(context)")
                outcome = w.json["passwordCopied"] == true ? .finishedWithCopy : .finishedWithoutCopy
            } else {
                #expect(w.code == "INTERRUPTED", "\(context)")
                #expect(w.kitDirs.isEmpty && w.p12Masters.isEmpty && w.ledgerText == nil, "\(context)")
                outcome = signal.phase == .dead ? .diedBeforeWriting : .cutOffAfterWriting
            }
            switch signal.phase {
            case .done, .dead: break
            default: Issue.record("\(context): phase \(signal.phase)")
            }
            counts[outcome, default: 0] += 1
            switch kind {
            case 0: #expect(outcome == .diedBeforeWriting, "\(context)")
            case 1: #expect(outcome == .cutOffAfterWriting, "\(context)")
            case 2: #expect(outcome == .finishedWithoutCopy, "\(context)")
            case 3, 5: #expect(outcome == .finishedWithCopy, "\(context)")
            default: break
            }
        }
        for outcome: Outcome in [.diedBeforeWriting, .cutOffAfterWriting, .finishedWithCopy, .finishedWithoutCopy] {
            #expect(counts[outcome, default: 0] >= 50, "\(outcome) happened \(counts[outcome, default: 0]) times")
        }
    }

    @Test("the signal handler never touches a file")
    func handlerTouchesNoFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/sideload/Interrupts.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        #expect(text.contains("trip()"), "the scan must see the handler")
        for banned in ["unlink", "removeItem", "FileManager", "rmdir", "remove(", "rename"] {
            #expect(!text.contains(banned), "Interrupts.swift mentions \(banned)")
        }
    }

    @Test("a failed copy attempts the clear and reports its real outcome, and reports an interruption", arguments: [true, false])
    func failedCopyClearsAndReports(sideloadError: Bool) async throws {
        let signal = HoldSignal()
        let stub = StubPasteboard(
            copyError: sideloadError ? SideloadError("PASTEBOARD_FAILED", "fake") : ThrowingPasteboard.Boom(),
            clearResult: true)
        var setup = Setup()
        setup.holdSignal = signal
        setup.pasteboard = { _ in
            stub.onCopy = { _ = signal.trip() }
            return stub
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok && w.json["passwordCopied"] == false)
        #expect(stub.clears == 1 && w.json["clipboardCleared"] == true, "the clear was attempted and its result reported")
        #expect(w.json["clipboardHoldInterrupted"] == true, "a signal arrived during the failed copy")
        #expect(w.warningCodes().contains("PASTEBOARD_FAILED"))
    }

    @Test("any error from the pasteboard after the kit exists is a warning, not a failure")
    func pasteboardThrowsUnexpectedly() async throws {
        let w = try await withTestHome(config: iphoneConfig()) { paths, _ in
            let paid = try keychainCert(TestCerts.paid)
            let scratch = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            var profile = paidProfile(certs: [paid.reference])
            profile.file = scratch.appendingPathComponent("p.mobileprovision").path
            try profileBytes.write(to: URL(fileURLWithPath: profile.file!))
            var (services, _) = fakeServices(paths, keychain: FakeKeychain([paid]))
            services.profiles = FakeProfileSource([profile])
            services.identityExporter = FakeIdentityExporter(.success(p12Bytes(legacy: true)))
            services.secrets = FakeSecretStore()
            services.p12Verifier = FakeP12Verifier(references: [CertReference(paid.reference)!])
            services.pasteboard = ThrowingPasteboard()
            services.sleep = { _ in }
            return await ExportCertCommand.run(services, ExportCertOptions(device: "iphone", yes: true, copyPassword: true))
        }
        #expect(w.ok && w.exitCode == 0, "\(w.errors)")
        #expect(w.data["passwordCopied"] == false && w.data["clipboardCleared"] == false)
        #expect(w.data["warnings"]?.array?.contains { $0["code"]?.string == "PASTEBOARD_FAILED" } == true)
        let fixes = w.data["warnings"]?.array?.compactMap { $0["fix"]?.string } ?? []
        #expect(!fixes.isEmpty && fixes.allSatisfy { !$0.lowercased().contains("run the export again") && !$0.lowercased().contains("re-run") })
    }

    @Test("a signal during the hold reports clipboardCleared false when the owner copied something else")
    func interruptedHoldClipboardChanged() async throws {
        let signal = HoldSignal()
        var setup = Setup()
        setup.holdSignal = signal
        setup.hold = { _, backend in
            backend.userCopies("my own text")
            _ = signal.trip()
            try await Task.sleep(for: .seconds(60))
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok && w.json["clipboardCleared"] == false && w.json["clipboardHoldInterrupted"] == true)
        #expect(w.backend.snapshot.contents == "my own text" && w.backend.snapshot.clears == 0)
    }

    @Test("a normal hold reports clipboardHoldInterrupted false")
    func uninterruptedHold() async throws {
        var setup = Setup()
        setup.hold = { _, _ in }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok && w.json["clipboardHoldInterrupted"] == false && w.json["clipboardCleared"] == true)
    }

    @Test("a cancelled hold still clears the clipboard")
    func cancelledHold() async throws {
        var setup = Setup()
        setup.hold = { _, _ in throw CancellationError() }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok && w.backend.snapshot.contents == nil && w.backend.snapshot.clears == 1)
    }

    @Test("the operation lock is released before the hold, so the next command is not blocked for 90 s")
    func lockReleasedBeforeHold() async throws {
        var setup = Setup()
        let probe = Mutex<Paths?>(nil)
        let state = Mutex<String?>(nil)
        setup.home = { paths in probe.withLock { $0 = paths } }
        setup.hold = { _, _ in
            guard let paths = probe.withLock({ $0 }) else { return }
            do {
                OperationLockProbe.release(try OperationLock.acquire(paths: paths))
                state.withLock { $0 = "free" }
            } catch {
                state.withLock { $0 = "held" }
            }
        }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.envelope.ok)
        #expect(state.withLock { $0 } == "free")
    }

    @Test("a pasteboard that cannot be written is a warning: the kit stands, nothing is on the clipboard")
    func copyFailure() async throws {
        let w = try await invokeWithBrokenPasteboard()
        #expect(w.envelope.ok && w.json["passwordCopied"] == false && w.json["clipboardCleared"] == false)
        #expect(w.warningCodes().contains("PASTEBOARD_FAILED"))
        #expect(w.recorder.sleepsRequested.isEmpty && w.backend.snapshot.contents == nil)
        #expect(w.kitDirs.count == 1)
    }

    @Test("a failed export never touches the pasteboard, even with --copy-password")
    func noCopyOnFailure() async throws {
        var setup = Setup()
        setup.exporterOutcome = .failure(.denied)
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        #expect(w.code == "KEYCHAIN_DENIED")
        #expect(w.backend.snapshot.reads == 0 && w.backend.snapshot.contents == nil && w.recorder.sleepsRequested.isEmpty)
    }

    @Test("without the inert-default override a CLI run cannot reach a real pasteboard")
    func inertPasteboardDefault() async throws {
        let w = try await withTestHome(config: iphoneConfig()) { paths, _ in
            let paid = try keychainCert(TestCerts.paid)
            let scratch = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            var profile = paidProfile(certs: [paid.reference])
            profile.file = scratch.appendingPathComponent("p.mobileprovision").path
            try profileBytes.write(to: URL(fileURLWithPath: profile.file!))
            var (services, _) = fakeServices(paths, keychain: FakeKeychain([paid]))
            services.profiles = FakeProfileSource([profile])
            services.identityExporter = FakeIdentityExporter()
            services.secrets = FakeSecretStore()
            services.p12Verifier = FakeP12Verifier(references: [CertReference(paid.reference)!])
            services.sleep = { _ in }
            return await ExportCertCommand.run(services, ExportCertOptions(device: "iphone", yes: true, copyPassword: true))
        }
        #expect(w.ok && w.data["passwordCopied"] == false)
        #expect(w.data["warnings"]?.array?.contains { $0["code"]?.string == "PASTEBOARD_UNAVAILABLE" } == true)
    }

    // MARK: secret hygiene

    @Test("the password, the full fingerprint, full device IDs and identity names appear nowhere")
    func hygiene() async throws {
        for copy in [false, true] {
            var setup = Setup()
            setup.hold = { _, _ in }
            let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: copy), setup: setup)
            #expect(w.envelope.ok)
            let password = try #require(w.password)
            let paid = try keychainCert(TestCerts.paid)
            let secrets = [
                ("password", password), ("password without hyphens", password.replacingOccurrences(of: "-", with: "")),
                ("sha1", paid.reference), ("sha1 lower", paid.reference.lowercased()),
                ("udid", savedUdid("1")), ("udid lower", savedUdid("1").lowercased()), ("udid bare", savedUdid("1").replacingOccurrences(of: "-", with: "")),
                ("core id", savedCoreId("1")), ("identity name", "Test 000001"), ("identity name 2", "Apple Development: Test"),
            ]
            var surfaces: [(String, String)] = [("envelope", w.text), ("progress", w.recorder.logged.joined(separator: "\n"))]
            // Every file under the home except the owner's config.json (it holds the saved device IDs by design);
            // the .p12 and profile are opaque blobs here, but must still not contain the password.
            for (path, data) in w.snap.files where path != "config.json" {
                surfaces.append((path, String(decoding: data, as: UTF8.self)))
            }
            for (surface, text) in surfaces {
                for (label, secret) in secrets {
                    #expect(!text.contains(secret), "\(label) leaked into \(surface) (copy: \(copy))")
                }
            }
            #expect(w.ledgerText?.contains("deviceTails") == true)
        }
    }

    @Test("the password reaches nothing but the keychain store, the exporter, the verifier and the pasteboard")
    func passwordSinks() async throws {
        var setup = Setup()
        setup.hold = { _, _ in }
        let w = try await invoke(ExportCertOptions(device: "iphone", yes: true, copyPassword: true), setup: setup)
        let password = try #require(w.password)
        #expect((w.secrets as? FakeSecretStore)?.events == [.read, .add(password)])
        #expect(w.runner.calls.allSatisfy { !$0.args.joined().contains(password) })
    }
}

/// Fires `onCopy` (the signals) just before the write lands.
private struct SignallingPasteboard: SecretPasteboard {
    let inner: ConcealedClipboard
    let onCopy: @Sendable () -> Void
    func copy(_ secret: String) throws {
        onCopy()
        try inner.copy(secret)
    }
    func clearIfOurs() -> Bool { inner.clearIfOurs() }
}

/// A pasteboard whose copy fails; `onCopy` runs first (signals), `clearIfOurs` returns `clearResult` and counts.
private final class StubPasteboard: SecretPasteboard {
    private let calls = Mutex(0)
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)
    let copyError: any Error
    let clearResult: Bool
    var clears: Int { calls.withLock { $0 } }
    var onCopy: (@Sendable () -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }

    init(copyError: any Error, clearResult: Bool) {
        self.copyError = copyError
        self.clearResult = clearResult
    }

    func copy(_ secret: String) throws {
        onCopy?()
        throw copyError
    }

    func clearIfOurs() -> Bool {
        calls.withLock { $0 += 1 }
        return clearResult
    }
}

private struct ThrowingPasteboard: SecretPasteboard {
    struct Boom: Error {}
    func copy(_ secret: String) throws { throw Boom() }
    func clearIfOurs() -> Bool { false }
}

private enum OperationLockProbe {
    static func release(_ lock: OperationLock) { lock.release() }
}

/// Same as `invoke` with a pasteboard backend whose writes fail.
private func invokeWithBrokenPasteboard() async throws -> World {
    try await withTestHome(config: iphoneConfig()) { paths, _ in
        let scratch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paid = try keychainCert(TestCerts.paid)
        let recorder = Recorder()
        var profile = paidProfile(certs: [paid.reference])
        profile.file = scratch.appendingPathComponent("p.mobileprovision").path
        try profileBytes.write(to: URL(fileURLWithPath: profile.file!))
        let backend = FakePasteboardBackend()
        backend.failNextWrites()
        let keychain = FakeKeychain([paid])
        let source = FakeProfileSource([profile])
        let exporter = FakeIdentityExporter(.success(p12Bytes(legacy: true)))
        let secrets = FakeSecretStore()
        let verifier = FakeP12Verifier(references: [CertReference(paid.reference)!])
        var (services, runner) = fakeServices(paths, keychain: keychain)
        services.profiles = source
        services.identityExporter = exporter
        services.secrets = secrets
        services.p12Verifier = verifier
        services.pasteboard = ConcealedClipboard(backend: backend)
        services.log = { recorder.log($0) }
        services.sleep = { recorder.slept($0) }
        let envelope = await ExportCertCommand.run(
            services, ExportCertOptions(device: "iphone", yes: true, copyPassword: true))
        let (text, json) = try envelope.printed()
        return World(
            envelope: envelope, text: text, json: json, snap: snapshot(paths.home), paths: paths, recorder: recorder,
            exporter: exporter, secrets: secrets, verifier: verifier, backend: backend, keychain: keychain, source: source,
            runner: runner, ledger: try? LedgerStore(paths: paths).load(),
            ledgerText: try? String(contentsOfFile: paths.ledger, encoding: .utf8))
    }
}

@Suite("export-cert CLI")
struct ExportCertCLITests {
    private func invokeCLI(_ argv: [String]) async throws -> (envelope: Envelope, json: JSONValue) {
        try await withTestHome(config: iphoneConfig()) { paths, _ in
            let (services, _) = fakeServices(paths)
            let envelope = await run(argv: argv, services: services)
            return (envelope, try envelope.printed().json)
        }
    }

    @Test("export-cert is built and listed in help with --copy-password and no --show-password")
    func help() async throws {
        for argv in [["help"], ["export-cert", "-h"]] {
            let out = try await invokeCLI(argv)
            #expect(out.json["built"]?.array?.contains("export-cert") == true)
            let usage = out.json["usage"]?.array?.compactMap(\.string) ?? []
            let line = try #require(usage.first { $0.hasPrefix("export-cert") })
            #expect(line.contains("--copy-password") && line.contains("--yes") && !line.contains("show-password"))
        }
    }

    @Test("flags and values parse; unknown options and positionals are USAGE")
    func parsing() async throws {
        let confirm = try await invokeCLI(["export-cert", "--device", "iphone", "--copy-password"])
        #expect(confirm.envelope.errorCodes == ["CONFIRM_REQUIRED"] && confirm.json["copyPassword"] == true)
        let eq = try await invokeCLI(["export-cert", "--device=iphone", "--profile=\(UUID().uuidString)", "--out=/tmp/x"])
        #expect(eq.envelope.errorCodes == ["CONFIRM_REQUIRED"])
        for argv in [
            ["export-cert", "--device", "iphone", "--show-password", "--yes"], ["export-cert", "extra"],
            ["export-cert", "--device"], ["export-cert", "--copy-password=1"], ["export-cert", "--bogus"],
        ] {
            #expect(try await invokeCLI(argv).envelope.errorCodes == ["USAGE"], "\(argv)")
        }
        #expect(try await invokeCLI(["export-cert", "--yes"]).envelope.errorCodes == ["USAGE"])
    }

    @Test("a CLI run over fakes without a pasteboard reaches nothing real")
    func fakesOnly() async throws {
        let out = try await invokeCLI(["export-cert", "--device", "iphone", "--yes", "--copy-password"])
        // The fake services have inert exporter/profile defaults: it fails on the first unavailable piece.
        #expect(!out.envelope.ok)
        #expect(["KEYCHAIN_READ_FAILED", "CERT_NOT_FOUND", "PROFILES_UNAVAILABLE", "KEYCHAIN_UNAVAILABLE"].contains(out.envelope.errorCodes.first ?? ""))
    }
}
