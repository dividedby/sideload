import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu
@testable import sideload

// Remove source in the menu bar app (design section 12): the list of the owner's sources, the local preview, the confirm card,
// the confirm click as `source remove --yes`, the check that the source did not change before the click, and the view model's
// flow. Fakes and temp homes only; nothing here has run in the built app.

private func removal(_ step: MenuSourceRemoveStep) -> MenuSourceRemoval? {
    if case .confirm(let removal) = step { return removal }
    return nil
}

private func failure(_ step: MenuSourceRemoveStep) -> MenuIssue? {
    if case .failed(let issue) = step { return issue }
    return nil
}

private func listed(_ picker: MenuSourceRemovePicker) -> [MenuRemovableSource]? {
    if case .choosing(let listed, _) = picker { return listed }
    return nil
}

private let secondEntry: [String: JSONValue] = altstoreEntry.merging(["app": "second"]) { $1 }

private func apply(_ edit: [String: JSONValue], _ services: Services) async throws {
    try await services.store.update { config in
        for (key, value) in edit {
            if key == "approvedSources", case .array(let list) = value {
                config.approvedSources = list
            } else {
                config.extra[key] = value
            }
        }
    }
}

/// `myapp` (GitHub) and `second` (AltStore index), both approved, both custom apps.
private func twoSources() -> Config {
    var config = customConfig(
        sources: [githubEntry, secondEntry], approved: [["app": "myapp"], ["app": "second"]])
    config.extra["customApps"] = [
        ["id": "myapp", "platform": "ios"], ["id": "second", "platform": "ios"],
    ]
    return config
}

/// Removes `myapp`'s entry, as a second front end would between the list and the pick.
private func keepOnlySecond(_ paths: Paths) async throws {
    try await ConfigStore(paths: paths).update { config in
        config.extra["customSources"] = .array([.object(secondEntry)])
    }
}

@Suite("menu remove source: the list and the preview")
struct MenuRemoveSourceReadTests {
    @Test(
        "the list has each added source once, in file order, with its kind and host; built-ins are left out"
    )
    func list() async throws {
        var config = twoSources()
        let builtIn: [String: JSONValue] = githubEntry.merging(["app": "apollo"]) { $1 }
        config.extra["customSources"] = .array(
            [githubEntry, githubEntry, secondEntry, builtIn].map(JSONValue.object))
        try await withSourceHome(config: config, http: SourceHTTP()) { _, services in
            let sources = try #require(listed(MenuSourceRemove.list(services)))
            #expect(sources.map(\.app) == ["myapp", "second"])
            #expect(sources[0].title.hasSuffix(" · myapp"))
            #expect(sources[0].detail == "GitHub release · acme/widget")
            #expect(sources[1].detail == "AltStore index · index.example.org")
        }
    }

    @Test(
        "no added source is an empty list; a customSources that is not an array is CONFIG_INVALID")
    func emptyAndInvalid() async throws {
        try await withSourceHome(config: sourceBaseConfig(), http: SourceHTTP()) { _, services in
            #expect(MenuSourceRemove.list(services) == .choosing([], problem: nil))
        }
        let broken = sourceBaseConfig(extra: ["customSources": "oops"])
        try await withSourceHome(config: broken, http: SourceHTTP()) { _, services in
            guard case .failed(let issue) = MenuSourceRemove.list(services) else {
                Issue.record("expected a failure")
                return
            }
            #expect(issue.code == "CONFIG_INVALID")
        }
    }

    @Test(
        "the preview reads local files only, writes nothing, and the confirm says what goes and what stays"
    )
    func preview() async throws {
        let http = SourceHTTP()
        try await withSourceHome(config: twoSources(), http: http) { paths, services in
            let before = try configBytes(paths)
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "second")))
            let prompt = MenuSourceRemove.prompt(source)
            #expect(prompt.title == "Remove the source for \(source.name)?")
            #expect(prompt.destructive && prompt.confirmLabel == "Remove source")
            #expect(prompt.lines.first == "Address https://index.example.org/apps/index.json")
            #expect(prompt.monospacedLines == [0])
            #expect(prompt.lines.contains("Kind AltStore index"))
            #expect(
                prompt.lines.contains(
                    "Removes 1 customSources entry and 1 approvedSources entry from config.json"))
            #expect(prompt.lines.contains("Stays: the app second. Renew keeps working."))
            #expect(http.getRequests.isEmpty)
            #expect(try configBytes(paths) == before)
            // A printed action carries no address.
            #expect("\(MenuAction.removeSource(source))".contains("index.example.org") == false)
        }
    }

    @Test("a built-in app is SOURCE_BUILT_IN and an unknown one SOURCE_NOT_FOUND")
    func refusals() async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { _, services in
            #expect(
                failure(MenuSourceRemove.preview(services, app: "apollo"))?.code
                    == "SOURCE_BUILT_IN")
            #expect(
                failure(MenuSourceRemove.preview(services, app: "nothere"))?.code
                    == "SOURCE_NOT_FOUND")
        }
    }
}

@Suite("menu remove source: the confirm and the run")
struct MenuRemoveSourceRunTests {
    private func perform(
        _ source: MenuSourceRemoval, services: Services, steps: MenuActionSteps = MenuActionSteps()
    ) async -> MenuActionOutcome? {
        let outcome = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            .removeSource(source), services: services, steps: steps, isCancelled: { false }
        ) { result in
            outcome.withLock { $0 = result }
        }
        return outcome.withLock { $0 }
    }

    @Test("the confirm click hands the command the preview the owner saw")
    func handsPreview() async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { _, services in
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            let seen = Mutex<SourceRemovePreview?>(nil)
            var steps = MenuActionSteps()
            steps.removeSource = { _, preview in
                seen.withLock { $0 = preview }
                return Envelope(ok: true, command: "source remove")
            }
            _ = await perform(source, services: services, steps: steps)
            #expect(seen.withLock { $0 } == source.preview)
        }
    }

    @Test(
        "the real run removes only that source and its approval; the app stays and Add app… no longer offers it"
    )
    func removes() async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { paths, services in
            let before = try loadConfig(paths)
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            #expect(menuBuild(config: before).addSources.contains { $0.app == "myapp" })

            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .done, "\(outcome.issues)")
            #expect(outcome.headline == "Removed the source for \(source.name)")
            #expect(outcome.notes == [MenuSourceRemove.removedNote])
            expectLockFree(paths)

            let after = try loadConfig(paths)
            #expect(after.extra["customSources"] == [.object(secondEntry)])
            #expect(!after.approvedSources.contains(["app": "myapp"]))
            #expect(after.extra["customApps"] == before.extra["customApps"])
            #expect(!menuBuild(config: after).addSources.contains { $0.app == "myapp" })
        }
    }

    /// The edits a second front end could make between the preview and the click: remove the source, re-add it at another
    /// address, or drop its approval.
    static let edits: [[String: JSONValue]] = [
        ["customSources": .array([.object(secondEntry)])],
        [
            "customSources": .array(
                [githubEntry.merging(["repo": "evil/widget"]) { $1 }, secondEntry].map(
                    JSONValue.object))
        ],
        ["approvedSources": .array([["app": "second"]])],
    ]

    @Test(
        "a source removed or changed after the confirm opened is SOURCE_CHANGED with no retry, and nothing is written",
        arguments: edits)
    func changed(_ edit: [String: JSONValue]) async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { paths, services in
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            try await apply(edit, services)
            let before = try configBytes(paths)
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .failed)
            #expect(outcome.headline == "The source changed since you reviewed it")
            #expect(outcome.issues.first?.code == "SOURCE_CHANGED")
            #expect(outcome.notes == [MenuSourceRemove.changedNote] && outcome.lines.isEmpty)
            #expect(try configBytes(paths) == before)
            expectLockFree(paths)
        }
    }

    @Test(
        "the comparison is made under the lock: a change landing just before the command takes it is still refused",
        arguments: edits)
    func changedJustBeforeTheLock(_ edit: [String: JSONValue]) async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { paths, services in
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            let before = Mutex<Data?>(nil)
            var steps = MenuActionSteps()
            // The edit lands after the menu handed over and before `source remove` takes `.op.lock`.
            steps.removeSource = { services, preview in
                try? await apply(edit, services)
                before.withLock { $0 = try? configBytes(paths) }
                return await SourceCommand.removeReviewed(services, preview)
            }
            let outcome = try #require(
                await perform(source, services: services, steps: steps))
            #expect(outcome.issues.first?.code == "SOURCE_CHANGED")
            #expect(try configBytes(paths) == before.withLock { $0 })
        }
    }

    @Test("a busy lock is the busy result with a retry, and nothing is removed")
    func busy() async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { paths, services in
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            let before = try configBytes(paths)
            let held = try OperationLock.acquire(paths: paths)
            defer { held.release() }
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .busy)
            #expect(outcome.lines.first?.retry == .removeSource(source))
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("the action needs no device and leaves the device read alone")
    func shape() async throws {
        try await withSourceHome(config: twoSources(), http: SourceHTTP()) { _, services in
            let source = try #require(removal(MenuSourceRemove.preview(services, app: "myapp")))
            let action = MenuAction.removeSource(source)
            #expect(action.device == "" && action.leavesDeviceReadAlone)
            let snapshot = menuBuild(config: try services.store.load())
            #expect(
                MenuActions.prompt(for: action, in: snapshot, now: testNow)
                    == MenuSourceRemove.prompt(source))
        }
    }
}

@MainActor
@Suite("menu remove source: view model")
struct MenuRemoveSourceModelTests {
    private struct World {
        let model: MenuModel
        let paths: Paths
        let dir: URL
    }

    private func world(config: Config) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        try await seed(paths, config: config, ledger: Ledger())
        let runner = SlowDeviceRunner(
            menuDeviceScript(
                devices: deviceListJSON(phoneEntryJSON(seed: "1")), apps: { _ in .apps([]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow),
            keychain: FakeKeychain(), home: paths, http: SourceHTTP())
        let model = MenuModel(services: services)
        model.reload(force: true)
        await model.loadTask?.value
        return World(model: model, paths: paths, dir: dir)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    private func picker(_ model: MenuModel) -> MenuSourceRemovePicker? {
        if case .removingSource(let picker) = model.actionState { return picker }
        return nil
    }

    @Test("list, pick, confirm, run: the source is removed and the panel redraws without it")
    func flow() async throws {
        let w = try await world(config: twoSources())
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(w.model.canRemoveSource)

        w.model.openRemoveSource()
        let sources = try #require(picker(w.model).flatMap(listed))
        #expect(sources.map(\.app) == ["myapp", "second"])
        #expect(!w.model.controlsEnabled && !w.model.canRemoveSource)

        w.model.chooseSourceToRemove(sources[0])
        guard case .confirming(.removeSource(let source), let prompt) = w.model.actionState else {
            Issue.record("expected the confirm, got \(w.model.actionState)")
            return
        }
        #expect(source.appId == "myapp" && prompt.destructive)
        // Nothing is written before the click.
        #expect(try loadConfig(w.paths).extra["customSources"]?.array?.count == 2)

        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected a result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done, "\(outcome.issues)")
        #expect(try loadConfig(w.paths).extra["customSources"]?.array?.count == 1)
        try await until {
            if case .loaded(let snapshot) = w.model.panel {
                return !snapshot.addSources.contains { $0.app == "myapp" }
            }
            return false
        }
        #expect(w.model.controlsEnabled)
    }

    @Test(
        "a pick whose source is gone stays on the list with why; Cancel closes it and writes nothing"
    )
    func goneAndCancel() async throws {
        let w = try await world(config: twoSources())
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openRemoveSource()
        let sources = try #require(picker(w.model).flatMap(listed))
        try await keepOnlySecond(w.paths)
        let before = try configBytes(w.paths)

        w.model.chooseSourceToRemove(sources[0])
        guard case .choosing(let still, let problem?) = picker(w.model) else {
            Issue.record("expected the list with a problem, got \(w.model.actionState)")
            return
        }
        #expect(still == sources && problem.code == "SOURCE_NOT_FOUND")

        w.model.dismiss()
        #expect(w.model.actionState == .idle && w.model.controlsEnabled)
        #expect(try configBytes(w.paths) == before)
    }
}
