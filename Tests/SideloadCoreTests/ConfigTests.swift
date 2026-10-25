import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private func thrownCode(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return errorCode(of: error)
    }
}

@Suite("config")
struct ConfigTests {
    @Test("defaults SIDELOAD_HOME to ~/.sideload and honours the env var")
    func resolveHome() {
        #expect(Paths.resolveHome(environment: [:], homeDirectory: "/home/u").home == "/home/u/.sideload")
        #expect(
            Paths.resolveHome(environment: ["SIDELOAD_HOME": "/somewhere/else"], homeDirectory: "/home/u").home
                == "/somewhere/else")
        #expect(
            Paths.resolveHome(environment: ["SIDELOAD_HOME": ""], homeDirectory: "/home/u").home == "/home/u/.sideload")
        #expect(
            Paths.resolveHome(environment: ["SIDELOAD_HOME": "/a/b/../c/./d/"], homeDirectory: "/h").home == "/a/c/d")
        let p = Paths(home: "/x")
        #expect([p.config, p.configLock, p.opLock, p.tmp] == ["/x/config.json", "/x/.config.lock", "/x/.op.lock", "/x/tmp"])
    }

    @Test("creates the home and subdirectories as 0700")
    func createsHome() async throws {
        try await withTestHome { paths, _ in
            #expect(modeOf(paths.home) == 0o700)
            for d in ["secrets", "downloads", "builds", "logs", "tmp"] { #expect(modeOf(paths.home + "/" + d) == 0o700) }
        }
    }

    @Test("creates a missing home and its missing parents as 0700")
    func createsParents() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root.path + "/a/b/home")
        try paths.ensureHome()
        for dir in [root.path + "/a", root.path + "/a/b", paths.home, paths.tmp] { #expect(modeOf(dir) == 0o700) }
    }

    @Test("repairs loose directory modes and reports them via checkModes")
    func repairsModes() async throws {
        try await withTestHome { paths, _ in
            chmod(paths.secrets, 0o755)
            #expect(paths.checkModes().count == 1)
            try paths.ensureHome()
            #expect(modeOf(paths.secrets) == 0o700)
            #expect(paths.checkModes().isEmpty)
        }
    }

    @Test("writes config.json as 0600 and round-trips it with defaults")
    func roundTrip() async throws {
        try await withTestHome(config: iphoneConfig(bundleIdPrefix: "com.example")) { paths, store in
            #expect(modeOf(paths.config) == 0o600)
            let cfg = try store.load()
            #expect(cfg.bundleIdPrefix == "com.example")
            #expect(cfg.minFreeGB == 2)
            #expect(cfg.teamId == Team.id)
            #expect(cfg.savedDeviceIDs == [savedCoreId("1"), savedUdid("1")])
            let text = try String(contentsOfFile: paths.config, encoding: .utf8)
            #expect(text.hasSuffix("}\n"))
        }
    }

    @Test("a missing config.json loads the defaults")
    func missingConfig() async throws {
        try await withTestHome { _, store in
            let cfg = try store.load()
            #expect(cfg == Config())
            #expect(cfg.teamId == Team.id && cfg.devices.isEmpty && cfg.approvedSources.isEmpty && cfg.lastNotified.isEmpty)
        }
    }

    @Test("fields this version does not model survive a load and update")
    func preservesUnknownFields() async throws {
        try await withTestHome { paths, store in
            let raw = #"""
                {"future": {"a": [1, 2]}, "devices": {"iphone": {"udid": "u1", "novel": true}},
                 "approvedSources": [{"kind": "x"}], "lastNotified": {"cert": 14}, "apps": {"feather": {"v": "1"}}}
                """#
            try Data(raw.utf8).write(to: URL(fileURLWithPath: paths.config))
            try await store.update { $0.minFreeGB = 3 }
            let cfg = try store.load()
            #expect(cfg.minFreeGB == 3)
            #expect(cfg.extra["future"] == ["a": [1, 2]])
            #expect(cfg.devices["iphone"]?.extra["novel"] == true)
            #expect(cfg.approvedSources == [["kind": "x"]])
            #expect(cfg.lastNotified == ["cert": 14])
            #expect(cfg.apps["feather"] == ["v": "1"])
        }
    }

    @Test("writes atomically: no temp files left behind, old content survives a failed write")
    func atomicWrite() async throws {
        try await withTestHome { paths, _ in
            let file = paths.home + "/f.txt"
            try AtomicFile.write(Data("one".utf8), to: file)
            try AtomicFile.write(Data("two".utf8), to: file)
            #expect(try String(contentsOfFile: file, encoding: .utf8) == "two")
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
            #expect(modeOf(file) == 0o600)

            #expect(throws: SideloadError.self) {
                try AtomicFile.write(Data("three".utf8), to: file, rename: { _, _ in
                    errno = EIO
                    return -1
                })
            }
            #expect(try String(contentsOfFile: file, encoding: .utf8) == "two")
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test("the temp file is named <file>.<pid>.<rand>.tmp and is 0600 while it exists")
    func tempName() async throws {
        try await withTestHome { paths, _ in
            let file = paths.home + "/g.txt"
            let seen = Mutex<(name: String, mode: Int)?>(nil)
            try AtomicFile.write(Data("x".utf8), to: file, rename: { from, to in
                seen.withLock { $0 = (String(from.dropFirst(paths.home.count + 1)), modeOf(from)) }
                return Darwin.rename(from, to)
            })
            let s = try #require(seen.withLock { $0 })
            #expect(s.mode == 0o600)
            #expect(s.name.hasPrefix("g.txt.\(getpid())."))
            #expect(s.name.hasSuffix(".tmp"))
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test("rejects a home inside a git work tree (including a not-yet-created subdir)")
    func rejectsGitWorkTree() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(atPath: repo.path + "/.git", withIntermediateDirectories: false)
        for home in [repo.path + "/home", repo.path + "/a/b/c"] {
            #expect(throws: SideloadError.self) { try Paths(home: home).ensureHome() }
            do {
                try Paths(home: home).ensureHome()
            } catch {
                #expect(errorCode(of: error) == "HOME_IN_GIT_WORKTREE")
            }
        }
        // A worktree-style `.git` file counts too.
        let wt = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: wt) }
        try Data("gitdir: /elsewhere".utf8).write(to: wt.appendingPathComponent(".git"))
        do {
            try Paths(home: wt.path + "/home").ensureHome()
            Issue.record("expected HOME_IN_GIT_WORKTREE")
        } catch {
            #expect(errorCode(of: error) == "HOME_IN_GIT_WORKTREE")
        }
        #expect(!listing(repo.path).contains("home"))
        #expect(!listing(repo.path).contains("a"))
        #expect(!listing(wt.path).contains("home"))
    }

    @Test("a home outside any git work tree is accepted")
    func acceptsPlainHome() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Paths(home: root.path + "/home").findGitWorkTree() == nil)
    }

    @Test("rejects the free team in config and invalid JSON without echoing it")
    func rejectsBadConfig() async throws {
        try await withTestHome { paths, store in
            let url = URL(fileURLWithPath: paths.config)
            try Data(#"{"teamId": "6ZU5Z6ZKK7"}"#.utf8).write(to: url)
            #expect(await thrownCode { _ = try store.load() } == "FREE_TEAM_SELECTED")

            try Data(#"{"secret": nope"#.utf8).write(to: url)
            do {
                _ = try store.load()
                Issue.record("expected CONFIG_INVALID")
            } catch let e as SideloadError {
                #expect(e.code == "CONFIG_INVALID")
                #expect(!e.message.contains("secret") && !(e.fix ?? "").contains("secret"))
            }

            for bad in [
                #"[1]"#, #"5"#, #"{"teamId": "OTHER12345"}"#, #"{"teamId": null}"#, #"{"devices": []}"#,
                #"{"devices": null}"#, #"{"devices": {"x": 5}}"#, #"{"minFreeGB": "secret-text"}"#,
            ] {
                try Data(bad.utf8).write(to: url)
                do {
                    _ = try store.load()
                    Issue.record("expected CONFIG_INVALID for \(bad)")
                } catch let e as SideloadError {
                    #expect(e.code == "CONFIG_INVALID")
                    #expect(!e.message.contains("secret"))
                }
            }
        }
    }

    @Test("wrong-typed fields are CONFIG_INVALID naming the key path, never the value")
    func namesTheKey() async throws {
        try await withTestHome { paths, store in
            let url = URL(fileURLWithPath: paths.config)
            let cases: [(String, String)] = [
                (#"{"minFreeGB": "hush-3"}"#, "minFreeGB"),
                (#"{"devices": {"iphone": "hush-3"}}"#, "devices.iphone"),
                (#"{"devices": {"iphone": {"hostnames": [1]}}}"#, "devices.iphone.hostnames[0]"),
                (#"{"lastNotified": {"cert": "hush-3"}}"#, "lastNotified.cert"),
            ]
            for (raw, key) in cases {
                try Data(raw.utf8).write(to: url)
                do {
                    _ = try store.load()
                    Issue.record("expected CONFIG_INVALID for \(key)")
                } catch let e as SideloadError {
                    #expect(e.code == "CONFIG_INVALID")
                    #expect((e.fix ?? "").contains("`\(key)`"))
                    #expect(!e.message.contains("hush") && !(e.fix ?? "").contains("hush"))
                }
            }
        }
    }

    @Test("null-valued unknown keys survive a rewrite")
    func preservesNullUnknown() async throws {
        try await withTestHome { paths, store in
            try Data(#"{"future": null, "devices": {"d": {"udid": "u", "novel": null}}}"#.utf8)
                .write(to: URL(fileURLWithPath: paths.config))
            try await store.update { $0.minFreeGB = 3 }
            let cfg = try store.load()
            #expect(cfg.extra["future"] == JSONValue.null)
            #expect(cfg.devices["d"]?.extra["novel"] == JSONValue.null)
        }
    }

    @Test("appleSupportCase round-trips as a string, as an integer, and absent; an unknown sibling survives")
    func appleSupportCaseRoundTrip() async throws {
        func roundTrip(_ raw: String) async throws -> (Config, String) {
            try await withTestHome { paths, store in
                try Data(raw.utf8).write(to: URL(fileURLWithPath: paths.config))
                try await store.update { $0.minFreeGB = 3 }
                return (try store.load(), try String(contentsOfFile: paths.config, encoding: .utf8))
            }
        }
        let (asString, stringFile) = try await roundTrip(#"{"appleSupportCase": "555000111222", "future": true}"#)
        #expect(asString.appleSupportCase == "555000111222" && asString.extra["future"] == true)
        #expect(stringFile.contains(#""appleSupportCase" : "555000111222""#))

        let (asNumber, numberFile) = try await roundTrip(#"{"appleSupportCase": 555000111222, "future": true}"#)
        #expect(asNumber.appleSupportCase == "555000111222" && asNumber.extra["future"] == true)
        #expect(numberFile.contains(#""appleSupportCase" : 555000111222"#))
        #expect(!numberFile.contains(#""555000111222""#))

        let (absent, absentFile) = try await roundTrip(#"{"future": true}"#)
        #expect(absent.appleSupportCase == nil && absent.extra["future"] == true)
        #expect(!absentFile.contains("appleSupportCase"))

        let (null, nullFile) = try await roundTrip(#"{"appleSupportCase": null}"#)
        #expect(null.appleSupportCase == nil && !nullFile.contains("appleSupportCase"))
    }

    @Test("an appleSupportCase that is neither a string nor an integer is CONFIG_INVALID naming the key")
    func appleSupportCaseWrongType() async throws {
        try await withTestHome { paths, store in
            try Data(#"{"appleSupportCase": ["hush"]}"#.utf8).write(to: URL(fileURLWithPath: paths.config))
            let code = await thrownCode { _ = try store.load() }
            #expect(code == "CONFIG_INVALID")
        }
    }

    @Test("refuses to save a config for another team")
    func saveRejectsTeam() async throws {
        try await withTestHome { _, store in
            var cfg = Config()
            cfg.teamId = "6ZU5Z6ZKK7"
            #expect(await thrownCode { try await store.update { $0 = cfg } } == "FREE_TEAM_SELECTED")
            cfg.teamId = "SOMETHING1"
            #expect(await thrownCode { try await store.update { $0 = cfg } } == "CONFIG_INVALID")
        }
    }

    @Test("requireDevice prefers the CoreDevice UUID and errors on unknown aliases")
    func requireDevice() throws {
        let cfg = iphoneConfig()
        #expect(try cfg.requireDevice("iphone").deviceId == savedCoreId("1"))
        do {
            _ = try cfg.requireDevice("nope")
            Issue.record("expected DEVICE_NOT_SAVED")
        } catch {
            #expect(errorCode(of: error) == "DEVICE_NOT_SAVED")
        }
        let udidOnly = Config(devices: ["phone": SavedDevice(udid: savedUdid("2"), platform: "ios")])
        #expect(try udidOnly.requireDevice("phone").deviceId == savedUdid("2"))
        #expect(try udidOnly.requireDevice("phone").udid == savedUdid("2"))
        let empty = Config(devices: ["x": SavedDevice(platform: "ios")])
        do {
            _ = try empty.requireDevice("x")
            Issue.record("expected CONFIG_INVALID")
        } catch {
            #expect(errorCode(of: error) == "CONFIG_INVALID")
        }
        #expect(cfg.isSavedDeviceID(savedUdid("1")) && cfg.isSavedDeviceID(savedCoreId("1")))
        #expect(!cfg.isSavedDeviceID("iphone") && !cfg.isSavedDeviceID(savedUdid("9")) && !cfg.isSavedDeviceID(""))
        #expect(try cfg.savedDevices(platform: "tvos").isEmpty)
        #expect(try cfg.savedDevices(platform: "ios").map(\.alias) == ["iphone"])
    }
}

@Suite("config locks")
struct ConfigLockTests {
    @Test("concurrent updates from separate stores lose no writes")
    func concurrentUpdates() async throws {
        try await withTestHome { paths, _ in
            let n = 24
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<n {
                    group.addTask {
                        let store = ConfigStore(paths: paths, lockTimeout: .seconds(20))
                        try await store.update { cfg in
                            cfg.devices["d\(i)"] = SavedDevice(udid: savedUdid("\(i)"), platform: "ios")
                            cfg.lastNotified["n", default: 0] += 1
                        }
                    }
                }
                try await group.waitForAll()
            }
            let cfg = try ConfigStore(paths: paths).load()
            #expect(cfg.devices.count == n)
            #expect(cfg.lastNotified["n"] == n)
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test("update returns the body's value, and nothing is written when the body throws")
    func updateSemantics() async throws {
        try await withTestHome(config: iphoneConfig()) { paths, store in
            let count = try await store.update { $0.devices.count }
            #expect(count == 1)
            struct Boom: Error {}
            do {
                try await store.update { cfg in
                    cfg.devices.removeAll()
                    throw Boom()
                }
                Issue.record("expected the body's error")
            } catch is Boom {}
            #expect(try store.load().devices.count == 1)
            // The lock was released: another update goes through at once.
            try await store.update { $0.minFreeGB = 9 }
            #expect(try store.load().minFreeGB == 9)
            #expect(!listing(paths.home).contains { $0.hasSuffix(".tmp") })
        }
    }

    @Test("BUSY after the bounded wait while the config lock is held")
    func busy() async throws {
        try await withTestHome { paths, _ in
            let held = try #require(try FileLock.tryAcquire(path: paths.configLock))
            let store = ConfigStore(paths: paths, lockTimeout: .milliseconds(200), retryInterval: .milliseconds(10))
            let start = ContinuousClock.now
            let code = await thrownCode { try await store.update { $0.minFreeGB = 7 } }
            let elapsed = ContinuousClock.now - start
            #expect(code == "BUSY")
            // Lower bound only: the wait lasts at least the configured bound. No upper bound, which load can break.
            #expect(elapsed >= .milliseconds(200))
            #expect(try store.load().minFreeGB == 2)

            held.release()
            try await store.update { $0.minFreeGB = 7 }
            #expect(try store.load().minFreeGB == 7)
        }
    }

    @Test("a waiting update proceeds once the holder releases within the timeout")
    func waitsForRelease() async throws {
        try await withTestHome { paths, _ in
            let held = try #require(try FileLock.tryAcquire(path: paths.configLock))
            let store = ConfigStore(paths: paths, lockTimeout: .seconds(10), retryInterval: .milliseconds(10))
            async let done: Void = store.update { $0.minFreeGB = 5 }
            try await Task.sleep(for: .milliseconds(100))
            held.release()
            try await done
            #expect(try store.load().minFreeGB == 5)
        }
    }

    @Test("the operation lock admits one holder: OPERATION_IN_PROGRESS for the second")
    func operationLock() async throws {
        try await withTestHome { paths, _ in
            let first = try OperationLock.acquire(paths: paths)
            #expect(await thrownCode { _ = try OperationLock.acquire(paths: paths) } == "OPERATION_IN_PROGRESS")
            first.release()
            first.release()  // idempotent
            let second = try OperationLock.acquire(paths: paths)
            #expect(await thrownCode { _ = try OperationLock.acquire(paths: paths) } == "OPERATION_IN_PROGRESS")
            second.release()
        }
    }

    @Test("the operation lock is released on deinit")
    func operationLockDeinit() async throws {
        try await withTestHome { paths, _ in
            do { _ = try OperationLock.acquire(paths: paths) }
            let again = try OperationLock.acquire(paths: paths)
            again.release()
        }
    }

    @Test("the operation lock and the config lock are independent")
    func locksIndependent() async throws {
        try await withTestHome { paths, store in
            let op = try OperationLock.acquire(paths: paths)
            try await store.update { $0.minFreeGB = 4 }
            op.release()
        }
    }

    @Test("an existing lock file with a loose mode is tightened to 0600")
    func existingLockMode() async throws {
        try await withTestHome { paths, store in
            for file in [paths.opLock, paths.configLock] {
                #expect(FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o644]))
                chmod(file, 0o644)
            }
            let op = try OperationLock.acquire(paths: paths)
            try await store.update { _ in }
            #expect(modeOf(paths.opLock) == 0o600)
            #expect(modeOf(paths.configLock) == 0o600)
            op.release()
        }
    }

    @Test("cancelling a task that waits for the config lock throws CANCELLED, not CancellationError")
    func cancelledWhileWaiting() async throws {
        try await withTestHome { paths, _ in
            let held = try #require(try FileLock.tryAcquire(path: paths.configLock))
            let store = ConfigStore(paths: paths, lockTimeout: .seconds(30), retryInterval: .milliseconds(10))
            let task = Task { () -> String? in
                await thrownCode { try await store.update { $0.minFreeGB = 8 } }
            }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            #expect(await task.value == "CANCELLED")
            held.release()
            #expect(try store.load().minFreeGB == 2)
        }
    }

    @Test("lock files are 0600")
    func lockModes() async throws {
        try await withTestHome { paths, store in
            let op = try OperationLock.acquire(paths: paths)
            try await store.update { _ in }
            #expect(modeOf(paths.opLock) == 0o600)
            #expect(modeOf(paths.configLock) == 0o600)
            #expect(modeOf(paths.config) == 0o600)
            op.release()
        }
    }

    @Test(
        "the kernel releases the operation lock when its holder dies",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func releasedOnProcessDeath() async throws {
        try await withTestHome { paths, _ in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = [
                "-e",
                #"use Fcntl qw(:flock); $|=1; open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; print "locked\n"; sleep 60;"#,
                paths.opLock,
            ]
            let out = Pipe()
            child.standardOutput = out
            try child.run()
            defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
            let line = out.fileHandleForReading.availableData
            try #require(String(decoding: line, as: UTF8.self).hasPrefix("locked"))

            #expect(await thrownCode { _ = try OperationLock.acquire(paths: paths) } == "OPERATION_IN_PROGRESS")
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            let lock = try OperationLock.acquire(paths: paths)
            lock.release()
        }
    }
}
