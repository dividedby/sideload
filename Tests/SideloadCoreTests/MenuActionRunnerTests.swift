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
