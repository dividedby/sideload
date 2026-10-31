import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import sideload

// `status --notify` and `status --print-agent` (docs/design.md sections 11 and 18). Temp homes and fake runners only: no
// real notification, no `launchctl`, nothing in the real `$SIDELOAD_HOME`.

/// Answers `osascript` with `result`, records every call, and can run a hook while the "notification" is being posted.
private final class PostRunner: Runner {
    let seen = Mutex<[CommandSpec]>([])
    let result: Mutex<RunResult>
    let hook: (@Sendable () async -> Void)?

    init(_ result: RunResult = RunResult(), hook: (@Sendable () async -> Void)? = nil) {
        self.result = Mutex(result)
        self.hook = hook
    }

    var calls: [CommandSpec] { seen.withLock { $0 } }
    var message: String? { calls.last?.args.last }

    func run(_ spec: CommandSpec) async -> RunResult {
        seen.withLock { $0.append(spec) }
        await hook?()
        return result.withLock { $0 }
    }
}

private func cert(_ fp: String, days: Double, present: Bool = true) -> LedgerCertificate {
    LedgerCertificate(
        fp8: fp, team: Team.id, notBefore: nil, notAfter: daysFromNow(days), firstSeen: testNow, lastSeen: testNow,
        valid: true, present: present)
}

private let profileUuid = "0F0F0F0F-1111-2222-3333-4444444455AA"

private func profile(days: Double) -> LedgerProfile {
    LedgerProfile(
        uuid: profileUuid, team: Team.id, applicationId: nil, wildcard: true, created: nil, expires: daysFromNow(days),
        deviceCount: 1, deviceTails: [], certFp8s: [], source: "xcode-managed", firstSeen: testNow, lastSeen: testNow,
        present: true)
}

private func install(_ app: ProvisionApp, alias: String = "iphone", days: Double) -> LedgerInstall {
    var record = installRecord(app, alias: alias)
    record.profileExpires = daysFromNow(days)
    return record
}

private struct Run {
    var envelope: Envelope
    var json: JSONValue
    var text: String
    var warningCodes: [String] { json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? [] }
    var notified: [String] { json["notified"]?.array?.compactMap { $0["item"]?.string } ?? [] }
}

private struct Home {
    var paths: Paths
    var store: ConfigStore

    func setLedger(_ ledger: Ledger) async throws { try await LedgerStore(paths: paths).update { $0 = ledger } }
    func stored() -> [String: Int] { (try? store.load().lastNotified) ?? ["<unreadable>": -1] }
    func setStored(_ values: [String: Int]) async throws { try await store.update { $0.lastNotified = values } }

    /// `status --notify` through the CLI, `shift` days after `testNow`.
    func notify(
        _ runner: PostRunner, shift: Double = 0, argv: [String] = ["status", "--notify"], http: (any HTTPTransport)? = nil
    ) async throws -> Run {
        var (services, _) = fakeServices(paths, now: daysFromNow(shift))
        services.runner = runner
        if let http { services.http = http }
        let envelope = await run(argv: argv, services: services)
        let (text, json) = try envelope.printed()
        return Run(envelope: envelope, json: json, text: text)
    }
}

private func withNotifyHome(
    config: Config = provisionConfig(), ledger: Ledger? = nil, _ body: (Home) async throws -> Void
) async throws {
    try await withTestHome(config: config) { paths, store in
        let home = Home(paths: paths, store: store)
        if let ledger { try await home.setLedger(ledger) }
        try await body(home)
    }
}

private let installKey = "install stremio-ios @ iphone"

@Suite("status --notify")
struct StatusNotifyTests {
    // MARK: thresholds

    @Test("a free install crosses 3, 1 and 0", arguments: [
        (3.5, nil, nil), (3.0, 3, "stremio-ios @ iphone 3 d left"), (2.5, 3, "stremio-ios @ iphone 2 d left"),
        (1.0, 1, "stremio-ios @ iphone 1 d left"), (0.5, 1, "stremio-ios @ iphone under 1 d left"),
        (-0.5, 0, "stremio-ios @ iphone expired"),
    ] as [(Double, Int?, String?)])
    func installThresholds(days: Double, threshold: Int?, text: String?) async throws {
        try await withNotifyHome(ledger: Ledger(installs: [install(.stremioIOS, days: days)])) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            // (`status`'s own INSTALL_EXPIRING / INSTALL_EXPIRED warnings may be there; no NOTIFY_ one.)
            #expect(out.envelope.ok && !out.warningCodes.contains { $0.hasPrefix("NOTIFY_") })
            guard let threshold, let text else {
                #expect(runner.calls.isEmpty && out.json["delivered"] == false && out.json["notified"] == [])
                #expect(home.stored().isEmpty)
                return
            }
            #expect(runner.message == text)
            #expect(out.json["delivered"] == true)
            #expect(out.json["notified"] == [["item": .string(installKey), "threshold": .number(Double(threshold))]])
            #expect(home.stored() == [installKey: threshold])
        }
    }

    @Test("a paid certificate crosses 60, 14 and 0 by whole days", arguments: [
        (61.5, nil, nil), (60.5, 60, "cert aaaaaaaa 60 d left"), (20.0, 60, "cert aaaaaaaa 20 d left"),
        (15.5, 60, "cert aaaaaaaa 15 d left"), (14.5, 14, "cert aaaaaaaa 14 d left"), (14.0, 14, "cert aaaaaaaa 14 d left"), (5.0, 14, "cert aaaaaaaa 5 d left"),
        (-1.0, 0, "cert aaaaaaaa expired"),
    ] as [(Double, Int?, String?)])
    func certThresholds(days: Double, threshold: Int?, text: String?) async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: days)])) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && out.warningCodes == [])
            guard let threshold, let text else {
                #expect(runner.calls.isEmpty && out.json["delivered"] == false)
                return
            }
            #expect(runner.message == text)
            #expect(home.stored() == ["cert aaaaaaaa": threshold])
            #expect(out.notified == ["cert aaaaaaaa"])
        }
    }

    @Test("a paid profile is keyed by the last four of its UUID, and says so without the ellipsis")
    func profileKey() async throws {
        try await withNotifyHome(ledger: Ledger(profiles: [profile(days: 10)])) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(home.stored() == ["profile …55AA": 14])
            #expect(runner.message == "profile 55AA 10 d left")
            #expect(!out.text.contains(profileUuid))
        }
    }

    // MARK: pending restores

    @Test("a pending app-data restore is announced once at 0, and its key goes when the restore is done")
    func pendingRestore() async throws {
        let prefs = "Library/Preferences/io.github.dividedby.free.stremio.plist"
        let files: [String: Data] = [prefs: Data("a".utf8), "Documents/library.json": Data("b".utf8)]
        var device = DeviceScript(initial: [stremioId: true])
        device.container = files
        try await withInstallWorld(script: device, lendable: "stremio-ios", ledger: { $0.installs = [installRecord(.stremioIOS)] }) { w in
            #expect(await w.slot("lend", device: "iphone", to: "lab").ok)
            var failing = device
            failing.dataFaults.copyToFails = [prefs]
            w.runner.arm(failing)
            #expect(json(await w.slot("return", device: "iphone"))["dataRestored"] == false)
            w.clock.advance(PendingRestores.settleWindow)

            let post = PostRunner()
            var services = w.services
            services.runner = post
            let first = try await StatusCommand.runNotify(services).printed().json
            #expect(first["pendingRestores"] == [["device": "iphone", "app": "stremio-ios"]])
            #expect(post.message == "restore waiting: stremio-ios @ iphone")
            #expect(first["notified"] == [["item": "restore stremio-ios @ iphone", "threshold": 0]])
            #expect((try? w.config().lastNotified) == ["restore stremio-ios @ iphone": 0])

            _ = await StatusCommand.runNotify(services)
            #expect(post.calls.count == 1, "the same restore is not announced twice")

            w.runner.arm(device)
            let restored = await SlotCommand.run(
                w.services, SlotOptions(sub: "restore", device: "iphone", udid: nil, to: nil, app: nil, yes: true))
            #expect(restored.ok)
            let after = try await StatusCommand.runNotify(services).printed().json
            #expect(after["pendingRestores"] == [] && after["delivered"] == false)
            #expect((try? w.config().lastNotified)?.isEmpty == true && post.calls.count == 1)
        }
    }

    // MARK: once per threshold

    @Test("no repeat at the same threshold; the next lower one is announced; so is expiry")
    func lowerThresholds() async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 20)])) { home in
            let runner = PostRunner()
            _ = try await home.notify(runner)
            #expect(runner.calls.count == 1 && home.stored() == ["cert aaaaaaaa": 60])
            let again = try await home.notify(runner, shift: 3)
            #expect(runner.calls.count == 1 && again.json["delivered"] == false && again.json["notified"] == [])
            let fourteen = try await home.notify(runner, shift: 7)
            #expect(runner.calls.count == 2 && runner.message == "cert aaaaaaaa 13 d left")
            #expect(fourteen.notified == ["cert aaaaaaaa"] && home.stored() == ["cert aaaaaaaa": 14])
            _ = try await home.notify(runner, shift: 19)
            #expect(runner.calls.count == 2)
            let expired = try await home.notify(runner, shift: 21)
            #expect(runner.calls.count == 3 && runner.message == "cert aaaaaaaa expired" && home.stored() == ["cert aaaaaaaa": 0])
            _ = try await home.notify(runner, shift: 40)
            #expect(runner.calls.count == 3 && expired.envelope.ok)
        }
    }

    @Test("a stored threshold below the item's own (renewed into a higher bracket) is re-armed without a notification")
    func rearm() async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 10)])) { home in
            try await home.setStored(["cert aaaaaaaa": 0])
            let runner = PostRunner()
            _ = try await home.notify(runner)
            #expect(runner.calls.isEmpty && home.stored() == ["cert aaaaaaaa": 14])
            _ = try await home.notify(runner, shift: 11)
            #expect(runner.message == "cert aaaaaaaa expired" && home.stored() == ["cert aaaaaaaa": 0])
        }
    }

    // MARK: clean-up

    @Test("a renewal clears the key, a vanished item's key is pruned, a key this feature does not own is left alone")
    func pruning() async throws {
        try await withNotifyHome(ledger: Ledger(installs: [install(.stremioIOS, days: 5)])) { home in
            try await home.setStored([
                installKey: 3, "install apollo @ iphone": 1, "cert deadbeef": 14, "profile …ZZZZ": 60,
                "restore stremio-ios @ iphone": 0, "custom": 7, "installer": 2, "certain": 9, "": 1,
            ])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && out.warningCodes == [] && runner.calls.isEmpty)
            #expect(home.stored() == ["custom": 7, "installer": 2, "certain": 9, "": 1])
        }
    }

    @Test("with the ledger unreadable nothing is known, so no key is pruned and nothing is announced")
    func unreadableLedger() async throws {
        try await withNotifyHome { home in
            try await home.setStored([installKey: 1, "cert deadbeef": 14])
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: home.paths.ledger))
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && runner.calls.isEmpty)
            #expect(home.stored() == [installKey: 1, "cert deadbeef": 14])
        }
    }

    @Test("with the config unreadable it cannot tell what was announced: nothing is posted, NOTIFY_SKIPPED")
    func unreadableConfig() async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 5)])) { home in
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: home.paths.config))
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && runner.calls.isEmpty && out.json["delivered"] == false)
            #expect(out.warningCodes.contains("NOTIFY_SKIPPED"))
        }
    }

    // MARK: delivery

    @Test("a failed delivery records nothing, warns NOTIFY_FAILED and stays ok; stale keys still go")
    func deliveryFails() async throws {
        let failures = [
            RunResult(code: 1, stderr: "not allowed"), RunResult(code: nil, timedOut: true),
            RunResult(code: nil, spawnError: "ENOENT"),
        ]
        for failure in failures {
            try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 5)])) { home in
                try await home.setStored(["cert deadbeef": 14, "custom": 1])
                let runner = PostRunner(failure)
                let out = try await home.notify(runner)
                #expect(out.envelope.ok && out.envelope.exitCode == 0 && out.envelope.errors.isEmpty)
                #expect(out.warningCodes == ["NOTIFY_FAILED"])
                let warning = try #require(out.json["warnings"]?.array?.first)
                #expect(warning["fix"]?.string?.contains("notifications") == true && warning["fix"]?.string?.contains("GUI session") == true)
                #expect(out.json["delivered"] == false && out.json["notified"] == [])
                #expect(home.stored() == ["custom": 1], "nothing recorded; the vanished cert's key removed")
                // The next run tries again.
                runner.result.withLock { $0 = RunResult() }
                let retry = try await home.notify(runner)
                #expect(retry.json["delivered"] == true && home.stored() == ["custom": 1, "cert aaaaaaaa": 14])
            }
        }
    }

    @Test("a config that cannot be written is a warning: the notification is still reported delivered")
    func writeFails() async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 5)])) { home in
            let runner = PostRunner()
            var (services, _) = fakeServices(home.paths)
            services.runner = runner
            // The config lock cannot be opened: a folder stands where the lock file is.
            try? FileManager.default.removeItem(atPath: home.paths.configLock)
            try FileManager.default.createDirectory(atPath: home.paths.configLock, withIntermediateDirectories: false)
            let out = try await StatusCommand.runNotify(services).printed()
            #expect(out.json["delivered"] == true && out.json["notified"] == [["item": "cert aaaaaaaa", "threshold": 14]])
            let codes = out.json["warnings"]?.array?.compactMap { $0["code"]?.string } ?? []
            #expect(codes == ["NOTIFY_STATE_NOT_SAVED"])
            #expect(home.stored().isEmpty)
        }
    }

    @Test("a concurrent writer's change to lastNotified is kept: the update re-reads inside the config lock")
    func concurrentWriter() async throws {
        try await withNotifyHome(ledger: Ledger(certificates: [cert("aaaaaaaa", days: 5)])) { home in
            try await home.setStored(["cert deadbeef": 14])
            let store = home.store
            let runner = PostRunner(hook: {
                try? await store.update { $0.lastNotified["other tool"] = 4 }
            })
            let out = try await home.notify(runner)
            #expect(out.json["delivered"] == true)
            #expect(home.stored() == ["cert aaaaaaaa": 14, "other tool": 4])
        }
    }

    // MARK: the message

    @Test("one notification lists the due items, worst first, and records each at its own threshold")
    func combinedMessage() async throws {
        let ledger = Ledger(
            certificates: [cert("aaaaaaaa", days: -1)],
            installs: [install(.stremioIOS, days: 2.5), install(.apollo, days: 0.5)])
        try await withNotifyHome(ledger: ledger) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(runner.calls.count == 1)
            #expect(runner.message == "cert aaaaaaaa expired, apollo @ iphone under 1 d left, stremio-ios @ iphone 2 d left")
            #expect(out.json["notified"] == [
                ["item": "cert aaaaaaaa", "threshold": 0], ["item": "install apollo @ iphone", "threshold": 1],
                ["item": .string(installKey), "threshold": 3],
            ])
            #expect(home.stored() == ["cert aaaaaaaa": 0, "install apollo @ iphone": 1, installKey: 3])
        }
    }

    @Test("osascript gets the message as an argument of Notifier.arguments, with its 10 s timeout, and nothing else runs")
    func osascriptShape() async throws {
        try await withNotifyHome(ledger: Ledger(installs: [install(.stremioIOS, days: 2.5)])) { home in
            let runner = PostRunner()
            _ = try await home.notify(runner)
            let spec = try #require(runner.calls.first)
            #expect(runner.calls.count == 1)
            #expect(spec.executable == "/usr/bin/osascript" && spec.timeout == .seconds(10))
            #expect(spec.args == Notifier.arguments(for: "stremio-ios @ iphone 2 d left"))
            #expect(spec.args.dropLast().filter { $0 == "-e" }.count == 3 && !spec.args.dropLast().contains { $0.contains("stremio") })
        }
    }

    @Test("nothing due means no subprocess at all", arguments: [0, 1, 2])
    func nothingDue(scenario: Int) async throws {
        let ledger: Ledger? =
            switch scenario {
            case 0: nil
            case 1: Ledger(certificates: [cert("aaaaaaaa", days: 300)], installs: [install(.stremioIOS, days: 6)])
            default: Ledger(certificates: [cert("aaaaaaaa", days: 5)])
            }
        try await withNotifyHome(ledger: ledger) { home in
            if scenario == 2 { try await home.setStored(["cert aaaaaaaa": 14]) }
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(runner.calls.isEmpty && out.envelope.ok)
            #expect(out.json["delivered"] == false && out.json["notified"] == [] && out.warningCodes == [])
        }
    }

    @Test("a message too long for one notification ends with +N more, and every due item is recorded")
    func cap() async throws {
        let certs = (1...12).map { cert("aaaaaa" + String(format: "%02d", $0), days: Double($0)) }
        try await withNotifyHome(ledger: Ledger(certificates: certs)) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            let message = try #require(runner.message)
            #expect(message.count <= 160 && message.hasPrefix("cert aaaaaa01 1 d left, cert aaaaaa02 2 d left, "))
            let more = try #require(message.split(separator: ",").last)
            let hidden = try #require(Int(more.dropFirst(2).prefix { $0.isNumber }))
            #expect(more == " +\(hidden) more" && hidden > 0)
            #expect(out.notified.count == 12 && home.stored().count == 12)
        }
    }

    // MARK: no identifiers

    @Test("no device ID, device name or profile UUID in the output or in what osascript is given")
    func noIdentifiers() async throws {
        let ledger = Ledger(
            profiles: [profile(days: 3)], installs: [install(.stremioIOS, days: 2.5), install(.stremioTVOS, alias: "appletv", days: -1)])
        try await withNotifyHome(ledger: ledger) { home in
            let runner = PostRunner()
            let out = try await home.notify(runner)
            let everything = out.text + (runner.calls.flatMap(\.args).joined(separator: "\n"))
            for secret in [savedUdid("1"), savedCoreId("1"), savedUdid("2"), savedCoreId("2"), "Test iPhone", "Test Apple TV", profileUuid] {
                #expect(!everything.contains(secret), "output holds \(secret)")
            }
            #expect(out.json["delivered"] == true)
            let keys = home.stored().keys
            #expect(keys.allSatisfy { key in StatusNotify.owns(key) && !key.contains(savedUdid("1")) })
        }
    }

    @Test("an alias that is a device ID is cut to its last four characters in the key and the text")
    func idShapedAlias() {
        let alias = savedUdid("1")
        let current = StatusNotify.current(items: [], pending: [PendingRestores.Entry(device: alias, app: "apollo")])
        #expect(current.map(\.key) == ["restore apollo @ …" + String(alias.suffix(4))])
        #expect(!current[0].text.contains(alias))
    }
}

@Suite("status --notify: texts and rules")
struct StatusNotifyRuleTests {
    @Test("the thresholds follow the item's level")
    func thresholds() {
        func item(_ kind: ExpiryItem.Kind, _ level: ExpiryItem.Level) -> ExpiryItem {
            ExpiryItem(kind: kind, name: "x", notAfter: testNow, daysLeft: 0, level: level)
        }
        let paid = [ExpiryItem.Kind.certificate, .profile].flatMap { kind in
            [ExpiryItem.Level.ok, .warn, .critical, .expired].map { StatusNotify.threshold(of: item(kind, $0)) }
        }
        #expect(paid == [nil, 60, 14, 0, nil, 60, 14, 0])
        let free = [ExpiryItem.Level.ok, .warn, .critical, .expired].map { StatusNotify.threshold(of: item(.install, $0)) }
        #expect(free == [nil, 3, 1, 0])
    }

    @Test("the keys this feature owns")
    func owned() {
        for key in ["install a @ b", "cert ab12cd34", "profile …ABCD", "restore a @ b", "update apollo 4.0.2"] {
            #expect(StatusNotify.owns(key))
        }
        for key in ["", "installer", "certain", "profiles", "restoration", "other", "Install a @ b", "updates apollo 4.0.2"] {
            #expect(!StatusNotify.owns(key))
        }
    }

    @Test("apply: lowers, never raises on a record, re-arms, prunes only owned keys, and reports whether it changed")
    func apply() {
        let current = [
            StatusNotify.Current(key: "cert a", threshold: 14, text: "", notAfter: testNow),
            StatusNotify.Current(key: "cert b", threshold: 60, text: "", notAfter: testNow),
        ]
        var stored = ["cert a": 60, "cert b": 14, "cert gone": 0, "foreign": 5]
        #expect(StatusNotify.apply(to: &stored, announced: [current[0]], current: current, prune: true, pruneUpdates: true))
        // `cert a` lowered to 14, `cert b` (14, below its current 60) re-armed to 60.
        #expect(stored == ["cert a": 14, "cert b": 60, "foreign": 5])
        #expect(!StatusNotify.apply(to: &stored, announced: [], current: current, prune: true, pruneUpdates: true))
        // A concurrent lower value is not raised by an announcement.
        var raced = ["cert a": 0]
        StatusNotify.apply(to: &raced, announced: [current[0]], current: [], prune: false, pruneUpdates: true)
        #expect(raced == ["cert a": 0])
        // Without `prune`, vanished keys stay.
        var kept = ["cert gone": 0]
        #expect(!StatusNotify.apply(to: &kept, announced: [], current: [], prune: false, pruneUpdates: true) && kept == ["cert gone": 0])
    }

    @Test("the texts, and sanitised keeps the + of +N more")
    func texts() {
        #expect(Notifier.expiring("cert ab12cd34", daysLeft: 41) == "cert ab12cd34 41 d left")
        #expect(Notifier.expiring("apollo @ iphone", daysLeft: 0) == "apollo @ iphone under 1 d left")
        #expect(Notifier.expired("cert ab12cd34") == "cert ab12cd34 expired")
        #expect(Notifier.restoreWaiting(app: "stremio-ios", alias: "iphone") == "restore waiting: stremio-ios @ iphone")
        #expect(Notifier.sanitised("a, +3 more") == "a, +3 more")
    }

    @Test("combined: whole when it fits; otherwise the first parts and +N more, within 160 characters")
    func combined() {
        #expect(Notifier.combined(["a @ b 3 d left", "c @ d expired"]) == "a @ b 3 d left, c @ d expired")
        #expect(Notifier.combined([]) == "" && Notifier.combined(["é"]) == "")
        let parts = (1...20).map { "stremio-ios @ device\($0) 3 d left" }
        let text = Notifier.combined(parts)
        #expect(text.count <= 160 && text.hasSuffix(" more") && text.hasPrefix(parts[0] + ", " + parts[1]))
        let kept = text.components(separatedBy: ", ").dropLast().count
        #expect(text.hasSuffix(", +\(20 - kept) more"))
        // Exactly full: no suffix; one character over: the last part moves into the count.
        let exact = ["a" + String(repeating: "x", count: 79), String(repeating: "y", count: 78)]
        #expect(Notifier.combined(exact).count == 160 && !Notifier.combined(exact).contains("more"))
        let over = ["a" + String(repeating: "x", count: 79), String(repeating: "y", count: 80)]
        #expect(Notifier.combined(over) == exact[0] + ", +1 more")
        // A first part that is too long alone is cut, with no count.
        #expect(Notifier.combined([String(repeating: "z", count: 200), "b"]).count == 160)
    }
}

// MARK: status --print-agent

private let statusLabel = "io.github.dividedby.sideload.status"

private func agentServices(home: String = "/Users/pat/.sideload") -> (services: Services, runner: FakeRunner) {
    let made = fakeServices(Paths(home: home))
    var services = made.services
    services.localUser = LocalUser(login: "pat", homeDirectory: "/Users/pat")
    return (services, made.runner)
}

private func plistText(_ envelope: Envelope) throws -> String { try #require(envelope.data["plist"]?.string) }

private let goldenStatus = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>Label</key>
    \t<string>io.github.dividedby.sideload.status</string>
    \t<key>LimitLoadToSessionType</key>
    \t<string>Aqua</string>
    \t<key>LowPriorityIO</key>
    \t<true/>
    \t<key>ProcessType</key>
    \t<string>Background</string>
    \t<key>ProgramArguments</key>
    \t<array>
    \t\t<string>/Users/pat/.local/bin/sideload</string>
    \t\t<string>status</string>
    \t\t<string>--notify</string>
    \t\t<string>--check-updates</string>
    \t</array>
    \t<key>RunAtLoad</key>
    \t<true/>
    \t<key>StandardErrorPath</key>
    \t<string>/Users/pat/.sideload/logs/launchd-status.err</string>
    \t<key>StandardOutPath</key>
    \t<string>/dev/null</string>
    \t<key>StartCalendarInterval</key>
    \t<dict>
    \t\t<key>Hour</key>
    \t\t<integer>9</integer>
    \t\t<key>Minute</key>
    \t\t<integer>0</integer>
    \t</dict>
    </dict>
    </plist>

    """

@Suite("status --print-agent")
struct StatusAgentTests {
    @Test("the default plist is exactly the golden text, and it parses with the planned keys")
    func golden() throws {
        let envelope = StatusCommand.printAgent(agentServices().services, binary: nil)
        #expect(envelope.ok && envelope.command == "status" && envelope.errors.isEmpty)
        let text = try plistText(envelope)
        #expect(text == goldenStatus)
        #expect(envelope.data["label"]?.string == statusLabel)
        #expect(envelope.data["path"]?.string == "/Users/pat/Library/LaunchAgents/\(statusLabel).plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil) as? [String: Any])
        #expect(
            Set(plist.keys) == [
                "Label", "ProgramArguments", "StartCalendarInterval", "RunAtLoad", "ProcessType", "LowPriorityIO",
                "LimitLoadToSessionType", "StandardErrorPath", "StandardOutPath",
            ])
        #expect(plist["RunAtLoad"] as? Bool == true && plist["StartInterval"] == nil && plist["KeepAlive"] == nil)
        let calendar = try #require(plist["StartCalendarInterval"] as? [String: Int])
        #expect(calendar == ["Hour": 9, "Minute": 0])
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/pat/.local/bin/sideload", "status", "--notify", "--check-updates"])
    }

    @Test("the refresh agent's plist is unchanged by the generalisation")
    func refreshUnchanged() throws {
        let text = try plistText(RefreshCommand.printAgent(agentServices().services, binary: nil))
        #expect(text.contains("\t<key>StartInterval</key>\n\t<integer>1800</integer>\n</dict>"))
        #expect(text.contains("\t<key>RunAtLoad</key>\n\t<false/>"))
        #expect(text.contains("<string>refresh</string>\n\t\t<string>--auto</string>"))
        #expect(text.contains("launchd-refresh.err") && !text.contains("StartCalendarInterval"))
    }

    @Test("SIDELOAD_HOME is in the plist only for a non-default home, and the log path follows the home")
    func sideloadHome() throws {
        let other = StatusCommand.printAgent(agentServices(home: "/Volumes/Work/sl").services, binary: "/opt/sl/sideload")
        let text = try plistText(other)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil) as? [String: Any])
        #expect((plist["EnvironmentVariables"] as? [String: String]) == ["SIDELOAD_HOME": "/Volumes/Work/sl"])
        #expect(plist["StandardErrorPath"] as? String == "/Volumes/Work/sl/logs/launchd-status.err")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/sl/sideload", "status", "--notify", "--check-updates"])
        #expect(!(try plistText(StatusCommand.printAgent(agentServices().services, binary: nil))).contains("SIDELOAD_HOME"))
    }

    @Test("the owner's commands: write, lint, bootstrap, kickstart; stopping is only bootout (no kill-switch file)")
    func commands() throws {
        let envelope = StatusCommand.printAgent(agentServices().services, binary: nil)
        let install = try #require(envelope.data["install"]?.array).compactMap(\.string)
        let path = "/Users/pat/Library/LaunchAgents/\(statusLabel).plist"
        #expect(install.count == 5)
        #expect(install[0] == "mkdir -p /Users/pat/Library/LaunchAgents /Users/pat/.sideload/logs")
        #expect(install[1] == "cat > \(path) <<'SIDELOAD_PLIST_END'\n\(goldenStatus)SIDELOAD_PLIST_END")
        #expect(install[2] == "/usr/bin/plutil -lint \(path)")
        #expect(install[3] == "launchctl bootstrap gui/$(id -u) \(path)")
        #expect(install[4] == "launchctl kickstart -k gui/$(id -u)/\(statusLabel)")
        #expect(try #require(envelope.data["stop"]?.array).compactMap(\.string) == ["launchctl bootout gui/$(id -u)/\(statusLabel)"])
    }

    @Test("a relative or control-character --binary is USAGE; nothing is built")
    func badBinary() {
        for binary in ["sideload", "./sideload", "~/.local/bin/sideload", "", "/a/b\nc", "/a/\u{7}b"] {
            let envelope = StatusCommand.printAgent(agentServices().services, binary: binary)
            #expect(!envelope.ok && envelope.errors.first?.code == "USAGE" && envelope.data["plist"] == nil, "\(binary.debugDescription)")
        }
    }

    @Test("through the command line: no subprocess, no file, not even the home; the owner's paths are kept")
    func pure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = fakeServices(Paths(home: dir.path + "/.sideload"))
        var services = made.services
        services.localUser = LocalUser(login: "pat", homeDirectory: dir.path)
        let out = await run(argv: ["status", "--print-agent"], services: services)
        #expect(out.ok && out.exitCode == 0 && out.command == "status")
        #expect(out.data["plist"]?.string?.contains("<string>\(dir.path)/.local/bin/sideload</string>") == true)
        let viaBinary = await run(argv: ["status", "--print-agent", "--binary", "/opt/sl/sideload"], services: services)
        #expect(try plistText(viaBinary).contains("<string>/opt/sl/sideload</string>"))
        #expect(await run(argv: ["status", "--print-agent", "--binary=/opt/sl/sideload"], services: services) == viaBinary)
        #expect(made.runner.calls.isEmpty && listing(dir.path).isEmpty)
        let (_, json) = try StatusCommand.printAgent(agentServices().services, binary: nil).printed()
        #expect(json["plist"]?.string == goldenStatus, "the printed form keeps /Users/pat")
    }

    @Test("a SIDELOAD_HOME with a control character is PATH_UNSAFE")
    func unsafeHome() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = fakeServices(Paths(home: dir.path + "/side\nSIDELOAD_PLIST_END\nload"))
        var services = made.services
        services.localUser = LocalUser(login: "pat", homeDirectory: dir.path)
        let out = await run(argv: ["status", "--print-agent"], services: services)
        #expect(!out.ok && out.errors.first?.code == "PATH_UNSAFE" && out.errors.first?.fix?.contains("status --print-agent") == true)
    }

    @Test("usage combinations: the two modes are alternatives and --binary belongs to --print-agent; plain status is as it was")
    func usage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = fakeServices(Paths(home: dir.path + "/.sideload"))
        var services = made.services
        services.localUser = LocalUser(login: "pat", homeDirectory: dir.path)
        let bad: [[String]] = [
            ["--notify", "--print-agent"], ["--print-agent", "--notify", "--binary", "/opt/sl/sideload"],
            ["--binary", "/opt/sl/sideload"], ["--notify", "--binary", "/opt/sl/sideload"],
            ["--print-agent", "--binary"], ["--print-agent", "--binary", "relative/sideload"], ["--print-agent", "extra"],
            ["--notify", "extra"], ["--print-agent", "--yes"], ["--notify", "--yes"], ["--notify=1"],
            ["--check-updates"], ["--print-agent", "--check-updates"], ["--notify", "--print-agent", "--check-updates"],
            ["--check-updates", "--binary", "/opt/sl/sideload"], ["--notify", "--check-updates", "extra"],
        ]
        for extra in bad {
            let out = await run(argv: ["status"] + extra, services: services)
            #expect(!out.ok && out.exitCode == 1 && out.errors.first?.code == "USAGE" && out.data["plist"] == nil, "\(extra)")
        }
        #expect(made.runner.calls.isEmpty && listing(dir.path).isEmpty)

        // Plain `status` has neither field.
        try await withTestHome { paths, _ in
            let plain = await run(argv: ["status"], services: fakeServices(paths).services)
            #expect(plain.ok && plain.data["notified"] == nil && plain.data["delivered"] == nil)
        }
    }

    @Test("help lists both")
    func help() async {
        let help = await run(argv: ["help"], services: agentServices().services)
        let usage = help.data["usage"]?.array
        #expect(usage?.contains("status --notify [--check-updates]") == true)
        #expect(usage?.contains("status --print-agent [--binary <absolute path>]") == true)
    }
}

// MARK: new-version notices and --check-updates

private let apolloUpdateKey = "update apollo 4.0.2"

private func updateConfig(approved: [JSONValue] = apolloApproved + stremioApproved) -> Config {
    Config(devices: twoDevices, approvedSources: approved, bundleIdPrefix: carrierPrefix)
}

/// An install with the given version and a long-lived signing, so it raises no expiry item of its own.
private func versioned(_ app: ProvisionApp, _ version: String, alias: String = "iphone", present: Bool = true) -> LedgerInstall {
    var record = installRecord(app, alias: alias, present: present)
    record.version = version
    record.profileExpires = daysFromNow(30)
    return record
}

/// `updates.json` as the last check left it: the last good listing per app.
private func writeListing(_ paths: Paths, _ versions: [String: String], at date: Date = testNow) throws {
    var cache = UpdateCache()
    for (app, version) in versions {
        cache.apps[app] = UpdateCacheEntry(
            checkedAt: date, version: version, build: nil, minOS: nil, size: 2000, sha256: String(repeating: "ab", count: 32))
    }
    try UpdateCacheStore(paths: paths).save(cache)
}

private func apolloMetadata(_ version: String) -> Data {
    releaseJSON(
        tag: "v1.15.11_\(version)",
        assets: apolloDecoys(version: version) + [ReleaseAsset(name: "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa")])
}

/// Every GET fails on the wire.
private final class BrokenHTTP: HTTPTransport {
    func get(_ request: HTTPRequest) async throws -> HTTPResponse { throw HTTPTransportError.failed }
    func download(_ request: DownloadRequest, sink: @Sendable (Data) throws -> Void) async throws -> DownloadResponse {
        throw HTTPTransportError.disabled
    }
}

private let checkArgv = ["status", "--notify", "--check-updates"]

@Suite("status --notify: new versions")
struct StatusNotifyUpdateTests {
    @Test("a newer cached version for an installed, approved app is one item, announced once per version")
    func oncePerVersion() async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && out.warningCodes == [])
            #expect(runner.calls.count == 1 && runner.message == "Apollo 4.0.2 available")
            #expect(out.json["notified"] == [["item": .string(apolloUpdateKey), "threshold": 0]])
            #expect(out.json["delivered"] == true)
            #expect(home.stored() == [apolloUpdateKey: 0])

            let again = try await home.notify(runner)
            #expect(runner.calls.count == 1 && again.notified == [] && again.json["delivered"] == false)
            #expect(home.stored() == [apolloUpdateKey: 0])

            // A newer one after that is a new item; the old key goes.
            try writeListing(home.paths, ["apollo": "4.0.3"])
            let next = try await home.notify(runner)
            #expect(next.notified == ["update apollo 4.0.3"] && runner.message == "Apollo 4.0.3 available")
            #expect(home.stored() == ["update apollo 4.0.3": 0])
        }
    }

    @Test("a version that is equal, older or not understood says nothing", arguments: [
        ("4.0.2", "4.0.2"), ("4.0.3", "4.0.2"), ("1.9.5", "1.9.6b142"), ("4.0.1", "latest"),
    ])
    func notNewer(installed: String, upstream: String) async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, installed)])) { home in
            try writeListing(home.paths, ["apollo": upstream])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && runner.calls.isEmpty && out.notified == [] && home.stored().isEmpty)
        }
    }

    @Test("an entry with only an error, a source not approved, and an app not installed on a saved device say nothing")
    func notApplicable() async throws {
        // Error only: no version to compare.
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            var cache = UpdateCache()
            cache.apps["apollo"] = UpdateCacheEntry().failed(code: "FETCH_HTTP_ERROR", retryAfter: nil, at: testNow)
            try UpdateCacheStore(paths: home.paths).save(cache)
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && runner.calls.isEmpty && out.notified == [])
        }
        // Not approved.
        try await withNotifyHome(config: updateConfig(approved: stremioApproved), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let runner = PostRunner()
            #expect(try await home.notify(runner).notified == [] && runner.calls.isEmpty)
        }
        // Installed on a device that is not saved, recorded absent, or another app.
        let ledger = Ledger(installs: [
            versioned(.apollo, "4.0.1", alias: "retired"), versioned(.apollo, "4.0.1", present: false),
            versioned(.stremioIOS, "1.9.5b100"),
        ])
        try await withNotifyHome(config: updateConfig(), ledger: ledger) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let runner = PostRunner()
            #expect(try await home.notify(runner).notified == [] && runner.calls.isEmpty && home.stored().isEmpty)
        }
    }

    @Test("newer than one of two installs is one item")
    func oneOfTwoDevices() async throws {
        let ledger = Ledger(installs: [versioned(.apollo, "4.0.2"), versioned(.apollo, "4.0.1", alias: "appletv")])
        try await withNotifyHome(config: updateConfig(), ledger: ledger) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.notified == [apolloUpdateKey] && runner.calls.count == 1)
        }
    }

    @Test("the key goes once every install has caught up, and a rollback announces the version again")
    func pruneAndRollback() async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let runner = PostRunner()
            #expect(try await home.notify(runner).notified == [apolloUpdateKey])
            try await home.setLedger(Ledger(installs: [versioned(.apollo, "4.0.2")]))
            let caughtUp = try await home.notify(runner)
            #expect(caughtUp.notified == [] && runner.calls.count == 1 && home.stored().isEmpty)
            try await home.setLedger(Ledger(installs: [versioned(.apollo, "4.0.1")]))
            #expect(try await home.notify(runner).notified == [apolloUpdateKey] && runner.calls.count == 2)
        }
    }

    @Test("a missing, corrupt, unreadable or version-less updates.json prunes no update key", arguments: [
        "missing", "corrupt", "wrong schema", "folder", "errors only",
    ])
    func noPruneWithoutTheFile(file: String) async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            try await home.setStored([apolloUpdateKey: 0])
            let path = home.paths.updates
            switch file {
            case "corrupt": try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))
            case "wrong schema": try Data(#"{"schema": 99, "apps": {}}"#.utf8).write(to: URL(fileURLWithPath: path))
            // Reading a folder fails with an I/O error.
            case "folder": try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            case "errors only":
                var cache = UpdateCache()
                cache.apps["apollo"] = UpdateCacheEntry().failed(code: "FETCH_HTTP_ERROR", retryAfter: nil, at: testNow)
                try UpdateCacheStore(paths: home.paths).save(cache)
            default: break
            }
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.envelope.ok && runner.calls.isEmpty && home.stored() == [apolloUpdateKey: 0], "\(file)")
            // A real listing that is not newer does prune it.
            try? FileManager.default.removeItem(atPath: path)
            try writeListing(home.paths, ["apollo": "4.0.1"])
            _ = try await home.notify(runner)
            #expect(home.stored().isEmpty, "\(file)")
        }
    }

    @Test("the same version newer on both Stremio builds is said once and recorded twice")
    func stremioBothBuilds() async throws {
        let ledger = Ledger(installs: [versioned(.stremioIOS, "1.9.5b100"), versioned(.stremioTVOS, "1.9.5b100", alias: "appletv")])
        try await withNotifyHome(config: updateConfig(), ledger: ledger) { home in
            try writeListing(home.paths, ["stremio-ios": "1.9.6b142", "stremio-tvos": "1.9.6b142"])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(runner.message == "Stremio 1.9.6b142 available")
            #expect(out.notified == ["update stremio-ios 1.9.6b142", "update stremio-tvos 1.9.6b142"])
            #expect(home.stored() == ["update stremio-ios 1.9.6b142": 0, "update stremio-tvos 1.9.6b142": 0])
        }
    }

    @Test("Stremio's version form passes the sanitiser whole")
    func stremioForm() async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.stremioIOS, "1.9.5b100")])) { home in
            try writeListing(home.paths, ["stremio-ios": "1.9.6b142"])
            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.notified == ["update stremio-ios 1.9.6b142"])
            #expect(runner.message == "Stremio 1.9.6b142 available")
            #expect(Notifier.sanitised(Notifier.updateAvailable(app: "stremio-tvos", version: "1.9.6b142")) == "Stremio 1.9.6b142 available")
        }
    }

    @Test("expiry items come first and the update last; a failed post records nothing")
    func orderAndFailedPost() async throws {
        let ledger = Ledger(installs: [install(.stremioIOS, days: 2), versioned(.apollo, "4.0.1")])
        try await withNotifyHome(config: updateConfig(), ledger: ledger) { home in
            try writeListing(home.paths, ["apollo": "4.0.2"])
            let failing = PostRunner(RunResult(code: 1, stderr: "not allowed"))
            let failed = try await home.notify(failing)
            #expect(failed.warningCodes.contains("NOTIFY_FAILED") && failed.notified == [] && home.stored().isEmpty)
            #expect(failing.message == "stremio-ios @ iphone 2 d left, Apollo 4.0.2 available")

            let runner = PostRunner()
            let out = try await home.notify(runner)
            #expect(out.notified == [installKey, apolloUpdateKey] && runner.message == failing.message)
            #expect(home.stored() == [installKey: 3, apolloUpdateKey: 0])
        }
    }

    @Test("when the message is full, the updates are the ones left out")
    func capDropsUpdatesFirst() {
        let expiry = (1...6).map { "stremio-ios @ device\($0) 3 d left" }
        let crowded = Notifier.combined(expiry + [Notifier.updateAvailable(app: "apollo", version: "4.0.2")])
        #expect(!crowded.contains("Apollo") && crowded.hasSuffix(" more") && crowded.count <= Notifier.maxLength)
        let roomy = Notifier.combined(Array(expiry.prefix(2)) + [Notifier.updateAvailable(app: "apollo", version: "4.0.2")])
        #expect(roomy.hasSuffix("Apollo 4.0.2 available"))
    }

    @Test("the pure item list: approved apps with an installed older version, ordered by key")
    func pureItems() {
        let installs = [versioned(.stremioIOS, "1.9.5b100"), versioned(.apollo, "4.0.1")]
        let items = StatusNotify.updates(
            installs: installs, approved: ["apollo", "stremio-ios"],
            upstream: ["stremio-ios": "1.9.6b142", "apollo": "4.0.2", "stremio-tvos": "1.9.6b142"])
        #expect(items.map(\.key) == [apolloUpdateKey, "update stremio-ios 1.9.6b142"])
        #expect(items.map(\.threshold) == [0, 0])
        #expect(StatusNotify.updates(installs: installs, approved: ["apollo"], upstream: ["stremio-ios": "1.9.6b142"]).isEmpty)
    }
}

@Suite("status --notify --check-updates")
struct StatusCheckUpdatesTests {
    @Test("without the flag there is no network call, with or without --notify")
    func noFlagNoHTTP() async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            let http = FakeFetchTransport(metadata: [apolloAPI: apolloMetadata("4.0.2")])
            let runner = PostRunner()
            let out = try await home.notify(runner, http: http)
            #expect(out.envelope.ok && out.json["updateCheck"] == ["ran": false, "checked": 0, "replayed": 0, "failed": 0])
            var (services, _) = fakeServices(home.paths)
            services.http = http
            let plain = await run(argv: ["status"], services: services)
            #expect(plain.ok && plain.data["updateCheck"] == nil)
            #expect(http.callCount == 0 && !FileManager.default.fileExists(atPath: home.paths.updates))
        }
    }

    @Test("one GET per approved installed source, the result announced, a second run answered from updates.json")
    func oneGetPerSource() async throws {
        let ledger = Ledger(installs: [versioned(.apollo, "4.0.1"), versioned(.stremioIOS, "1.9.5b100")])
        // stremio-tvos is approved but has no install, so it is not asked.
        try await withNotifyHome(config: updateConfig(), ledger: ledger) { home in
            let http = FakeFetchTransport(metadata: [
                apolloAPI: apolloMetadata("4.0.2"), stremioIOSIndex: stremioIndexJSON(tvos: false),
                stremioTVOSIndex: stremioIndexJSON(tvos: true),
            ])
            let runner = PostRunner()
            let out = try await home.notify(runner, argv: checkArgv, http: http)
            #expect(out.envelope.ok && out.warningCodes == [])
            #expect(http.getRequests.map(\.url.absoluteString).sorted() == [apolloAPI, stremioIOSIndex].sorted())
            #expect(http.downloadRequests.isEmpty)
            #expect(out.json["updateCheck"] == ["ran": true, "checked": 2, "replayed": 0, "failed": 0])
            #expect(out.notified == [apolloUpdateKey, "update stremio-ios 1.9.6b142"])
            #expect(runner.message == "Apollo 4.0.2 available, Stremio 1.9.6b142 available")

            let again = try await home.notify(runner, argv: checkArgv, http: http)
            #expect(http.callCount == 2 && runner.calls.count == 1)
            #expect(again.json["updateCheck"] == ["ran": true, "checked": 0, "replayed": 2, "failed": 0])
            #expect(again.notified == [] && again.warningCodes == [])
        }
    }

    @Test("a failed check (404, transport error) is a warning, never a failure, and the file still speaks")
    func failedCheck() async throws {
        for wire in ["404", "broken"] {
            try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
                try writeListing(home.paths, ["apollo": "4.0.2"])
                let http: any HTTPTransport = wire == "404" ? FakeFetchTransport(metadata: [:]) : BrokenHTTP()
                let runner = PostRunner()
                // A day later, so the listing is due for a new check.
                let out = try await home.notify(runner, shift: 1, argv: checkArgv, http: http)
                #expect(out.envelope.ok && out.envelope.exitCode == 0, "\(wire)")
                #expect(out.warningCodes == ["UPDATE_CHECK_FAILED"], "\(wire)")
                #expect(out.json["updateCheck"] == ["ran": true, "checked": 1, "replayed": 0, "failed": 1], "\(wire)")
                let message = out.json["warnings"]?.array?.first?["message"]?.string ?? ""
                #expect(!message.contains("http") && !message.contains("github"), "\(wire)")
                // The last good listing is still there, so the notice goes out.
                #expect(out.notified == [apolloUpdateKey] && runner.message == "Apollo 4.0.2 available", "\(wire)")
            }
        }
    }

    @Test("a check that cannot run at all (unreadable ledger) is the same warning, and the notification step still runs")
    func checkThrows() async throws {
        try await withNotifyHome(config: updateConfig(), ledger: Ledger(installs: [versioned(.apollo, "4.0.1")])) { home in
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: home.paths.ledger))
            let http = FakeFetchTransport(metadata: [apolloAPI: apolloMetadata("4.0.2")])
            let runner = PostRunner()
            let out = try await home.notify(runner, argv: checkArgv, http: http)
            #expect(out.envelope.ok && out.warningCodes.contains("UPDATE_CHECK_FAILED"))
            #expect(out.json["updateCheck"] == ["ran": true, "checked": 0, "replayed": 0, "failed": 1])
            #expect(http.callCount == 0 && runner.calls.isEmpty)
        }
    }

    @Test("the flag parses with --notify only; alone or with --print-agent it is USAGE and nothing is touched")
    func parsing() async throws {
        try await withNotifyHome(config: updateConfig()) { home in
            let http = FakeFetchTransport(metadata: [:])
            for argv in [["status", "--check-updates"], ["status", "--check-updates", "--print-agent"]] {
                let out = try await home.notify(PostRunner(), argv: argv, http: http)
                #expect(!out.envelope.ok && out.envelope.errors.first?.code == "USAGE" && out.envelope.exitCode == 1, "\(argv)")
            }
            let ok = try await home.notify(PostRunner(), argv: checkArgv, http: http)
            #expect(ok.envelope.ok && ok.json["updateCheck"]?["ran"] == true)
            #expect(http.downloadRequests.isEmpty)
        }
    }
}
