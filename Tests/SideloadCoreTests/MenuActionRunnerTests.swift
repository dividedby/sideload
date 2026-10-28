import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private final class Log: Sendable {
    private let lines = Mutex<[String]>([])
    var value: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

private func services() -> Services {
    Services(
        runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
        keychain: FakeKeychain(), home: Paths(home: "/nonexistent-sideload-home"))
}

private func steps(_ log: Log, ok: Bool = true, work: @escaping @Sendable (Services) -> Void = { _ in }) -> MenuActionSteps {
    @Sendable func envelope(_ command: String) -> Envelope {
        ok ? .result(command) : .fail(command, code: "BOOM", message: "It failed.")
    }
    var steps = MenuActionSteps()
    steps.refresh = { services, options in
        log.add("refresh \(options)")
        work(services)
        return envelope("refresh")
    }
    steps.install = { services, options in
        log.add("install \(options)")
        work(services)
        return envelope("install")
    }
    steps.remove = { services, options in
        log.add("remove \(options)")
        work(services)
        return envelope("app remove")
    }
    steps.lendable = { services, options in
        log.add("lendable \(options)")
        work(services)
        return envelope("device lendable")
    }
    return steps
}

@Suite("menu action runner")
struct MenuActionRunnerTests {
    @Test("each action sends exactly its options, with the owner's --yes, and nothing else")
    func options() async {
        let log = Log()
        let cases: [(MenuAction, String)] = [
            (
                .renew(device: "iphone", app: "apollo"),
                "refresh \(RefreshOptions(device: "iphone", app: "apollo", within: nil, force: true, yes: true))"
            ),
            (.install(device: "iphone", app: "apollo"), "install \(InstallOptions(app: "apollo", device: "iphone", yes: true))"),
            (
                .remove(device: "iphone", app: "apollo"),
                "remove \(AppOptions(sub: "remove", app: "apollo", device: "iphone", yes: true))"
            ),
            (
                .lendable(device: "iphone", app: "apollo"),
                "lendable \(DeviceOptions(sub: "lendable", alias: "iphone", app: "apollo", none: false, yes: true))"
            ),
            (
                .lendable(device: "iphone", app: nil),
                "lendable \(DeviceOptions(sub: "lendable", alias: "iphone", app: nil, none: true, yes: true))"
            ),
        ]
        for (action, expected) in cases {
            let before = log.value.count
            await MenuActionRunner.perform(action, services: services(), steps: steps(log), isCancelled: { false }) { _ in }
            #expect(log.value.dropFirst(before) == [expected][...], "\(action)")
        }
    }

    @Test("the outcome is delivered first, then the post-result work runs")
    func postEmitAfterDeliver() async {
        let log = Log()
        let work = steps(log) { $0.postEmit.add { log.add("postEmit") } }
        await MenuActionRunner.perform(
            .renew(device: "iphone", app: "apollo"), services: services(), steps: work, isCancelled: { false }
        ) { outcome in
            log.add("deliver \(outcome.kind)")
        }
        #expect(log.value.suffix(2) == ["deliver done", "postEmit"])
    }

    @Test("a cancelled action delivers a Cancelled outcome and skips the post-result work, which is not run by the next action")
    func cancelledSkipsPostEmit() async {
        let log = Log()
        let first = steps(log, ok: false) { $0.postEmit.add { log.add("postEmit-from-first") } }
        let kinds = Mutex<[MenuActionOutcome.Kind]>([])
        await MenuActionRunner.perform(
            .renew(device: "iphone", app: "apollo"), services: services(), steps: first, isCancelled: { true }
        ) { outcome in
            kinds.withLock { $0.append(outcome.kind) }
        }
        #expect(kinds.withLock { $0 } == [.cancelled])
        #expect(!log.value.contains("postEmit-from-first"))

        // The next action starts with nothing registered: the first one's work is gone, not run late.
        await MenuActionRunner.perform(
            .install(device: "iphone", app: "apollo"), services: services(), steps: steps(log), isCancelled: { false }
        ) { _ in }
        #expect(!log.value.contains("postEmit-from-first"))
    }

    /// A home with a ledger file; `body` shapes it (nil leaves the file unwritten, `garbage` makes it unreadable).
    private func lendableRun(
        _ action: MenuAction, ledger body: ((inout Ledger) -> Void)?, garbage: Bool = false
    ) async throws -> (log: [String], outcomes: [MenuActionOutcome]) {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        if let body { try await LedgerStore(paths: paths).update { body(&$0) } }
        if garbage { try Data("{ not json".utf8).write(to: URL(fileURLWithPath: paths.ledger)) }
        let services = Services(
            runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
            keychain: FakeKeychain(), home: paths)
        let log = Log()
        let outcomes = Mutex<[MenuActionOutcome]>([])
        await MenuActionRunner.perform(action, services: services, steps: steps(log), isCancelled: { false }) { outcome in
            outcomes.withLock { $0.append(outcome) }
        }
        return (log.value, outcomes.withLock { $0 })
    }

    @Test("the lendable setting reads the ledger again: a lent or pending slot on the device stops it, others do not")
    func lendableGate() async throws {
        let setting = MenuAction.lendable(device: "iphone", app: "apollo")

        let clear = try await lendableRun(setting) { $0.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .present)] }
        #expect(clear.log.count == 1 && clear.log[0].hasPrefix("lendable ") && clear.outcomes.map(\.kind) == [.done])
        let empty = try await lendableRun(setting, ledger: nil)
        #expect(empty.log.count == 1 && empty.outcomes.map(\.kind) == [.done])

        let lent = try await lendableRun(setting) {
            $0.slots = [LedgerSlot(device: "iphone", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        }
        #expect(lent.log.isEmpty)
        #expect(lent.outcomes.map(\.kind) == [.failed] && lent.outcomes.first?.headline == "Not run")
        #expect(lent.outcomes.first?.issues.first?.message == MenuActions.lentOrChanging("iphone"))

        let pending = try await lendableRun(.lendable(device: "iphone", app: nil)) {
            $0.slots = [
                LedgerSlot(
                    device: "iphone", app: "apollo", presence: .unknown,
                    op: LedgerSlotOp(kind: .install, by: .install, startedAt: testNow, window: 600))
            ]
        }
        #expect(pending.log.isEmpty && pending.outcomes.first?.issues.first?.message == MenuActions.lentOrChanging("iphone"))

        let stale = try await lendableRun(setting) {
            $0.slots = [
                LedgerSlot(
                    device: "iphone", app: "apollo", presence: .unknown,
                    op: LedgerSlotOp(kind: .install, by: .install, startedAt: testNow.addingTimeInterval(-3_600), window: 600))
            ]
        }
        #expect(stale.log.count == 1 && stale.outcomes.map(\.kind) == [.done])

        let other = try await lendableRun(setting) {
            $0.slots = [LedgerSlot(device: "ipad", app: "apollo", presence: .absent, lentTo: "lab", since: testNow)]
        }
        #expect(other.log.count == 1)
    }

    @Test("the lendable setting is not written when the ledger cannot be read")
    func lendableUnreadable() async throws {
        let run = try await lendableRun(.lendable(device: "iphone", app: "apollo"), ledger: nil, garbage: true)
        #expect(run.log.isEmpty)
        #expect(run.outcomes.first?.issues.first?.message == MenuActions.ledgerUnreadable)
    }

    @Test("each action gets its own PostEmit and InterruptReport, whatever the services passed in")
    func freshPerAction() async {
        let shared = services()
        let seen = Mutex<[PostEmit]>([])
        let reports = Mutex<[InterruptReport]>([])
        let probe = steps(Log()) { services in
            seen.withLock { $0.append(services.postEmit) }
            reports.withLock { $0.append(services.interruptReport) }
        }
        for _ in 0..<2 {
            await MenuActionRunner.perform(.install(device: "iphone", app: "apollo"), services: shared, steps: probe, isCancelled: { false }) { _ in }
        }
        let posts = seen.withLock { $0 }
        let interrupts = reports.withLock { $0 }
        #expect(posts.count == 2 && posts[0] !== posts[1] && posts[0] !== shared.postEmit)
        #expect(interrupts.count == 2 && interrupts[0] !== interrupts[1] && interrupts[0] !== shared.interruptReport)
    }

    @Test("a task cancelled inside a step makes the failure a Cancelled outcome, by the default flag")
    func taskCancel() async {
        let kinds = Mutex<[MenuActionOutcome.Kind]>([])
        var cancelling = MenuActionSteps()
        cancelling.refresh = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .fail("refresh", code: "SIGNING_FAILED", message: "killed")
        }
        let task = Task {
            await MenuActionRunner.perform(.renew(device: "iphone", app: "apollo"), services: services(), steps: cancelling) { outcome in
                kinds.withLock { $0.append(outcome.kind) }
            }
        }
        await task.value
        #expect(kinds.withLock { $0 } == [.cancelled])
    }
}
