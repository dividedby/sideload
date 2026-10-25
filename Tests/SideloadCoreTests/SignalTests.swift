import Darwin
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private final class Capture: Sendable {
    private let storage = Mutex<[String]>([])
    var writes: [String] { storage.withLock { $0 } }
    var writer: Emitter.Writer { { [self] text in storage.withLock { $0.append(text) } } }
}

private func decode(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func errorCode(_ value: JSONValue) -> String? {
    guard case .object(let o) = value, case .array(let errors)? = o["errors"],
        case .object(let first)? = errors.first, case .string(let code)? = first["code"]
    else { return nil }
    return code
}

private let signalCases: [(Int32, Int32)] = [(SIGINT, 130), (SIGTERM, 143), (SIGHUP, 129)]

/// A writer for the gate tests. Records every call; `gate` makes selected calls block until released.
private final class GatedWriter: Sendable {
    private let storage = Mutex<[String]>([])
    private let gate: @Sendable (String) -> Bool
    /// Signalled each time a gated call is entered.
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(gate: @escaping @Sendable (String) -> Bool = { _ in false }) { self.gate = gate }

    var writes: [String] { storage.withLock { $0 } }

    var writer: Emitter.Writer {
        { [self] text in
            storage.withLock { $0.append(text) }
            if gate(text) {
                entered.signal()
                // Bounded so a bug fails the test instead of hanging it.
                _ = release.wait(timeout: .now() + 20)
            }
        }
    }
}

private let isInterruptedObject: @Sendable (String) -> Bool = { $0.contains("INTERRUPTED") }
private let isAnyObject: @Sendable (String) -> Bool = { _ in true }

/// Runs `body` on its own thread; `wait` blocks until it returned and gives its result.
private final class Background<T: Sendable>: Sendable {
    private let result = Mutex<T?>(nil)
    private let done = DispatchSemaphore(value: 0)

    init(_ body: @escaping @Sendable () -> T) {
        Thread { [self] in
            let value = body()
            result.withLock { $0 = value }
            done.signal()
        }.start()
    }

    func wait(timeout: TimeInterval = 10) -> T? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.withLock { $0 }
    }
}

private func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        usleep(100)
    }
    return true
}

private extension Interrupt.Outcome {
    var exitCode: Int32? {
        if case .exit(let code) = self { return code }
        return nil
    }
    var isYield: Bool {
        if case .yield = self { return true }
        return false
    }
}

/// In-process: the gate the CLI wires to its DispatchSources and its main flow.
@Suite("interrupt handling")
struct InterruptTests {
    @Test("kills every live group, emits one INTERRUPTED object, returns 128+signo")
    func handleKillsAndEmits() async throws {
        let h = Harness()
        let capture = Capture()
        let interrupt = Interrupt(writer: capture.writer, children: h.children)
        let task = Task { await h.runner.run(CommandSpec(executable: fixture("sleep.sh"), timeout: .seconds(60))) }
        #expect(await eventually { h.children.count == 1 })

        #expect(interrupt.handle(signal: SIGTERM) == 143)
        let r = await task.value
        #expect(r.signal == SIGKILL)
        #expect(h.children.isEmpty)

        #expect(capture.writes.count == 1)
        let obj = try decode(try #require(capture.writes.first))
        #expect(errorCode(obj) == "INTERRUPTED")
        guard case .object(let o) = obj else {
            Issue.record("not an object")
            return
        }
        #expect(o["ok"] == .bool(false))
    }

    @Test("once the kit exists the object reports it and the clipboard, and never says to re-run")
    func interruptedAfterKit() throws {
        let cases: [(Bool?, String)] = [(true, "cleared"), (false, "left alone"), (nil, "unknown")]
        for (cleared, word) in cases {
            let capture = Capture()
            let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
            #expect(interrupt.handle(signal: SIGINT, kit: "exports/feather-1", clipboardCleared: cleared) == 130)
            let obj = try decode(try #require(capture.writes.first))
            guard case .object(let o) = obj, case .array(let errors)? = o["errors"], case .object(let e)? = errors.first,
                case .string(let message)? = e["message"], case .string(let fix)? = e["fix"]
            else {
                Issue.record("shape")
                return
            }
            #expect(o["ok"] == .bool(false) && errorCode(obj) == "INTERRUPTED")
            #expect(message.contains("exports/feather-1") && message.contains("ledger.json") && message.contains(word))
            #expect(o["kit"] == .string("exports/feather-1") && o["ledgerRecorded"] == .bool(true))
            #expect(o["clipboardCleared"] == cleared.map(JSONValue.bool) ?? .null)
            for text in [message, fix] { #expect(!text.lowercased().contains("re-run") && !text.lowercased().contains("run again")) }
        }
    }

    @Test("a second signal after the kit exists but before main prints: exactly one object reaches stdout, either order")
    func oneObjectEvenWithAKit() throws {
        // The handler wins: one INTERRUPTED object that names the kit; main yields and writes nothing.
        let first = Capture()
        let handlerFirst = Interrupt(writer: first.writer, children: LiveChildren())
        #expect(handlerFirst.handle(signal: SIGINT, kit: "exports/feather-1", clipboardCleared: true) == 130)
        #expect(handlerFirst.finishMain(.result("export-cert", ["kit": .string("exports/feather-1")])).isYield)
        #expect(first.writes.count == 1)
        let obj = try decode(try #require(first.writes.first))
        #expect(errorCode(obj) == "INTERRUPTED" && first.writes[0].contains("exports/feather-1"))

        // Main wins: the success object is the only one; the late signal parks and writes nothing.
        let second = Capture()
        let mainFirst = Interrupt(writer: second.writer, children: LiveChildren())
        #expect(mainFirst.finishMain(.result("export-cert", ["kit": .string("exports/feather-1")])).exitCode == 0)
        #expect(mainFirst.handle(signal: SIGINT, kit: "exports/feather-1", clipboardCleared: true) == nil)
        #expect(second.writes.count == 1 && !second.writes[0].contains("INTERRUPTED"))
    }

    @Test("the cleanup hook runs once, after the kill and before the object is written; a second signal skips it")
    func cleanupOrdering() {
        let events = Mutex<[String]>([])
        let interrupt = Interrupt(writer: { _ in events.withLock { $0.append("write") } }, children: LiveChildren())
        #expect(interrupt.handle(signal: SIGINT, cleanup: { events.withLock { $0.append("cleanup") } }) == 130)
        #expect(interrupt.handle(signal: SIGINT, cleanup: { events.withLock { $0.append("again") } }) == nil)
        #expect(events.withLock { $0 } == ["cleanup", "write"])
    }

    @Test("exit codes are 128+signo for INT, TERM and HUP", arguments: signalCases)
    func exitCodes(signal: Int32, expected: Int32) {
        let capture = Capture()
        let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(interrupt.handle(signal: signal) == expected)
        #expect(capture.writes.count == 1)
    }

    @Test("round 3: a signal recorded before main writes makes finishMain yield without writing")
    func handlerWinsOrdering() throws {
        let w = GatedWriter(gate: isInterruptedObject)
        let interrupt = Interrupt(writer: w.writer, children: LiveChildren(), emitTimeout: .seconds(10))
        let handler = Background { interrupt.handle(signal: SIGTERM) }
        #expect(w.entered.wait(timeout: .now() + 10) == .success)  // the handler's write is in flight

        #expect(interrupt.finishMain(.result("x")).isYield)
        #expect(w.writes.count == 1, "main wrote while the handler owned stdout")

        w.release.signal()
        #expect(try #require(handler.wait()) == 143)
        #expect(w.writes.count == 1)
        #expect(errorCode(try decode(try #require(w.writes.first))) == "INTERRUPTED")
    }

    @Test("a signal during main's write: main yields, the handler exits 143, one ok:true object")
    func signalDuringMainWrite() throws {
        let w = GatedWriter(gate: isAnyObject)
        let interrupt = Interrupt(writer: w.writer, children: LiveChildren(), emitTimeout: .seconds(10))
        let main = Background { interrupt.finishMain(.result("x")) }
        #expect(w.entered.wait(timeout: .now() + 10) == .success)  // main is inside its write

        let handler = Background { interrupt.handle(signal: SIGTERM) }
        #expect(spin { interrupt.signalRecorded })
        w.release.signal()

        #expect(try #require(main.wait()).isYield)
        #expect(try #require(handler.wait()) == 143)
        #expect(w.writes.count == 1)
        let obj = try decode(try #require(w.writes.first))
        #expect(errorCode(obj) == nil)
        guard case .object(let o) = obj else {
            Issue.record("not an object")
            return
        }
        #expect(o["ok"] == .bool(true))
    }

    @Test("after main emitted and set exiting, a signal parks the handler")
    func signalAfterMainExit() {
        let capture = Capture()
        let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(interrupt.finishMain(.result("x")).exitCode == 0)
        #expect(interrupt.handle(signal: SIGTERM) == nil)
        #expect(capture.writes.count == 1)
    }

    @Test("a failing envelope exits 1; a failing write reports writeFailed")
    func mainExitAndFailure() {
        let capture = Capture()
        #expect(Interrupt(writer: capture.writer, children: LiveChildren()).finishMain(.fail("x", code: "E", message: "m")).exitCode == 1)

        struct Boom: Error {}
        let failing = Interrupt(writer: { _ in throw Boom() }, children: LiveChildren())
        guard case .writeFailed(let error) = failing.finishMain(.result("x")) else {
            Issue.record("expected writeFailed")
            return
        }
        #expect(error is Boom)
    }

    @Test("a render failure: writeFailed and exiting without a signal; yield when a signal came first")
    func renderFailure() {
        let unrenderable = Envelope.result("x", ["n": .number(.nan)])
        #expect((try? Output.render(unrenderable)) == nil, "fixture must fail to render")

        let capture = Capture()
        let plain = Interrupt(writer: capture.writer, children: LiveChildren())
        guard case .writeFailed = plain.finishMain(unrenderable) else {
            Issue.record("expected writeFailed")
            return
        }
        #expect(plain.handle(signal: SIGTERM) == nil)
        #expect(capture.writes.isEmpty)

        let signalled = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(signalled.handle(signal: SIGTERM) == 143)
        #expect(signalled.finishMain(unrenderable).isYield)
        #expect(capture.writes.count == 1)  // only INTERRUPTED
    }

    @Test("bounded: a stuck stderr report is abandoned after the timeout, a quick one completes")
    func boundedReport() {
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!Interrupt.bounded(timeout: .milliseconds(50)) { _ = stuck.wait(timeout: .now() + 20) })
        #expect(clock.now - start < .seconds(1))
        #expect(Interrupt.bounded(timeout: .seconds(5)) {})
    }

    @Test("a second signal parks; one object")
    func secondSignalParks() {
        let capture = Capture()
        let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
        #expect(interrupt.handle(signal: SIGINT) == 130)
        #expect(interrupt.handle(signal: SIGTERM) == nil)
        #expect(capture.writes.count == 1)
    }

    @Test("blocked writers: the handler still returns 128+signo within the emit timeout")
    func blockedWriters() throws {
        let clock = ContinuousClock()

        // The handler's own write never returns.
        let own = GatedWriter(gate: isInterruptedObject)
        defer { own.release.signal() }
        let i1 = Interrupt(writer: own.writer, children: LiveChildren(), emitTimeout: .milliseconds(50))
        var start = clock.now
        #expect(i1.handle(signal: SIGTERM) == 143)
        #expect(clock.now - start < .seconds(1))

        // Main's write never returns.
        let mainBlocked = GatedWriter(gate: isAnyObject)
        defer { mainBlocked.release.signal() }
        let i2 = Interrupt(writer: mainBlocked.writer, children: LiveChildren(), emitTimeout: .milliseconds(50))
        _ = Background { i2.finishMain(.result("x")) }
        #expect(mainBlocked.entered.wait(timeout: .now() + 10) == .success)
        start = clock.now
        #expect(i2.handle(signal: SIGTERM) == 143)
        #expect(clock.now - start < .seconds(1))
    }

    @Test("stress: main and handler race 2000 times; one write and one exit owner each time")
    func stress() {
        let clock = ContinuousClock()
        let start = clock.now
        var failures: [String] = []
        for i in 0..<2000 {
            let capture = Capture()
            let interrupt = Interrupt(writer: capture.writer, children: LiveChildren())
            let barrier = DispatchSemaphore(value: 0)
            let main = Background { barrier.wait(); return interrupt.finishMain(.result("x")) }
            let handler = Background { barrier.wait(); return interrupt.handle(signal: SIGTERM) }
            barrier.signal()
            barrier.signal()
            guard let outcome = main.wait(), let handlerResult = handler.wait() else {
                failures.append("\(i): a thread did not finish")
                continue
            }
            let handlerCode: Int32? = handlerResult
            let owners = (outcome.exitCode != nil ? 1 : 0) + (handlerCode != nil ? 1 : 0)
            if capture.writes.count != 1 { failures.append("\(i): \(capture.writes.count) writes") }
            if owners != 1 { failures.append("\(i): \(owners) exit owners") }
            if outcome.exitCode != nil && handlerCode != nil { failures.append("\(i): main exit and handler code") }
            if outcome.isYield && handlerCode != 143 { failures.append("\(i): yield without a handler exit") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        // Each Background.wait already fails an iteration that hangs (10 s). This bound only catches an emit that
        // blocks for its full timeout every time (2000 x 1 s), so it is generous enough not to flake under load.
        #expect(clock.now - start < .seconds(120))
    }

    @Test("all stdout goes through the gate: no print( in Sources/sideload")
    func noPrintInCLITarget() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/sideload")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("print("), "\(file.lastPathComponent) calls print(; write through Interrupt")
        }
    }
}

/// Runs the built debug `sideload` binary with the test hook (`SIDELOAD_TEST_SLEEP_CHILD`, debug builds only).
@Suite("signals against the sideload binary")
struct BinarySignalTests {
    private static func binaryURL(file: String = #filePath) -> URL? {
        var candidates: [URL] = []
        // The test bundle sits next to the executable in the products directory.
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("sideload"))
        }
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/sideload"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A pipe whose buffer is full and which nobody reads: any blocking write to it never returns.
    private static func fullPipe() throws -> (reader: FileHandle, writer: FileHandle) {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        let flags = fcntl(fds[1], F_GETFL)
        _ = fcntl(fds[1], F_SETFL, flags | O_NONBLOCK)
        let chunk = [UInt8](repeating: 0x20, count: 4096)
        while write(fds[1], chunk, chunk.count) > 0 {}
        _ = fcntl(fds[1], F_SETFL, flags)
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    /// True once the readiness marker holds its full line.
    private static func isReady(_ path: String) -> Bool {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").hasSuffix("\n")
    }

    /// For expectation messages: how the process ended (only meaningful once it has exited).
    private static func termination(_ process: Process) -> String {
        guard !process.isRunning else { return " (still running)" }
        return " (terminationReason \(process.terminationReason == .exit ? "exit" : "uncaughtSignal"), terminationStatus \(process.terminationStatus))"
    }

    @Test("SIGTERM ends the process even when stdout is a full pipe nobody reads (main blocked in its write)")
    func blockedStdoutMainWrite() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready").path
        let pipe = try Self.fullPipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["help"]  // an immediate result before the home is touched, no real doctor run on the host
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_TEST_READY"] = ready  // written once the signal handlers exist (debug builds)
        process.environment = env
        process.standardOutput = pipe.writer
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        guard await eventually(timeout: .seconds(10), { Self.isReady(ready) }) else {
            process.terminate()
            Issue.record("sideload never reported its signal handlers installed\(Self.termination(process))")
            return
        }
        try await Task.sleep(for: .milliseconds(200))  // main reaches its blocked result write right after the marker
        #expect(process.isRunning, "sideload exited before the signal\(Self.termination(process))")
        let clock = ContinuousClock()
        let start = clock.now
        kill(process.processIdentifier, SIGTERM)
        let exited = await eventually(timeout: .seconds(5)) { !process.isRunning }
        if !exited { kill(process.processIdentifier, SIGKILL) }
        #expect(exited, "sideload ignored SIGTERM while stdout was blocked")
        #expect(clock.now - start < .seconds(4))
        #expect(process.terminationReason == .exit, "\(Self.termination(process))")
        #expect(process.terminationStatus == 143, "\(Self.termination(process))")
        withExtendedLifetime(pipe.reader) {}
    }

    @Test("SIGTERM kills the child tree and ends the process when the handler's own write would block")
    func blockedStdoutHandlerWrite() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pids").path
        let pipe = try Self.fullPipe()
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_TEST_SLEEP_CHILD"] = fixture("hang-tree.sh")
        env["SIDELOAD_TEST_MARKER"] = marker
        process.environment = env
        process.standardOutput = pipe.writer
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let started = await eventually(timeout: .seconds(15)) {
            ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        guard started else {
            process.terminate()
            Issue.record("child tree never started")
            return
        }
        let tree = ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        kill(process.processIdentifier, SIGTERM)
        let exited = await eventually(timeout: .seconds(5)) { !process.isRunning }
        if !exited { kill(process.processIdentifier, SIGKILL) }
        #expect(exited, "sideload ignored SIGTERM while stdout was blocked")
        #expect(process.terminationReason == .exit, "\(Self.termination(process))")
        #expect(process.terminationStatus == 143, "\(Self.termination(process))")
        for pid in tree {
            #expect(await eventually(timeout: .seconds(5)) { !isAlive(pid) }, "pid \(pid) survived")
        }
        withExtendedLifetime(pipe.reader) {}
    }

    @Test("SIGINT/SIGTERM/SIGHUP: one INTERRUPTED object, exit 128+signo, child tree dead",
        arguments: signalCases)
    func interrupted(signal sig: Int32, expectedExit: Int32) async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pids").path

        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_TEST_SLEEP_CHILD"] = fixture("hang-tree.sh")
        env["SIDELOAD_TEST_MARKER"] = marker
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // The fixture writes "<shell pid> <grandchild pid>" once the tree is up, which is after the
        // handlers were installed and the runner registered the group.
        func pids() -> [Int32] {
            let text = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
            guard text.hasSuffix("\n") else { return [] }
            return text.split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard await eventually(timeout: .seconds(15), { pids().count == 2 }) else {
            process.terminate()
            Issue.record("child tree never started")
            return
        }
        let tree = pids()
        #expect(tree.allSatisfy(isAlive))

        kill(process.processIdentifier, sig)
        if !(await eventually(timeout: .seconds(10)) { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("sideload did not exit after the signal")
            return
        }

        #expect(process.terminationReason == .exit, "\(Self.termination(process))")
        #expect(process.terminationStatus == expectedExit, "\(Self.termination(process))")
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = output.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(output.hasSuffix("\n"))
        let obj = try decode(String(try #require(lines.first)))
        #expect(errorCode(obj) == "INTERRUPTED")
        for pid in tree {
            #expect(await eventually(timeout: .seconds(5)) { !isAlive(pid) }, "pid \(pid) survived \(sig)")
        }
    }

    @Test("SIGINT while a renewal report is registered: the real handler prints it in the one INTERRUPTED object")
    func renewReportOnSignal() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pids").path
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_TEST_SLEEP_CHILD"] = fixture("hang-tree.sh")
        env["SIDELOAD_TEST_MARKER"] = marker
        env["SIDELOAD_TEST_RENEW_MOVED"] = "2"
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        guard await eventually(timeout: .seconds(15), { ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").hasSuffix("\n") }) else {
            process.terminate()
            Issue.record("child tree never started")
            return
        }
        kill(process.processIdentifier, SIGINT)
        if !(await eventually(timeout: .seconds(10)) { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("sideload did not exit after the signal")
            return
        }
        #expect(process.terminationStatus == 130, "\(Self.termination(process))")
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.split(separator: "\n").count == 1)
        let obj = try decode(output)
        guard case .object(let o) = obj, case .array(let errors)? = o["errors"], case .object(let e)? = errors.first,
            case .string(let message)? = e["message"]
        else {
            Issue.record("shape")
            return
        }
        #expect(errorCode(obj) == "INTERRUPTED")
        #expect(message == "Interrupted by SIGINT after provision --renew moved 2 cached profiles into tmp/.")
        #expect(o["cachedProfilesMoved"] == .number(2))
        #expect(o["app"] == .string("stremio-ios"))
        for key in ["cachedProfilesSkipped", "cachedProfilesMovedTo", "cachedProfilesStrayInTmp", "renewScanTruncated"] {
            #expect(o[key] != nil, "\(key)")
        }
        if let tree = (try? String(contentsOfFile: marker, encoding: .utf8))?.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
            for pid in tree { #expect(await eventually(timeout: .seconds(5)) { !isAlive(pid) }, "pid \(pid) survived") }
        }
    }

    @Test("SIGINT during a provision run without --renew: provision's own registration puts the ledger's leftovers in the object")
    func provisionLeftoversOnSignal() async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let ledger = Ledger(freeRenewMoves: [
            LedgerFreeRenewMove(
                from: "old.mobileprovision", to: "tmp/renewed-profile-0123456789ab.mobileprovision", at: testNow, state: .done,
                folder: "mobiledevice")
        ])
        try LedgerStore.encode(ledger).write(to: URL(fileURLWithPath: home + "/ledger.json"))
        let marker = dir.appendingPathComponent("pids").path
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_HOME"] = home
        env["SIDELOAD_TEST_SLEEP_CHILD"] = fixture("hang-tree.sh")
        env["SIDELOAD_TEST_MARKER"] = marker
        env["SIDELOAD_TEST_PROVISION_REGISTER"] = "1"
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        guard await eventually(timeout: .seconds(15), { ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").hasSuffix("\n") }) else {
            process.terminate()
            Issue.record("child tree never started")
            return
        }
        kill(process.processIdentifier, SIGINT)
        if !(await eventually(timeout: .seconds(10)) { !process.isRunning }) {
            kill(process.processIdentifier, SIGKILL)
            Issue.record("sideload did not exit after the signal")
            return
        }
        #expect(process.terminationStatus == 130, "\(Self.termination(process))")
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let obj = try decode(output)
        guard case .object(let o) = obj, case .array(let listed)? = o["cachedProfilesFromEarlierRun"] else {
            Issue.record("no cachedProfilesFromEarlierRun in \(output)")
            return
        }
        #expect(errorCode(obj) == "INTERRUPTED" && listed.count == 1)
        if case .object(let entry)? = listed.first {
            #expect(entry["folder"] == .string("mobiledevice") && entry["state"] == .string("done"))
        }
        #expect(o["cachedProfilesMoved"] == nil)
        #expect(!output.contains(home))
    }

    @Test("a signal removes a registered inspect scratch folder (unreadable directories included) before the process exits",
        arguments: signalCases)
    func scratchRemovedOnSignal(signal sig: Int32, expectedExit: Int32) async throws {
        let binary = try #require(Self.binaryURL(), "build the sideload executable first (swift build)")
        let dir = try makeTempDir()
        defer { _ = ScratchDirectory.removeTree(dir.path) }
        let marker = dir.appendingPathComponent("pids").path
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["SIDELOAD_TEST_SLEEP_CHILD"] = fixture("hang-tree.sh")
        env["SIDELOAD_TEST_MARKER"] = marker
        env["SIDELOAD_TEST_SCRATCH"] = "1"
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        guard await eventually(timeout: .seconds(15), { ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").hasSuffix("\n") }) else {
            process.terminate()
            Issue.record("child tree never started")
            return
        }
        // The hook made the folder itself (with an unreadable directory inside) and wrote its path here.
        let scratch = try String(contentsOfFile: marker + ".scratch", encoding: .utf8)
        defer { _ = ScratchDirectory.removeTree(scratch) }
        #expect(scratch.contains("/sideload-hook-") && FileManager.default.fileExists(atPath: scratch))
        kill(process.processIdentifier, sig)
        let exited = await eventually(timeout: .seconds(10)) { !process.isRunning }
        if !exited { kill(process.processIdentifier, SIGKILL) }
        #expect(exited, "sideload did not exit after the signal\(Self.termination(process))")
        #expect(process.terminationReason == .exit, "\(Self.termination(process))")
        #expect(process.terminationStatus == expectedExit, "\(Self.termination(process))")
        #expect(!FileManager.default.fileExists(atPath: scratch), "the scratch folder must be gone when the process has exited")
        let lines = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(errorCode(try decode(String(try #require(lines.first)))) == "INTERRUPTED")
    }
}
