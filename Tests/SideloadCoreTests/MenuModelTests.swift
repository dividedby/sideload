import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu

/// Blocks the first two calls until the test releases them (in order of arrival); every later call returns at once.
private final class GateRunner: Runner {
    private struct State {
        var calls = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func run(_ spec: CommandSpec) async -> RunResult {
        let blocks = state.withLock { st -> Bool in
            st.calls += 1
            return st.calls <= 2
        }
        if blocks {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                state.withLock { $0.waiters.append(c) }
            }
        }
        return RunResult()
    }

    var calls: Int { state.withLock { $0.calls } }
    var waiting: Int { state.withLock { $0.waiters.count } }

    func release(_ index: Int) {
        let waiter = state.withLock { $0.waiters[index] }
        waiter.resume()
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for a condition")
}

@MainActor
@Suite("menu: view model")
struct MenuModelTests {
    @Test("a cancelled doctor run that finishes late cannot write over a newer run")
    func staleDoctorRunIsIgnored() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = GateRunner()
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow), keychain: FakeKeychain(),
            home: Paths(home: dir.path))
        let model = MenuModel(services: services)

        model.runDoctor()
        try await until { runner.waiting == 1 }
        model.cancelDoctor()
        #expect(model.doctor == .idle)

        model.runDoctor()
        try await until { runner.waiting == 2 }
        #expect(model.doctor == .running)

        // The old run finishes first. Without the generation token it would write `.done` over the new run.
        runner.release(0)
        // Give the released run time to finish. A slow machine only weakens this check, it cannot fail it.
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.doctor == .running)

        runner.release(1)
        try await until {
            if case .done = model.doctor { return true }
            return false
        }
    }
}
