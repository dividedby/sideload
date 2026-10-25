import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// The ledger's `freeSigned` record and the CLI wiring of `sign`.

private func signedEntry(_ id: String = "iphone/stremio-ios") -> LedgerFreeSigned {
    LedgerFreeSigned(
        id: id, device: "iphone", app: "stremio-ios", bundleId: stremioId, version: "1.9.6b142", sha256Prefix: "0a1b2c3d",
        profileUuid: signProfileUUID, profileExpires: daysFromNow(5), certFp8: "12345678", signedAt: testNow,
        path: "builds/signed/stremio-ios/iphone/Stremio.app",
        strippedExtensions: [LedgerStrippedExtension(path: "PlugIns/W.appex", bundleId: "com.stremio.pal.w")],
        droppedEntitlements: ["aps-environment"])
}

@Suite("Ledger freeSigned")
struct LedgerFreeSignedTests {
    @Test("a ledger that never signed is byte-identical to before: no freeSigned key")
    func absentWhenEmpty() throws {
        let text = String(decoding: try LedgerStore.encode(Ledger()), as: UTF8.self)
        #expect(!text.contains("freeSigned"))
        let signed = String(decoding: try LedgerStore.encode(Ledger(freeSigned: [signedEntry()])), as: UTF8.self)
        #expect(signed.contains("\"freeSigned\""))
    }

    @Test("an entry survives a round trip, together with the provision records and unknown keys")
    func roundTrip() throws {
        let ledger = Ledger(
            freeProfiles: [
                LedgerFreeProfile(
                    id: "iphone/stremio-ios", device: "iphone", deviceTail: "…AAA1", app: "stremio-ios", bundleId: stremioId,
                    profileUuid: signProfileUUID, created: nil, expires: daysFromNow(5), certFp8: "12345678", file: "x")
            ], freeSigned: [signedEntry(), signedEntry("appletv/stremio-tvos")], extra: ["futureKey": ["a": 1]])
        let back = try LedgerStore.parse(try LedgerStore.encode(ledger))
        #expect(back == ledger)
        #expect(back.freeSigned.map(\.id) == ["iphone/stremio-ios", "appletv/stremio-tvos"])
        #expect(back.extra["futureKey"] == ["a": 1])
    }

    @Test("a later sign replaces its own key and leaves the others, sorted by id")
    func replaces() async throws {
        try await withTestHome { paths, _ in
            let store = LedgerStore(paths: paths)
            try await store.update { $0.freeSigned = [signedEntry("b/x"), signedEntry("a/y")] }
            try await store.update { ledger in
                ledger.freeSigned.removeAll { $0.id == "a/y" }
                var newer = signedEntry("a/y")
                newer.version = "2.0"
                ledger.freeSigned.append(newer)
                ledger.freeSigned.sort { $0.id < $1.id }
            }
            let ledger = try store.load()
            #expect(ledger.freeSigned.map(\.id) == ["a/y", "b/x"] && ledger.freeSigned.first?.version == "2.0")
            #expect(modeOf(paths.ledger) == 0o600)
        }
    }
}

@Suite("sign: CLI")
struct SignCLITests {
    @Test("sign is dispatched: usage, unknown options, --yes, and no extra positional")
    func dispatch() async throws {
        try await withSignWorld(profile: .noRecord) { w in
            func invoke(_ argv: [String]) async -> Envelope { await run(argv: argv, services: w.services) }
            #expect(await invoke(["sign"]).errors.first?.code == "USAGE")
            #expect(await invoke(["sign", "--bogus"]).errors.first?.code == "USAGE")
            #expect(await invoke(["sign", "--app", "stremio-ios", "--device", "iphone", "--force"]).errors.first?.code == "USAGE")
            #expect(await invoke(["sign", "--app", "stremio-ios", "--device", "iphone", "extra"]).errors.first?.code == "USAGE")
            #expect(await invoke(["sign", "--app", "nope", "--device", "iphone", "--yes"]).errors.first?.code == "USAGE")
            #expect(await invoke(["sign", "--app", "stremio-ios", "--device", "iphone"]).errors.first?.code == "CONFIRM_REQUIRED")
            #expect(w.runner.calls.isEmpty)
            // Both spellings of a value reach the command; this one stops at the missing profile.
            let inline = await invoke(["sign", "--app=stremio-ios", "--device=iphone", "--yes"])
            #expect(inline.command == "sign" && inline.errors.first?.code == "PROFILE_MISSING")
            let spaced = await invoke(["sign", "--app", "stremio-ios", "--device", "iphone", "--yes"])
            #expect(spaced.errors.first?.code == "PROFILE_MISSING")
        }
    }

    @Test("help lists sign as built, with its usage line, and sign --help prints it")
    func help() async throws {
        try await withSignWorld { w in
            for argv in [["help"], ["sign", "--help"], ["sign", "-h"]] {
                let out = await run(argv: argv, services: w.services)
                #expect(out.data["built"]?.array?.contains("sign") == true, "\(argv)")
                let usage = out.data["usage"]?.array?.compactMap(\.string) ?? []
                #expect(usage.contains { $0.hasPrefix("sign --app <apollo|stremio-ios|stremio-tvos> --device <alias>") && $0.hasSuffix("--yes") })
            }
            #expect(w.runner.calls.isEmpty)
        }
    }

    @Test("install is built: it needs its options and no longer answers NOT_IMPLEMENTED")
    func installBuilt() async throws {
        try await withSignWorld { w in
            #expect(await run(argv: ["install"], services: w.services).errors.first?.code == "USAGE")
        }
    }
}
