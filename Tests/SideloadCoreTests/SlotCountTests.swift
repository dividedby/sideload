import Foundation
import Testing

@testable import SideloadCore

// The live free-slot count: our apps + the other free-team apps found by their installed profiles (the lab's WebDriverAgent
// counts inside the slot lent to it) + the lent slot, with the reserve as a floor. TestFlight betas are `builtByDeveloper`
// too but their profiles belong to other teams, so they never count. installd's refusal is the backstop.

private let lentStremio = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))
private let testFlight: [String] = (1...5).map { "com.example.testflight.beta\($0)" }
private let installdLimit: InstallBehaviour = .fail(json: (try? loadFixtureJSON("install-free-app-limit.json")) ?? nil)

private func apps(_ ids: [String]) -> [String: Bool] { Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }) }

private func slots(_ out: Envelope) -> JSONValue { json(out)["slots"] ?? .null }

private func freeProfiles(_ ids: [String]) -> FreeTeamProfiles { FreeTeamProfiles(bundleIds: Set(ids)) }

@Suite("free slot count")
struct SlotCountTests {
    // MARK: the pure count

    @Test("the lab's case (a): Stremio lent, WebDriverAgent installed, apollo installed: used 2, free 1")
    func labCaseA() {
        let snapshot = AppSnapshot(apps: apps([apolloId, wdaId]))
        let usage = snapshot.usage(prefix: carrierPrefix, reserved: 0, outside: .init(lent: 1), profiles: freeProfiles([wdaId]))
        #expect(usage.managed == 1 && usage.labApps == 1 && usage.otherNonLab == 0)
        #expect(usage.unmanaged == 0, "the lab's app lives in the lent slot")
        #expect(usage.used == 2 && usage.free == 1)
    }

    @Test("case (b): Stremio lent, WebDriverAgent not installed yet, a SideStore-like app installed: apollo + other + lent = 3")
    func labCaseB() {
        let snapshot = AppSnapshot(apps: apps([apolloId, sideStoreId]))
        let usage = snapshot.usage(prefix: carrierPrefix, reserved: 0, outside: .init(lent: 1), profiles: freeProfiles([sideStoreId]))
        #expect(usage.labApps == 0 && usage.otherNonLab == 1)
        #expect(usage.used == 3 && usage.free == 0)
    }

    @Test("case (c): not lent, WebDriverAgent installed: it counts 1; a reserve standing for it is not added on top")
    func labCaseC() {
        let snapshot = AppSnapshot(apps: apps([apolloId, wdaId]))
        let plain = snapshot.usage(prefix: carrierPrefix, reserved: 0, profiles: freeProfiles([wdaId]))
        #expect(plain.unmanaged == 1 && plain.used == 2)
        let reserved = snapshot.usage(prefix: carrierPrefix, reserved: 1, profiles: freeProfiles([wdaId]))
        #expect(reserved.unmanaged == 1 && reserved.used == 2, "reserve 1 with WebDriverAgent counted: unmanaged 1, not 2")
    }

    @Test("the lent slot and the lab's app count once; two lab apps in one lent slot count as two")
    func labOnce() {
        let one = AppSnapshot(apps: apps([apolloId, wdaId, sideStoreId]))
        let usage = one.usage(prefix: carrierPrefix, reserved: 0, outside: .init(lent: 1), profiles: freeProfiles([wdaId, sideStoreId]))
        #expect(usage.used == 3, "apollo + SideStore + (lent slot holding WebDriverAgent)")
        let none = one.usage(prefix: carrierPrefix, reserved: 0, outside: .init(lent: 1), profiles: freeProfiles([]))
        #expect(none.otherFreeTeamApps == 0 && none.used == 2)
    }

    @Test("a pending install of another app is not lent: WebDriverAgent and the pending apollo count as 2, not 1")
    func pendingIsNotLent() async throws {
        try await withInstallWorld { w in
            let op = LedgerSlotOp(kind: .install, by: .install, startedAt: testNow, window: 645)
            var ledger = Ledger()
            ledger.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, op: op)]
            let book = SlotBook(services: w.services, config: try w.config(), alias: "iphone")
            let snapshot = AppSnapshot(apps: apps([wdaId]))
            let outside = book.usedOutsideSnapshot(ledger, excluding: "stremio-ios", snapshot: snapshot)
            #expect(outside.lent == 0 && outside.pending == 1 && outside.total == 1)

            let usage = snapshot.usage(
                prefix: carrierPrefix, reserved: 0, outside: outside, profiles: freeProfiles([wdaId]))
            #expect(usage.labApps == 1 && usage.unmanaged == 1)
            #expect(usage.used == 2 && usage.free == 1, "WDA does not live in a pending slot")

            // A lent slot as well: WDA lives in the lent one, the pending apollo is still its own.
            ledger.slots.append(LedgerSlot(device: "iphone", app: "stremio-ios", presence: .absent, lentTo: "lab", since: testNow))
            let both = book.usedOutsideSnapshot(ledger, excluding: "filler", snapshot: snapshot)
            #expect(both.lent == 1 && both.pending == 1)
            let together = snapshot.usage(
                prefix: carrierPrefix, reserved: 0, outside: both, profiles: freeProfiles([wdaId]))
            #expect(together.unmanaged == 0 && together.used == 2)
        }
    }

    @Test("TestFlight betas are developer-built but have no free-team profile: informational only")
    func testFlightIgnored() {
        let snapshot = AppSnapshot(apps: apps([apolloId, stremioId, wdaId] + testFlight))
        let usage = snapshot.usage(prefix: carrierPrefix, reserved: 0, profiles: freeProfiles([wdaId]))
        #expect(usage.otherDeveloperApps == 6 && usage.otherFreeTeamApps == 1 && usage.unmanaged == 1)
        #expect(usage.used == 3)
    }

    @Test("no profile read: the reserve alone, as before; and the profile document is parsed strictly")
    func fallbackAndParsing() {
        let snapshot = AppSnapshot(apps: apps([apolloId, wdaId]))
        let usage = snapshot.usage(prefix: carrierPrefix, reserved: 1, outside: .init(lent: 1))
        #expect(!usage.profilesRead && usage.otherFreeTeamApps == nil && usage.unmanaged == 1 && usage.used == 3)

        func profile(_ team: JSONValue, _ app: JSONValue) -> JSONValue { ["teamIdentifier": team, "appIdentifier": app] }
        func doc(_ rows: [JSONValue]) -> JSONValue { ["info": ["outcome": "success"], "result": ["provisioningProfiles": .array(rows)]] }
        let free = JSONValue.string(Team.free)
        let parsed = FreeTeamProfiles.parse(
            doc([profile(free, .string("\(Team.free).\(wdaId)")), profile("OTHERTEAM1", .string("OTHERTEAM1.\(sideStoreId)")), profile(free, "garbage")]))
        #expect(parsed?.bundleIds == [wdaId], "other teams' IDs are dropped, a malformed free appIdentifier is ignored")
        #expect(FreeTeamProfiles.parse(nil) == nil)
        #expect(FreeTeamProfiles.parse(["result": ["provisioningProfiles": []]]) == nil, "no info.outcome:success")
        #expect(FreeTeamProfiles.parse(["info": ["outcome": "success"], "result": [:]]) == nil)
        #expect(FreeTeamProfiles.parse(["info": ["outcome": "success"], "result": ["provisioningProfiles": "x"]]) == nil)
        #expect(FreeTeamProfiles.parse(doc([profile(5, "x")])) == nil, "a non-string team makes the whole read fail")
        #expect(FreeTeamProfiles.parse(doc([profile(free, .null)])) == nil)
        #expect(FreeTeamProfiles.parse(doc([]))?.bundleIds == [], "no profiles is a valid read")
    }

    // MARK: install

    @Test("the owner's phone, WebDriverAgent gone: our 2 + 5 TestFlight betas leave room, and the filler installs")
    func fillerPassesWithoutWda() async throws {
        let script = DeviceScript(initial: apps([apolloId, stremioId] + testFlight), otherTeamApps: Set(testFlight))
        try await withInstallWorld(app: .filler, script: script) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            let slots = slots(out)
            #expect(slots["unmanaged"] == 0 && slots["used"] == 3 && slots["profilesRead"] == true)
            #expect(slots["otherFreeTeamApps"] == 0 && slots["labApps"] == 0 && slots["otherNonLab"] == 0)
            #expect(slots["otherDeveloperApps"] == 5)
            #expect(w.runner.profileCalls.count == 1)
            let argv = try #require(w.runner.profileCalls.first?.args)
            #expect(argv.contains("provisioning") && argv.contains("--type") && !argv.contains("install") && !argv.contains("remove"))
            try w.expectClean(out)
            for id in testFlight { #expect(!(try out.printed().text).contains(id)) }
        }
    }

    @Test("WebDriverAgent present (our 2 + WDA): a NEW app is refused before any install call; TestFlight is ignored")
    func newAppRefusedWithWda() async throws {
        let script = DeviceScript(initial: apps([apolloId, stremioId, wdaId] + testFlight), otherTeamApps: Set(testFlight))
        try await withInstallWorld(app: .filler, script: script) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            let slots = json(out)["slots"] ?? .null
            #expect(slots["used"] == 3 && slots["unmanaged"] == 1 && slots["labApps"] == 1 && slots["otherDeveloperApps"] == 6)
            #expect(w.runner.installCalls.isEmpty && w.installs.isEmpty)
            #expect(!(try out.printed().text).contains("testflight"))
            try w.expectClean(out)
        }
    }

    @Test("a reinstall of our own app is slot-neutral even when the device is full")
    func reinstallNeutral() async throws {
        let script = DeviceScript(initial: apps([apolloId, stremioId, wdaId]))
        try await withInstallWorld(script: script) { w in
            let out = await w.install()
            #expect(out.ok && json(out)["reinstall"] == true, "\(out.errors)")
        }
    }

    @Test("reserve 1 with WebDriverAgent counted: unmanaged 1, not 2")
    func reserveNotAddedToWda() async throws {
        try await withInstallWorld(script: DeviceScript(initial: apps([apolloId, wdaId])), reserved: 1) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(slots(out)["unmanaged"] == 1 && slots(out)["used"] == 3)
        }
    }

    @Test("a stale free-team profile whose app is not on the device is not counted")
    func staleProfile() async throws {
        let script = DeviceScript(initial: apps([apolloId]), staleFreeProfiles: [wdaId, sideStoreId])
        try await withInstallWorld(script: script) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(slots(out)["unmanaged"] == 0 && slots(out)["used"] == 2 && slots(out)["otherFreeTeamApps"] == 0)
        }
    }

    @Test("a failed or malformed profile read falls back to the reserve; installd stays the backstop", arguments: [
        ProfileListBehaviour.fail, .malformed,
    ])
    func fallbackToReserve(behaviour: ProfileListBehaviour) async throws {
        // WebDriverAgent is there but unseen: the preflight lets the install through, installd refuses it.
        let script = DeviceScript(initial: apps([apolloId, stremioId, wdaId]), install: installdLimit, profileList: behaviour)
        try await withInstallWorld(app: .filler, script: script) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            let printed = try out.printed()
            #expect(!w.runner.installCalls.isEmpty, "the preflight did not stop it: only the reserve was known")
            #expect(printed.json["slots"]?["profilesRead"] == false && printed.json["slots"]?["otherFreeTeamApps"] == .null)
            #expect(printed.json["installdList"] != nil)
            #expect(w.installs.isEmpty, "nothing is recorded as present")
            #expect(w.slotRecord("filler") == nil || w.slotRecord("filler")?.op == nil)
        }
        let reserved = DeviceScript(initial: apps([apolloId, stremioId]), profileList: behaviour)
        try await withInstallWorld(app: .filler, script: reserved, reserved: 1) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"], "the reserve alone fills the device")
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    @Test("installd's refusal on a plain install is FREE_APP_LIMIT with nothing present, and the next command is not SLOT_PENDING")
    func installdRefusalClosesTheOp() async throws {
        let script = DeviceScript(initial: apps([apolloId] + testFlight), install: installdLimit, otherTeamApps: Set(testFlight))
        try await withInstallWorld(script: script) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(json(out)["uncertain"] == nil && json(out)["pending"] == nil)
            #expect(w.installs.isEmpty, "nothing recorded as present")
            #expect(w.slotRecord()?.op == nil, "the op is closed")
            try expectSlotModel(w)
            let again = await w.install()
            #expect(again.errorCodes == ["FREE_APP_LIMIT"], "runs again, no 435/645 s window")
            #expect((await w.slot("lend", device: "iphone", to: "lab")).errorCodes != ["SLOT_PENDING"])
        }
    }

    @Test("the lab's case (a) end to end: Stremio lent, WDA + apollo installed: a new app passes, and the lent slot counts once")
    func labInstallPasses() async throws {
        try await withInstallWorld(app: .filler, script: DeviceScript(initial: apps([apolloId, wdaId])), ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            #expect(slots(out)["lent"] == 1 && slots(out)["labApps"] == 1 && slots(out)["used"] == 3)
        }
    }

    @Test("case (b) end to end: Stremio lent, WDA not installed, SideStore installed: used 3, a new app is refused")
    func labInstallRefused() async throws {
        let script = DeviceScript(initial: apps([apolloId, sideStoreId]))
        try await withInstallWorld(app: .filler, script: script, ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            #expect(slots(out)["used"] == 3 && slots(out)["lent"] == 1 && slots(out)["otherNonLab"] == 1 && slots(out)["labApps"] == 0)
            #expect(w.runner.installCalls.isEmpty)
        }
    }

    // MARK: slot return

    @Test("slot return passes when the device is full only because of its own lent slot (apollo + filler, WDA absent)")
    func returnIntoOwnLentSlot() async throws {
        let script = DeviceScript(initial: apps([apolloId, fillerId] + testFlight), otherTeamApps: Set(testFlight))
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok, "\(out.errors)")
            #expect(json(out)["reinstalled"] == true)
            #expect(w.runner.deviceApps.keys.contains(stremioId))
            #expect(w.lent.isEmpty)
            try expectSlotModel(w, eventually: true)
        }
    }

    @Test("slot return with WebDriverAgent still installed is refused by the preflight and lent is kept; nothing is pending")
    func returnRefusedWithWda() async throws {
        let script = DeviceScript(initial: apps([apolloId, fillerId, wdaId]))
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["cause"] == "FREE_APP_LIMIT")
            #expect(json(out)["uncertain"] == nil || json(out)["uncertain"] == false)
            #expect(w.lent == [lentStremio] && w.runner.installCalls.isEmpty)
            let again = await w.slot("return", device: "iphone")
            #expect(again.errorCodes == ["RETURN_FAILED"] && json(again)["cause"] == "FREE_APP_LIMIT")
            try expectSlotModel(w)
        }
    }

    @Test("installd's limit refusal on a return: RETURN_FAILED/FREE_APP_LIMIT, not uncertain, the op closed, lent kept, no window")
    func returnInstalldRefusal() async throws {
        // The profile read fails, so the preflight cannot see WebDriverAgent and installd decides.
        let script = DeviceScript(initial: apps([apolloId, fillerId, wdaId]), install: installdLimit, profileList: .fail)
        try await withInstallWorld(script: script, lendable: "stremio-ios", ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.errorCodes == ["RETURN_FAILED"] && json(out)["cause"] == "FREE_APP_LIMIT")
            #expect(json(out)["uncertain"] == nil || json(out)["uncertain"] == false)
            #expect(!w.runner.installCalls.isEmpty, "installd was asked")
            #expect(w.lent == [lentStremio])
            let record = try #require(w.slotRecord())
            #expect(record.op == nil && record.presence == .absent && record.lentTo == "lab", "closed: effect absent, lent kept")
            try expectSlotModel(w)

            let again = await w.slot("return", device: "iphone")
            #expect(again.errorCodes != ["SLOT_PENDING"] && json(again)["cause"] == "FREE_APP_LIMIT")
            let lend = await w.slot("lend", device: "iphone", to: "lab")
            #expect(lend.errorCodes != ["SLOT_PENDING"], "\(lend.errors)")
            try expectSlotModel(w)
        }
    }

    // MARK: profile reads are read-only

    @Test("every slots object has the same keys: install, its FREE_APP_LIMIT refusals, slot return and app remove")
    func sameKeysEverywhere() async throws {
        let expected: Set<String> = [
            "limit", "used", "free", "reserved", "managed", "unmanaged", "lent", "pending", "otherDeveloperApps",
            "otherFreeTeamApps", "labApps", "otherNonLab", "profilesRead",
        ]
        func keys(_ value: JSONValue?) -> Set<String> {
            if case .object(let object)? = value { return Set(object.keys) }
            return []
        }
        var seen: [String: Set<String>] = [:]
        try await withInstallWorld(script: DeviceScript(initial: apps([apolloId]))) { w in
            let out = await w.install()
            #expect(out.ok, "\(out.errors)")
            seen["install"] = keys(slots(out))
        }
        try await withInstallWorld(app: .filler, script: DeviceScript(initial: apps([apolloId, stremioId, wdaId]))) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            seen["preflight refusal"] = keys(slots(out))
        }
        try await withInstallWorld(app: .filler, script: DeviceScript(initial: apps([apolloId, stremioId]), install: installdLimit, profileList: .fail)) { w in
            let out = await w.install()
            #expect(out.errorCodes == ["FREE_APP_LIMIT"])
            seen["installd refusal"] = keys(slots(out))
        }
        try await withInstallWorld(script: DeviceScript(initial: apps([apolloId])), lendable: "stremio-ios", ledger: { $0.lent = [lentStremio] }) { w in
            let out = await w.slot("return", device: "iphone")
            #expect(out.ok, "\(out.errors)")
            seen["slot return"] = keys(slots(out))
        }
        try await withInstallWorld(script: DeviceScript(initial: apps([stremioId, apolloId]))) { w in
            let out = await w.remove()
            #expect(out.ok, "\(out.errors)")
            seen["app remove"] = keys(slots(out))
            #expect(slots(out)["lent"] == 0 && slots(out)["pending"] == 0)
        }
        #expect(seen.count == 5)
        for (name, found) in seen { #expect(found == expected, "\(name): \(found.symmetricDifference(expected).sorted())") }
        // The unknown row (an out-of-range stored reserve) has the same keys, all null, plus `unknown`.
        let unknown = AppSnapshot.Usage.unknownJSON
        #expect(keys(unknown) == expected.union(["unknown"]))
        if case .object(let object) = unknown {
            #expect(object["unknown"] == true && object["profilesRead"] == false)
            let counts = object.filter { !["unknown", "limit", "profilesRead"].contains($0.key) }
            #expect(counts.values.allSatisfy { $0 == .null }, "no count is guessed")
        }
    }

    @Test("devicectl refuses any profile call but the read-only `profile list --type provisioning`")
    func onlyProfileList() async throws {
        try await withInstallWorld { w in
            for args in [
                ["device", "profile", "install"], ["device", "profile", "remove"], ["device", "profile", "validate"],
                ["device", "profile", "list"], ["device", "profile", "list", "--type", "configuration"],
                ["device", "profile", "list", "--type", "provisioning", "install"],
            ] {
                do {
                    _ = try await w.services.deviceCtl.run(args, deviceAlias: "iphone", scope: .free(bundleId: stremioId))
                    Issue.record("\(args) was allowed")
                } catch let error as SideloadError {
                    #expect(error.code == "BUNDLE_ID_NOT_ALLOWED", "\(args)")
                }
            }
            // The words may also be split between the flags and the positionals.
            for (args, positional) in [
                (["device"], ["profile", "remove"]), (["device", "profile"], ["remove"]), (["device", "profile"], ["validate"]),
                (["device", "profile", "list", "--type", "provisioning"], ["remove"]),
                (["device", "profile", "list", "--type", "provisioning"], ["/tmp/x.mobileprovision"]),
                (["device", "info", "apps"], ["profile"]), (["device", "info", "apps"], ["remove"]),
                (["device", "profile", "list", "--type", "provisioning", "--type", "configuration"], []),
                (["device", "profile", "list", "--type", "provisioning", "--verbose"], []),
                (["device", "profile", "install", "--type", "provisioning"], []),
            ] {
                do {
                    _ = try await w.services.deviceCtl.run(
                        args, deviceAlias: "iphone", positional: positional, scope: .free(bundleId: stremioId))
                    Issue.record("\(args) + \(positional) was allowed")
                } catch let error as SideloadError {
                    #expect(error.code == "BUNDLE_ID_NOT_ALLOWED", "\(args) + \(positional)")
                }
            }
            #expect(DeviceCtl.profileListArgs == ["device", "profile", "list", "--type", "provisioning"])
            #expect(w.runner.calls.isEmpty, "none of them reached a subprocess")
            let read = try await w.services.deviceCtl.run(
                ["device", "profile", "list", "--type", "provisioning"], deviceAlias: "iphone", scope: .free(bundleId: stremioId))
            #expect(read.code != nil || read.json != nil || read.spawnError == nil)
            #expect(w.runner.profileCalls.count == 1)
        }
    }

    @Test("no source calls `device profile install`, `remove` or `validate`; the only profile call is the read in FreeDevice.swift (and DeviceCtl.swift allowlists it)")
    func sourcesNeverWriteProfiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let banned = try NSRegularExpression(
            pattern: #"profiles?"\s*,\s*"(install|remove|validate|uninstall|add|delete|copy|sync)"|profile\s+(install|remove|validate)\b"#,
            options: [.caseInsensitive])
        var callers: [String] = []
        var seen = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            seen += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(location: 0, length: (text as NSString).length)
            #expect(banned.numberOfMatches(in: text, range: range) == 0, "\(url.lastPathComponent) names a profile write")
            if text.contains(#""device", "profile", "list""#) { callers.append(url.lastPathComponent) }
        }
        #expect(seen > 20)
        #expect(callers.sorted() == ["DeviceCtl.swift", "FreeDevice.swift"], "the read and the wrapper allowlist only: \(callers)")
    }
}
