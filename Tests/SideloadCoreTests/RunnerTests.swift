import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private func spec(
    _ script: String, _ args: [String] = [], timeout: Duration = .seconds(30), stdin: Data? = nil,
    cwd: String? = nil, max: Int = CommandSpec.defaultMaxOutputBytes
) -> CommandSpec {
    CommandSpec(
        executable: fixture(script), args: args, timeout: timeout, stdin: stdin, cwd: cwd, maxOutputBytes: max)
}

@Suite("process runner")
struct RunnerTests {
    // MARK: CommandSpec

    @Test("CommandSpec traps on an empty executable")
    func emptyExecutableTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = CommandSpec(executable: "", timeout: .seconds(1))
        }
    }

    @Test("CommandSpec traps on a zero or negative timeout")
    func badTimeoutTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = CommandSpec(executable: "/usr/bin/true", timeout: .zero)
        }
        await #expect(processExitsWith: .failure) {
            _ = CommandSpec(executable: "/usr/bin/true", timeout: .seconds(-1))
        }
    }

    @Test("CommandSpec traps on a non-positive output cap")
    func badOutputCapTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = CommandSpec(executable: "/usr/bin/true", timeout: .seconds(1), maxOutputBytes: 0)
        }
        await #expect(processExitsWith: .failure) {
            _ = CommandSpec(executable: "/usr/bin/true", timeout: .seconds(1), maxOutputBytes: -5)
        }
    }

    @Test("CommandSpec carries timeout, stdin and defaults through to the runner")
    func specPassesThrough() async {
        let fake = FakeRunner(results: [RunResult(code: 0, stdout: "ok")])
        let s = CommandSpec(executable: "/usr/bin/openssl", args: ["x509"], timeout: .milliseconds(99), stdin: Data("PEM".utf8))
        let r = await fake.run(s)
        #expect(r.stdout == "ok")
        #expect(fake.calls == [s])
        #expect(fake.calls[0].timeout == .milliseconds(99))
        #expect(fake.calls[0].stdin == Data("PEM".utf8))
        #expect(fake.calls[0].maxOutputBytes == 32 * 1024 * 1024)
    }

    // MARK: Spawning, arguments, process group

    @Test("passes args verbatim: no shell, no expansion")
    func argsVerbatim() async {
        let args = ["a b", "$HOME", "; echo hi", "*", "`id`", ""]
        let r = await Harness().run(spec("args.sh", args))
        #expect(r.code == 0)
        #expect(r.stdout == args.joined(separator: "\n") + "\n")
    }

    @Test("the child runs in its own process group")
    func ownProcessGroup() async throws {
        let r = await Harness().run(spec("pgid.sh"))
        let lines = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.count == 2)
        let pid = try #require(Int32(lines[0]))
        let pgid = try #require(Int32(lines[1]))
        #expect(pgid == pid)
        #expect(pgid != getpgrp())
    }

    @Test("reports non-zero exits with stdout and stderr, without throwing")
    func nonZeroExit() async {
        let r = await Harness().run(spec("exit3.sh"))
        #expect(r.code == 3)
        #expect(r.signal == nil)
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "bad\n")
        #expect(r.spawnError == nil && !r.timedOut && !r.overflow)
    }

    @Test("spawn failures are results: ENOENT for a missing path or PATH name, EACCES for a non-executable file")
    func spawnErrors() async throws {
        let h = Harness()
        let missing = await h.run(CommandSpec(executable: "/nonexistent/sideload-tool", timeout: .seconds(5)))
        #expect(missing.spawnError == "ENOENT")
        #expect(missing.code == nil)
        let notOnPath = await h.run(CommandSpec(executable: "sideload-no-such-tool-xyz", timeout: .seconds(5)))
        #expect(notOnPath.spawnError == "ENOENT")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.sh")
        try "#!/bin/sh\nexit 0\n".write(to: plain, atomically: true, encoding: .utf8)
        let denied = await h.run(CommandSpec(executable: plain.path, timeout: .seconds(5)))
        #expect(denied.spawnError == "EACCES")
        #expect(h.log.signals.isEmpty)
    }

    @Test("a bare executable name is resolved through PATH")
    func pathResolution() async {
        let r = await Harness().run(CommandSpec(executable: "true", timeout: .seconds(5)))
        #expect(r.code == 0)
        #expect(r.spawnError == nil)
    }

    @Test("the working directory is applied; a bad one is a spawn error")
    func workingDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = Harness()
        let ok = await h.run(spec("pwd.sh", cwd: dir.path))
        #expect(ok.stdout.trimmingCharacters(in: .newlines) == realPath(dir.path))
        let bad = await h.run(spec("pwd.sh", cwd: dir.appendingPathComponent("missing").path))
        #expect(bad.spawnError != nil)
    }

    @Test("the environment is inherited unchanged")
    func environment() async {
        let r = await Harness().run(spec("home.sh"))
        #expect(r.stdout == ProcessInfo.processInfo.environment["HOME"])
    }

    // MARK: stdin

    @Test("stdin round trip")
    func stdinRoundTrip() async {
        let r = await Harness().run(spec("cat.sh", stdin: Data("PEM data".utf8)))
        #expect(r.stdout == "PEM data")
        #expect(r.code == 0)
    }

    @Test("stdin is closed when there is no input, so the tool sees EOF")
    func stdinClosedWhenEmpty() async {
        let r = await Harness().run(spec("cat.sh", timeout: .seconds(10)))
        #expect(r.stdout.isEmpty)
        #expect(r.code == 0)
        #expect(!r.timedOut)
    }

    @Test("a large stdin that is echoed back does not deadlock")
    func largeStdin() async {
        let text = String(repeating: "x", count: 4 * 1024 * 1024)
        let r = await Harness().run(spec("cat.sh", stdin: Data(text.utf8)))
        #expect(r.stdout.utf8.count == text.utf8.count)
        #expect(r.code == 0)
    }

    @Test("a child that never reads stdin does not crash the host with SIGPIPE")
    func childIgnoresStdin() async {
        let r = await Harness().run(spec("noread.sh", stdin: Data(count: 4 * 1024 * 1024)))
        #expect(r.code == 0)
    }

    // MARK: Timeout and group kill

    @Test("timeout: SIGTERM to the group, then a final group SIGKILL after reaping, once each")
    func timeoutSignals() async throws {
        let h = Harness()
        let timeout: Duration = .milliseconds(150)
        let r = await h.run(spec("sleep.sh", timeout: timeout))
        #expect(r.timedOut)
        #expect(!r.overflow)
        #expect(r.signal == SIGTERM)
        #expect(h.log.signals == [SIGTERM, SIGKILL])
        #expect(h.log.groups.count == 1)
        let toTerm = try #require(h.log.sent(SIGTERM)) - (try #require(h.spawned.at))
        #expect(toTerm >= timeout && toTerm < timeout + runnerSlack, "SIGTERM at the timeout, took \(toTerm)")
    }

    @Test("sends no signals when the child finishes in time")
    func noSignalsWhenInTime() async {
        let h = Harness()
        let r = await h.run(spec("quick.sh", timeout: .seconds(20)))
        #expect(r.code == 0)
        #expect(r.stdout == "done\n")
        #expect(!r.timedOut)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.log.signals.isEmpty)
    }

    @Test("a timed-out child tree leaves no orphaned grandchildren")
    func timeoutKillsGrandchild() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path
        let r = await Harness().run(spec("grandchild.sh", [pidFile], timeout: .seconds(1)))
        #expect(r.timedOut)
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        #expect(pid > 1)
        #expect(await eventually(timeout: .seconds(5)) { !isAlive(pid) }, "grandchild \(pid) survived")
    }

    @Test("timeout: a child that ignores SIGTERM is SIGKILLed after the grace period")
    func timeoutIgnoringTerm() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready").path
        let grace: Duration = .milliseconds(300)
        let h = Harness(grace: grace)
        // Generous timeout: the fixture must have installed its trap before SIGTERM arrives.
        let timeout: Duration = .seconds(2)
        let r = await h.run(spec("ignore-term.sh", [ready], timeout: timeout))
        #expect(FileManager.default.fileExists(atPath: ready), "fixture never started")
        #expect(r.timedOut)
        #expect(r.signal == SIGKILL)
        #expect(h.log.signals == [SIGTERM, SIGKILL])
        let term = try #require(h.log.sent(SIGTERM))
        let toTerm = term - (try #require(h.spawned.at))
        let toKill = try #require(h.log.sent(SIGKILL)) - term
        #expect(toTerm >= timeout && toTerm < timeout + runnerSlack, "SIGTERM at the timeout, took \(toTerm)")
        #expect(toKill >= grace, "SIGKILL must wait for the grace period")
        #expect(toKill < grace + runnerSlack, "SIGKILL right after the grace period, took \(toKill)")
    }

    @Test("a child that cannot be reaped after SIGKILL: the run still returns, status unknown, registry clean")
    func unreapableChildDoesNotHangTheRun() async throws {
        let seen = Mutex<(pid: pid_t, at: ContinuousClock.Instant?)>((0, nil))
        let children = LiveChildren()
        let log = SignalLog()
        let reapTimeout: Duration = .milliseconds(200)
        // The seam never reports the child as reaped, like a child stuck in an uninterruptible state.
        let runner = PosixSpawnRunner(
            children: children, grace: .milliseconds(100), signalGroup: log.send,
            reap: { pid, _ in
                seen.withLock { $0 = (pid, .now) }
                return 0
            },
            reapTimeout: reapTimeout)
        let r = await runner.run(spec("sleep.sh", timeout: .milliseconds(200)))
        // After the SIGKILL the runner drains the pipes, then stops trying to reap once its reap timeout passes.
        let lastReap = try #require(seen.withLock { $0.at })
        let afterKill = lastReap - (try #require(log.sent(SIGKILL)))
        #expect(
            afterKill < PosixSpawnRunner.drainAfterKill + reapTimeout + runnerSlack,
            "gave up reaping \(afterKill) after the SIGKILL")
        #expect(r.timedOut)
        #expect(r.code == nil && r.signal == nil)
        #expect(children.isEmpty)
        // The real child was killed; reap it so the test leaves no zombie.
        var status: Int32 = 0
        let pid = seen.withLock { $0.pid }
        #expect(pid > 0)
        #expect(waitpid(pid, &status, 0) == pid)
    }

    // MARK: Overflow

    @Test("overflow: output is capped at the byte limit, flagged, and the group is killed")
    func overflowCaps() async {
        let h = Harness()
        let r = await h.run(spec("flood.sh", max: 10))
        #expect(r.overflow)
        #expect(!r.timedOut)
        #expect(r.stdout == "y\ny\ny\ny\ny\n")
        #expect(h.log.signals == [SIGTERM, SIGKILL])
    }

    @Test("overflow cap is shared across stdout and stderr")
    func overflowCombined() async {
        let r = await Harness().run(spec("both.sh", max: 10))
        #expect(r.overflow)
        #expect(r.stdout.utf8.count + r.stderr.utf8.count == 10)
    }

    @Test("output exactly at the limit is not an overflow")
    func exactlyAtLimit() async {
        let r = await Harness().run(spec("both.sh", max: 14))
        #expect(!r.overflow)
        #expect(r.stdout == "aaaaaaaa")
        #expect(r.stderr == "bbbbbb")
    }

    @Test("overflow: a real child that ignores SIGTERM is capped and killed promptly")
    func overflowIgnoringTerm() async throws {
        let grace: Duration = .milliseconds(300)
        let h = Harness(grace: grace)
        let r = await h.run(spec("flood-ignore-term.sh", timeout: .seconds(20), max: 100_000))
        #expect(r.overflow)
        // timedOut is set only when the deadline passes before any escalation, so this is the cap, not the timeout.
        #expect(!r.timedOut, "stopped by the cap, not by the 20 s timeout")
        #expect(r.stdout.utf8.count + r.stderr.utf8.count <= 100_000)
        // The fixture outlives SIGTERM and its closed pipes, so only the runner's SIGKILL ends it.
        #expect(r.signal == SIGKILL)
        #expect(h.log.signals == [SIGTERM, SIGKILL])
        let term = try #require(h.log.sent(SIGTERM))
        let toTerm = term - (try #require(h.spawned.at))
        let toKill = try #require(h.log.sent(SIGKILL)) - term
        #expect(toTerm < runnerSlack, "the cap hit soon after the spawn, long before the timeout; took \(toTerm)")
        #expect(toKill >= grace, "SIGKILL must wait for the grace period")
        #expect(toKill < grace + runnerSlack, "SIGKILL right after the grace period, took \(toKill)")
    }

    // MARK: Cancellation

    @Test("cancellation escalates immediately: SIGTERM now, final group SIGKILL, long before the timeout")
    func cancellation() async throws {
        let h = Harness()
        let task = Task { await h.runner.run(spec("sleep.sh", timeout: .seconds(60))) }
        #expect(await eventually { h.children.count == 1 }, "child never registered")
        let cancelled = ContinuousClock.now
        task.cancel()
        let r = await task.value
        let toTerm = try #require(h.log.sent(SIGTERM)) - cancelled
        #expect(toTerm < runnerSlack, "SIGTERM on cancel, long before the 60 s timeout; took \(toTerm)")
        #expect(r.signal == SIGTERM)
        #expect(!r.timedOut && !r.overflow)
        #expect(h.log.signals == [SIGTERM, SIGKILL])
        #expect(h.children.isEmpty)
    }

    @Test("cancellation: a child that ignores SIGTERM is SIGKILLed after the grace period")
    func cancellationIgnoringTerm() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready").path
        let grace: Duration = .milliseconds(300)
        let h = Harness(grace: grace)
        let task = Task { await h.runner.run(spec("ignore-term.sh", [ready], timeout: .seconds(60))) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready) }, "fixture never started")
        let cancelled = ContinuousClock.now
        task.cancel()
        let r = await task.value
        #expect(r.signal == SIGKILL)
        #expect(h.log.signals == [SIGTERM, SIGKILL])
        let term = try #require(h.log.sent(SIGTERM))
        let toTerm = term - cancelled
        let toKill = try #require(h.log.sent(SIGKILL)) - term
        #expect(toTerm < runnerSlack, "SIGTERM on cancel, long before the 60 s timeout; took \(toTerm)")
        #expect(toKill >= grace, "SIGKILL must wait for the grace period")
        #expect(toKill < grace + runnerSlack, "SIGKILL right after the grace period, took \(toKill)")
        #expect(h.children.isEmpty)
    }

    @Test("a task cancelled before the run starts still ends promptly")
    func cancelledBeforeStart() async {
        let h = Harness()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await h.runner.run(spec("sleep.sh", timeout: .seconds(60)))
        }
        let r = await task.value
        #expect(r.signal != nil)
        #expect(h.children.isEmpty)
    }

    // MARK: Failure paths (run in a child process so fd counts and signal state are isolated)

    @Test("a pipe() failure part-way closes the pipes already made and reports EMFILE")
    func pipeFailureLeaksNothing() async {
        await #expect(processExitsWith: .success) {
            func openFds() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
            func runner(failingAt index: Int) -> PosixSpawnRunner {
                let calls = Mutex(0)
                return PosixSpawnRunner(
                    children: LiveChildren(), grace: .milliseconds(100), signalGroup: { killpg($0, $1) },
                    pipeFactory: {
                        let n = calls.withLock { c in
                            defer { c += 1 }
                            return c
                        }
                        return n == index ? nil : makePipe()
                    })
            }
            let quick = CommandSpec(executable: fixture("quick.sh"), timeout: .seconds(10))
            let warm = await runner(failingAt: -1).run(quick)  // also proves a normal run leaks nothing
            #expect(warm.code == 0)
            let before = openFds()
            for index in 0..<4 {
                let r = await runner(failingAt: index).run(quick)
                #expect(r.spawnError == "EMFILE")
                #expect(r.code == nil)
            }
            #expect(openFds() == before, "pipe fds leaked")
            #expect((await runner(failingAt: -1).run(quick)).code == 0)
            #expect(openFds() == before, "a successful run leaked fds")
        }
    }

    @Test("an unreapable child (SIGCHLD ignored by the host) reports neither success nor a signal")
    func echildIsNotSuccess() async {
        await #expect(processExitsWith: .success) {
            signal(SIGCHLD, SIG_IGN)  // children are auto-reaped, so waitpid fails with ECHILD
            let r = await PosixSpawnRunner(children: LiveChildren()).run(
                CommandSpec(executable: fixture("quick.sh"), timeout: .seconds(10)))
            #expect(r.code == nil)
            #expect(r.signal == nil)
            #expect(r.spawnError == nil)
            #expect(r.stdout == "done\n")
        }
    }

    // MARK: LiveChildren

    @Test("after an interrupt closed the registry, nothing is spawned")
    func closedRegistryRefusesSpawns() async {
        let h = Harness()
        h.children.killAll(SIGKILL, closing: true)
        let r = await h.run(spec("sleep.sh", timeout: .seconds(60)))
        #expect(r.spawnError == "INTERRUPTED")
        #expect(r.code == nil && r.signal == nil)
        #expect(h.log.signals.isEmpty)
    }

    @Test("an interrupt waits for a spawn that is in flight, and that child is killed, not orphaned")
    func interruptWaitsForInFlightSpawn() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let h = Harness(afterSpawn: {
            entered.signal()
            release.wait()
        })
        let task = Task { await h.runner.run(spec("sleep.sh", timeout: .seconds(60))) }
        #expect(await eventually { entered.wait(timeout: .now()) == .success }, "spawn never reached the hook")

        let returned = Mutex(false)
        let children = h.children
        Thread {
            children.killAll(SIGKILL, closing: true, spawnWait: .seconds(10))
            returned.withLock { $0 = true }
        }.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!returned.withLock { $0 }, "killAll returned while a spawn was in flight")

        release.signal()
        let r = await task.value
        #expect(r.signal == SIGKILL)
        #expect(await eventually { returned.withLock { $0 } })
        #expect(h.children.isEmpty)
    }

    @Test("the wait for in-flight spawns is bounded")
    func inFlightWaitIsBounded() {
        let children = LiveChildren()
        #expect(children.beginSpawn())
        let clock = ContinuousClock()
        let start = clock.now
        children.killAll(SIGKILL, closing: true, spawnWait: .milliseconds(100))
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(90) && elapsed < .seconds(30))
        #expect(!children.beginSpawn())
        children.endSpawn(pgid: nil)
    }

    @Test("pipes never land on fds 0-2 when the host closed them")
    func closedStdinOfHost() async {
        await #expect(processExitsWith: .success) {
            close(0)
            let r = await PosixSpawnRunner(children: LiveChildren()).run(
                CommandSpec(executable: fixture("cat.sh"), timeout: .seconds(10), stdin: Data("hello".utf8)))
            #expect(r.code == 0)
            #expect(r.stdout == "hello")
        }
    }

    @Test("LiveChildren tracks a running child and is empty afterwards")
    func liveChildren() async {
        let h = Harness()
        let task = Task { await h.runner.run(spec("sleep.sh", timeout: .seconds(60))) }
        #expect(await eventually { h.children.count == 1 })
        h.children.killAll(SIGKILL)
        let r = await task.value
        #expect(r.signal == SIGKILL)
        #expect(h.children.isEmpty)
    }

    @Test("many concurrent runs do not interfere")
    func concurrentRuns() async {
        let h = Harness()
        let results = await withTaskGroup(of: String.self) { group in
            for i in 0..<12 {
                group.addTask { await h.runner.run(spec("args.sh", ["run-\(i)"])).stdout }
            }
            return await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(results == Set((0..<12).map { "run-\($0)\n" }))
        #expect(h.children.isEmpty)
    }
}
