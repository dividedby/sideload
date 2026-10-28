import Foundation
import Synchronization
import Testing

@testable import SideloadCore

private final class Calls: Sendable {
    private let state = Mutex<[String?]>([])
    var apps: [String?] { state.withLock { $0 } }
    func add(_ app: String?) { state.withLock { $0.append(app) } }
}

private func services() -> Services {
    Services(
        runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
        keychain: FakeKeychain(), home: Paths(home: "/nonexistent-sideload-home"))
}

private func renewed(_ app: String) -> Envelope {
    Envelope(
        ok: true, command: "refresh",
        data: ["results": [["app": .string(app), "status": "renewed", "daysLeftBefore": 3, "daysLeftAfter": 7]]])
}

private func failed(_ app: String, _ code: String) -> Envelope {
    Envelope(
        ok: false, command: "refresh",
        data: ["results": [["app": .string(app), "status": "failed", "code": .string(code)]]],
        errors: [.init(code: code, message: "\(app): \(code) happened.", fix: "Fix \(code).")])
}

private func steps(_ calls: Calls, _ reply: @escaping @Sendable (String) -> Envelope) -> MenuActionSteps {
    var steps = MenuActionSteps()
    steps.refresh = { _, options in
        calls.add(options.app)
        #expect(options.force && options.yes && options.device == "iphone")
        return reply(options.app ?? "")
    }
    return steps
}

private let all = MenuAction.renew(device: "iphone", app: nil)

@Suite("menu action runner: Renew all apps")
struct MenuRenewAllRunTests {
    @Test("one refresh per listed app, in order, each with its app set and never without one")
    func listedOnly() async {
        let calls = Calls()
        let kind = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            all, renewApps: ["stremio-ios", "apollo"], services: services(), steps: steps(calls, renewed), isCancelled: { false }
        ) { outcome in kind.withLock { $0 = outcome } }
        #expect(calls.apps == ["stremio-ios", "apollo"])
        let outcome = kind.withLock { $0 }
        #expect(outcome?.kind == .done && outcome?.headline == "Renewed 2 apps on iphone")
        #expect(outcome?.lines.map(\.name) == ["Stremio", "Apollo"])
    }

    @Test("an empty list calls nothing, whatever refresh would select")
    func emptyList() async {
        let calls = Calls()
        await MenuActionRunner.perform(
            all, renewApps: [], services: services(), steps: steps(calls, renewed), isCancelled: { false }
        ) { _ in }
        #expect(calls.apps.isEmpty)
    }

    @Test("an app's own failure does not stop the others; each failed app keeps its message and a Retry")
    func continuesPastFailure() async {
        let calls = Calls()
        let result = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            all, renewApps: ["stremio-ios", "apollo"], services: services(),
            steps: steps(calls) { $0 == "stremio-ios" ? failed($0, "DEVICE_LOCKED") : renewed($0) }, isCancelled: { false }
        ) { outcome in result.withLock { $0 = outcome } }
        #expect(calls.apps == ["stremio-ios", "apollo"])
        let outcome = result.withLock { $0 }
        #expect(outcome?.kind == .failed)
        #expect(outcome?.lines[0].issue?.code == "DEVICE_LOCKED" && outcome?.lines[0].retry == .renew(device: "iphone", app: "stremio-ios"))
        #expect(outcome?.lines[1].text == "Renewed · 3 d → 7 d")
    }

    @Test("a fatal stop skips the rest with its code, using refresh's own fatal set")
    func fatalStop() async {
        for code in ["FREE_CERT_CHANGED", "KEYCHAIN_LOCKED", "SLOT_PENDING", "FREE_IDENTITY_AMBIGUOUS"] {
            let calls = Calls()
            let result = Mutex<MenuActionOutcome?>(nil)
            // A pre-run stop carries no results, as refresh throws before any app.
            await MenuActionRunner.perform(
                all, renewApps: ["stremio-ios", "apollo", "filler"], services: services(),
                steps: steps(calls) { _ in .fail("refresh", code: code, message: "Stopped.", fix: "Fix it.") },
                isCancelled: { false }
            ) { outcome in result.withLock { $0 = outcome } }
            #expect(calls.apps == ["stremio-ios"], "\(code)")
            let outcome = result.withLock { $0 }
            #expect(outcome?.kind == .failed, "\(code)")
            #expect(outcome?.lines.map(\.text).suffix(2) == ["Skipped · \(code)", "Skipped · \(code)"], "\(code)")
        }
    }

    @Test("a busy lock stops the run: nothing renewed is the busy card, something renewed is a failure naming the rest")
    func busyStops() async {
        let calls = Calls()
        let first = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            all, renewApps: ["stremio-ios", "apollo"], services: services(),
            steps: steps(calls) { failed($0, "OPERATION_IN_PROGRESS") }, isCancelled: { false }
        ) { outcome in first.withLock { $0 = outcome } }
        #expect(calls.apps == ["stremio-ios"])
        #expect(first.withLock { $0 }?.kind == .busy)

        let calls2 = Calls()
        let second = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            all, renewApps: ["stremio-ios", "apollo"], services: services(),
            steps: steps(calls2) { $0 == "stremio-ios" ? renewed($0) : failed($0, "OPERATION_IN_PROGRESS") }, isCancelled: { false }
        ) { outcome in second.withLock { $0 = outcome } }
        #expect(calls2.apps == ["stremio-ios", "apollo"])
        #expect(second.withLock { $0 }?.kind == .failed)
    }

    @Test("a cancel stops between apps: the rest are skipped, and the outcome is Cancelled")
    func cancelBetweenApps() async {
        let calls = Calls()
        let result = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            all, renewApps: ["stremio-ios", "apollo", "filler"], services: services(), steps: steps(calls, renewed),
            isCancelled: { calls.apps.count >= 1 }
        ) { outcome in result.withLock { $0 = outcome } }
        #expect(calls.apps == ["stremio-ios"])
        let outcome = result.withLock { $0 }
        #expect(outcome?.kind == .cancelled)
        #expect(outcome?.lines.map(\.text) == ["Renewed · 3 d → 7 d"])
    }
}
