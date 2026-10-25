#if DEBUG
import Foundation
import Testing

@testable import SideloadCore

// The DEBUG-only `SIDELOAD_TEST_FORCE_SLOT` hook of `slot` (docs/design.md section 18). It is compiled out of release
// builds; `scripts/check.sh` builds the release CLI and proves it. These tests build debug, so they cover what the hook
// answers: the shapes against the real failures, `USAGE` for what it refuses, and, against the built `sideload`, that no
// lock, ledger or device is touched. Nothing here sets an environment variable in this process.

private let lentToLab = LedgerLent(app: "stremio-ios", device: "iphone", to: "lab", since: daysFromNow(-1))

private func keys(_ data: [String: JSONValue]) -> Set<String> { Set(data.keys) }

@Suite("slot: SIDELOAD_TEST_FORCE_SLOT")
struct SlotForceHookTests {
    @Test("unset or empty is no answer; an unknown value is USAGE")
    func modes() throws {
        #expect(try SlotCommand.forcedAnswer(mode: nil, sub: "lend", alias: "iphone", app: "filler") == nil)
        #expect(try SlotCommand.forcedAnswer(mode: "", sub: "return", alias: "iphone", app: "filler") == nil)
        for sub in ["lend", "return"] {
            for mode in ["bogus", "PENDING", "pending ", "return_failed"] {
                do {
                    _ = try SlotCommand.forcedAnswer(mode: mode, sub: sub, alias: "iphone", app: "filler")
                    Issue.record("\(sub) \(mode) must throw")
                } catch let error as SideloadError {
                    #expect(error.code == "USAGE", "\(sub) \(mode)")
                }
            }
        }
    }

    @Test("return-failed on slot lend is USAGE")
    func returnFailedOnLend() throws {
        do {
            _ = try SlotCommand.forcedAnswer(mode: "return-failed", sub: "lend", alias: "iphone", app: "filler")
            Issue.record("return-failed on lend must throw")
        } catch let error as SideloadError {
            #expect(error.code == "USAGE")
        }
    }

    @Test("pending carries the keys of a real SLOT_PENDING")
    func pendingShape() async throws {
        let forced = try #require(try SlotCommand.forcedAnswer(mode: "pending", sub: "lend", alias: "iphone", app: "filler"))
        #expect(forced.code == "SLOT_PENDING")
        #expect(forced.data["retryAfter"] == .number(Double(SlotRule.window(.install))))
        #expect(forced.data["freed"] == 0 && forced.data["uncertain"] == true && forced.data["app"] == "filler")
        #expect(forced.data["state"] == "pending" && forced.data["lent"] == false && forced.data["op"] == "install")
        #expect(try SlotCommand.forcedAnswer(mode: "pending", sub: "return", alias: "iphone", app: "filler")?.code == "SLOT_PENDING")

        // A real one: a timed-out lend leaves an op in flight, and the next command is answered by the gate.
        let script = DeviceScript(initial: [stremioId: true], uninstallLandsAfter: 100, uninstallTimeoutRemoves: false)
        try await withInstallWorld(script: script, lendable: "stremio-ios") { w in
            #expect((await w.slot("lend", device: "iphone", to: "lab")).errorCodes == ["TIMEOUT"])
            let real = await w.slot("lend", device: "iphone", to: "lab")
            #expect(real.errorCodes == ["SLOT_PENDING"])
            #expect(keys(real.data).subtracting(["action", "device"]) == keys(forced.data))
        }
    }

    @Test("return-failed carries the keys and the cause of a real RETURN_FAILED")
    func returnFailedShape() async throws {
        let forced = try #require(
            try SlotCommand.forcedAnswer(mode: "return-failed", sub: "return", alias: "iphone", app: "filler"))
        #expect(forced.code == "RETURN_FAILED")
        #expect(forced.data["cause"] == "DEVICE_LOCKED" && forced.data["state"] == "lent")
        #expect(forced.data["lent"] == true && forced.data["app"] == "filler")
        #expect(forced.fix?.contains("slot return --device iphone") == true)

        let locked = try loadFixtureJSON("install-locked.json")
        try await withInstallWorld(
            script: DeviceScript(install: .fail(json: locked)), lendable: "stremio-ios", ledger: { $0.lent = [lentToLab] }
        ) { w in
            let real = await w.slot("return", device: "iphone")
            #expect(real.errorCodes == ["RETURN_FAILED"])
            #expect(real.data["cause"] == "DEVICE_LOCKED" && real.data["state"] == "lent")
            #expect(keys(real.data).subtracting(["action", "device"]) == keys(forced.data))
        }
    }

    // MARK: the built binary

    private static func binaryURL(file: String = #filePath) -> URL? {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("sideload"))
        }
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/sideload"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `sideload slot ...` with the variable set, a temp home and a 15 s watchdog. Returns the printed JSON.
    private static func run(_ binary: URL, home: String, mode: String?, _ arguments: [String]) throws -> JSONValue {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["slot"] + arguments
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_HOME"] = home
        env["SIDELOAD_TEST_FORCE_SLOT"] = mode
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return try decodeJSON(String(decoding: data, as: UTF8.self))
    }

    @Test("the built sideload answers from the hook with no lock, ledger or device, and refuses what it must")
    func binary() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: carrierPrefix)) { paths, _ in
            let ledgerBytes = Data("{\"version\":1}\n".utf8)
            try ledgerBytes.write(to: URL(fileURLWithPath: paths.ledger))
            let before = listing(paths.home).sorted()

            for sub in [["lend", "--device", "iphone", "--to", "lab"], ["return", "--device", "iphone"]] {
                let out = try Self.run(binary, home: paths.home, mode: "pending", sub)
                #expect(out["ok"] == false && out["errors"]?.array?.first?["code"] == "SLOT_PENDING", "\(sub): \(out)")
                #expect(out["device"] == "iphone" && out["action"] == .string(sub[0]))
                for key in ["retryAfter", "freed", "state", "uncertain", "lent", "app", "op"] {
                    #expect(out[key] != nil, "\(sub[0]) missing \(key)")
                }
            }
            let failed = try Self.run(binary, home: paths.home, mode: "return-failed", ["return", "--device", "iphone"])
            #expect(failed["errors"]?.array?.first?["code"] == "RETURN_FAILED" && failed["cause"] == "DEVICE_LOCKED")
            #expect(failed["state"] == "lent" && failed["lent"] == true)

            let onLend = try Self.run(
                binary, home: paths.home, mode: "return-failed", ["lend", "--device", "iphone", "--to", "lab"])
            #expect(onLend["errors"]?.array?.first?["code"] == "USAGE")
            let unknown = try Self.run(binary, home: paths.home, mode: "bogus", ["return", "--device", "iphone"])
            #expect(unknown["errors"]?.array?.first?["code"] == "USAGE")

            // No lock file, no ledger write, nothing else created: the answers came before any of them.
            #expect(listing(paths.home).sorted() == before)
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths.ledger)) == ledgerBytes)
            #expect(!FileManager.default.fileExists(atPath: paths.opLock))
        }
    }

    @Test("an unsaved device is still DEVICE_NOT_SAVED: the hook answers after the alias is resolved")
    func unsavedDevice() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: carrierPrefix)) { paths, _ in
            let out = try Self.run(binary, home: paths.home, mode: "pending", ["return", "--device", "nope"])
            #expect(out["errors"]?.array?.first?["code"] == "DEVICE_NOT_SAVED")
        }
    }
}

#endif
