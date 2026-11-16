import Foundation
import Synchronization
import Testing

@testable import SideloadCore
@testable import SideloadMenu
@testable import sideload

// Add source in the menu bar app (issue #47, PR C; design section 12): the address check, the one read-only preview, the picker
// for an index of several apps, the confirm card, the confirm click as `source add --yes` with the preview's confirm value, the
// outcome headlines and the view model's flow. Fakes and temp homes only; nothing here has run in the built app.

private func menuServices(_ paths: Paths, http: SourceHTTP) -> Services {
    Services(
        runner: FakeRunner(), fs: FakeFileSystem.free(gb: 50), clock: FixedClock(testNow),
        keychain: FakeKeychain(), home: paths, http: http)
}

private func plan(_ step: MenuSourceStep) -> MenuSourcePlan? {
    if case .confirm(let plan) = step { return plan }
    return nil
}

private func failure(_ step: MenuSourceStep) -> MenuIssue? {
    if case .failed(let issue) = step { return issue }
    return nil
}

private let manyApps = [
    IndexEntry(name: "One", bundleId: "io.example.one"),
    IndexEntry(name: "Two", bundleId: "io.example.two", url: "https://cdn.example.org/2.ipa"),
    IndexEntry(
        name: "NoDigest", bundleId: "io.example.nodigest", url: "https://cdn.example.org/3.ipa",
        sha256: nil),
]

@Suite("menu add source: reading and the picker")
struct MenuAddSourceReadTests {
    @Test("the address is checked with source add's rules before anything is read")
    func address() {
        #expect(MenuSourceAdd.urlProblem("") != nil && MenuSourceAdd.urlProblem("   ") != nil)
        #expect(MenuSourceAdd.urlProblem("http://index.example.org/i.json") != nil)
        #expect(MenuSourceAdd.urlProblem("https://user:pw@index.example.org/i.json") != nil)
        #expect(MenuSourceAdd.urlProblem("https://index.example.org:8443/i.json") != nil)
        #expect(MenuSourceAdd.urlProblem("https://index.example.org/i.json?x=1") != nil)
        #expect(MenuSourceAdd.urlProblem("https://localhost/i.json") != nil)
        #expect(MenuSourceAdd.urlProblem(widgetURL) == nil)
        #expect(MenuSourceAdd.urlProblem("  \(sourceIndexURL)\n") == nil)
        #expect(MenuSourceAdd.trimmedURL("  \(widgetURL)\n") == widgetURL)
    }

    @Test("a GitHub repository: one GET, the plan, and nothing written")
    func github() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await withSourceHome(config: menuConfig(), http: http) { paths, services in
            let before = try configBytes(paths)
            let step = await MenuSourceAdd.preview(services, url: " \(widgetURL) ")
            let source = try #require(plan(step), "\(step)")
            #expect(source.name == "Widget" && source.appId == "widget")
            #expect(source.confirm.wholeMatch(of: /[0-9a-f]{16}/) != nil)
            #expect(http.getRequests.map(\.url.absoluteString) == [widgetAPI])
            #expect(http.downloadCount == 0)
            #expect(try configBytes(paths) == before)
            expectLockFree(paths)
        }
    }

    @Test("the plan is the one `source add` previews: same confirm value for the same source")
    func sameCore() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await withSourceHome(config: menuConfig(), http: http) { _, services in
            let source = try #require(
                plan(await MenuSourceAdd.preview(services, url: sourceIndexURL)))
            let cli = await run(argv: ["source"] + addArgs(sourceIndexURL), services: services)
            #expect(cli.data["confirm"] == .string(source.confirm))
            #expect(http.getRequests.count == 2)
        }
    }

    @Test("an index of several apps goes to the picker; a pick makes the plan with no second GET")
    func picker() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON(manyApps)])
        try await withSourceHome(config: menuConfig(), http: http) { paths, services in
            let before = try configBytes(paths)
            guard
                case .choose(let choices) = await MenuSourceAdd.preview(
                    services, url: sourceIndexURL)
            else {
                Issue.record("expected the picker")
                return
            }
            #expect(choices.choices.count == 3 && !choices.truncated)
            #expect(choices.choices[0].title == "One · 1.2.0 · io.example.one")
            #expect(choices.choices[0].blocked == nil && choices.choices[2].blocked != nil)
            #expect(http.getRequests.count == 1)

            let step = MenuSourceAdd.choose(choices, choices.choices[1], services: services)
            let source = try #require(plan(step), "\(step)")
            #expect(source.appId == "two" && source.plan.bundleId == "io.example.two")
            #expect(http.getRequests.count == 1, "the pick reads no more than the config")
            #expect(try configBytes(paths) == before)

            // An app without a digest is not addable even if it is picked.
            let bad = MenuSourceAdd.choose(choices, choices.choices[2], services: services)
            #expect(failure(bad)?.code == "UPSTREAM_DIGEST_MISSING")
        }
    }

    @Test("a long index is cut to 50 apps and says so")
    func truncated() async throws {
        let many = (0..<60).map { IndexEntry(name: "App \($0)", bundleId: "io.example.app\($0)") }
        let http = SourceHTTP([sourceIndexURL: indexJSON(many)])
        try await withSourceHome(config: menuConfig(), http: http) { _, services in
            guard
                case .choose(let choices) = await MenuSourceAdd.preview(
                    services, url: sourceIndexURL)
            else {
                Issue.record("expected the picker")
                return
            }
            #expect(choices.choices.count == 50 && choices.truncated)
            #expect(MenuSourceAdd.truncatedNote.contains("50"))
        }
    }

    @Test("refusals come back as an issue with source add's code, and write nothing")
    func failures() async throws {
        let http = SourceHTTP([
            "https://example.org/page": Data("<html></html>".utf8),
            sourceIndexURL: indexJSON([IndexEntry()]),
        ])
        try await withSourceHome(config: menuConfig(), http: http) { paths, services in
            let before = try configBytes(paths)
            let unknown = await MenuSourceAdd.preview(services, url: "https://example.org/page")
            #expect(failure(unknown)?.code == "SOURCE_KIND_UNKNOWN")
            let refused = await MenuSourceAdd.preview(services, url: "http://example.org/i.json")
            #expect(failure(refused)?.code == "SOURCE_NOT_ALLOWED")
            #expect(http.getRequests.count == 1, "the refused address made no request")
            let missing = await MenuSourceAdd.preview(services, url: "https://example.org/none")
            #expect(failure(missing)?.code == "FETCH_HTTP_ERROR")
            #expect(try configBytes(paths) == before)
        }
        // The app the source would add may not exist already.
        let taken = menuConfig()
        let exists = SourceHTTP([widgetAPI: widgetRelease()])
        var config = taken
        config.extra["customApps"] = [["id": "widget", "platform": "ios"]]
        config.extra["customSources"] = [.object(githubEntry.merging(["app": "widget"]) { $1 })]
        try await withSourceHome(config: config, http: exists) { _, services in
            #expect(
                failure(await MenuSourceAdd.preview(services, url: widgetURL))?.code
                    == "SOURCE_EXISTS")
        }
        try await withSourceHome(config: menuConfig(prefix: nil), http: exists) { _, services in
            #expect(
                failure(await MenuSourceAdd.preview(services, url: widgetURL))?.code
                    == "CONFIG_MISSING")
        }
    }
}

@Suite("menu add source: the confirm and the run")
struct MenuAddSourceRunTests {
    private func world(
        config: Config = menuConfig(), http: SourceHTTP, url: String = widgetURL,
        _ body: (Paths, Services, MenuSourcePlan) async throws -> Void
    ) async throws {
        try await withSourceHome(config: config, http: http) { paths, services in
            let step = await MenuSourceAdd.preview(services, url: url)
            try await body(paths, services, try #require(plan(step), "\(step)"))
        }
    }

    private func perform(
        _ source: MenuSourcePlan, services: Services, steps: MenuActionSteps = MenuActionSteps(),
        cancelled: Bool = false
    ) async -> MenuActionOutcome? {
        let outcome = Mutex<MenuActionOutcome?>(nil)
        await MenuActionRunner.perform(
            .addSource(source), services: services, steps: steps, isCancelled: { cancelled }
        ) { result in
            outcome.withLock { $0 = result }
        }
        return outcome.withLock { $0 }
    }

    @Test(
        "the card shows the address, every host, the upstream bundle ID and version, the app, its platform and the warning"
    )
    func prompt() async throws {
        let entry = IndexEntry(
            url: "https://github.com/acme/widget/releases/download/v1/W.ipa", platform: "tvos")
        let http = SourceHTTP([sourceIndexURL: indexJSON([entry])])
        try await world(http: http, url: sourceIndexURL) { _, _, source in
            let snapshot = menuBuild()
            let shown = try #require(
                MenuActions.prompt(for: .addSource(source), in: snapshot, now: testNow))
            let text = shown.lines.joined(separator: "\n")
            #expect(shown.title == "Add a source for Widget" && shown.confirmLabel == "Add source")
            #expect(shown.destructive == false && shown.apps.isEmpty)
            #expect(shown.lines.first == MenuSourceAdd.thirdPartyWarning)
            #expect(text.contains("Address \(sourceIndexURL)"))
            #expect(text.contains("Metadata from index.example.org"))
            for host in [
                "github.com", "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
            ] {
                #expect(text.contains(host))
            }
            #expect(text.contains("Upstream app io.example.widget · latest 1.2.0"))
            #expect(text.contains("Adds the app widget for tvOS, shown as Widget"))
            #expect(text.contains("Bundle ID \(menuPrefix).free.widget"))
            #expect(text.contains("Nothing is downloaded"))
            #expect(shown.monospacedLines == [1] && shown.lines[1].hasPrefix("Address"))
            // The same source gives the same card, so a click can be checked against what was shown.
            #expect(
                MenuActions.reconfirm(.addSource(source), shown: shown, in: snapshot, now: testNow)
                    == .run(shown))
        }
    }

    @Test("a GitHub source says its bundle ID is read at the first fetch; attaching says so")
    func githubAndAttach() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { _, _, source in
            let shown = try #require(
                MenuActions.prompt(for: .addSource(source), in: menuBuild(), now: testNow))
            let text = shown.lines.joined(separator: "\n")
            #expect(text.contains("Latest release 0.3.8 · its bundle ID is read from the IPA"))
            #expect(text.contains("Metadata from api.github.com"))
        }
        var config = menuConfig()
        config.extra["customApps"] = [["id": "widget", "platform": "ios"]]
        try await world(config: config, http: http) { _, _, source in
            let shown = try #require(
                MenuActions.prompt(for: .addSource(source), in: menuBuild(), now: testNow))
            #expect(
                shown.lines.joined(separator: "\n").contains(
                    "Gives the existing app widget (iOS) this source"))
        }
    }

    @Test(
        "it is a config action with no device: available on first run too, no cancel of loads, a printed action carries no address"
    )
    func availability() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { _, _, source in
            let action = MenuAction.addSource(source)
            #expect(MenuActions.availability(action, in: menuBuild(), now: testNow).isEnabled)
            #expect(
                MenuActions.availability(action, in: .firstRun(now: testNow), now: testNow)
                    .isEnabled)
            #expect(action.device.isEmpty && action.leavesDeviceReadAlone && !action.isFetchStage)
            #expect(MenuActions.cancellable(action))
            #expect("\(action)".contains(widgetURL) == false)
            #expect("\(action)".contains("addSource"))
        }
    }

    @Test(
        "the confirm click is source add --yes with the preview's confirm value and every choice spelled out"
    )
    func options() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await world(http: http, url: sourceIndexURL) { _, services, source in
            let seen = Mutex<SourceOptions?>(nil)
            var steps = MenuActionSteps()
            steps.addSource = { _, options in
                seen.withLock { $0 = options }
                return Envelope(ok: true, command: "source add")
            }
            _ = await perform(source, services: services, steps: steps)
            #expect(
                seen.withLock { $0 }
                    == SourceOptions(
                        sub: "add", url: sourceIndexURL, app: "widget", bundle: "io.example.widget",
                        platform: "ios", name: "Widget", confirm: source.confirm, yes: true))
        }
    }

    @Test("the real run writes the three entries and the result points at Add app…")
    func writes() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { paths, services, source in
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .done && outcome.headline == "Added the source for Widget")
            #expect(outcome.notes == [MenuSourceAdd.addedNote] && outcome.lines.isEmpty)
            let config = try loadConfig(paths)
            #expect(config.extra["customApps"] == [["id": "widget", "platform": "ios"]])
            #expect(config.extra["customSources"]?.array?.count == 1)
            #expect(config.approvedSources.last == ["app": "widget"])
            #expect(http.downloadCount == 0)
            expectLockFree(paths)

            // The new app is what Add app… offers.
            let snapshot = menuBuild(config: config)
            let offered = snapshot.addSources.first { $0.app == "widget" }
            #expect(offered?.thirdParty == true && offered?.platform == "ios")
        }
    }

    @Test(
        "a source that changed since the preview ends as SOURCE_CHANGED, with no retry, and writes nothing"
    )
    func changed() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await world(http: http, url: sourceIndexURL) { paths, services, source in
            http.set(
                sourceIndexURL, indexJSON([IndexEntry(url: "https://evil.example.net/Widget.ipa")]))
            let before = try configBytes(paths)
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .failed)
            #expect(outcome.headline == "The source changed since you reviewed it")
            #expect(outcome.issues.first?.code == "SOURCE_CHANGED")
            #expect(outcome.notes == [MenuSourceAdd.changedNote] && outcome.lines.isEmpty)
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("only the version moving is the same source")
    func newVersion() async throws {
        let http = SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])])
        try await world(http: http, url: sourceIndexURL) { _, services, source in
            http.set(sourceIndexURL, indexJSON([IndexEntry(version: "9.9.9")]))
            #expect(await perform(source, services: services)?.kind == .done)
        }
    }

    @Test("the app taken since the preview is a failed result with the command's code")
    func taken() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { paths, services, source in
            try await ConfigStore(paths: paths).update {
                $0.extra["customApps"] = [["id": "other", "suffix": "widget", "platform": "ios"]]
            }
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .failed && outcome.headline == "Source not added")
            #expect(outcome.issues.first?.code == "APP_EXISTS")
        }
    }

    @Test("a busy lock is the busy result with a retry through the confirm; the GET came first")
    func busy() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { paths, services, source in
            let before = try configBytes(paths)
            let held = try OperationLock.acquire(paths: paths)
            defer { held.release() }
            let outcome = try #require(await perform(source, services: services))
            #expect(outcome.kind == .busy && outcome.headline == MenuActionOutcome.busyHeadline)
            #expect(outcome.lines.first?.retry == .addSource(source))
            #expect(try configBytes(paths) == before)
        }
    }

    @Test("Cancel that stops the command before it wrote reads as cancelled")
    func cancelled() async throws {
        let http = SourceHTTP([widgetAPI: widgetRelease()])
        try await world(http: http) { paths, services, source in
            http.fail(with: CancellationError())
            let before = try configBytes(paths)
            let outcome = try #require(
                await perform(source, services: services, cancelled: true))
            #expect(outcome.kind == .cancelled && outcome.headline == "Cancelled")
            #expect(outcome.notes == ["Nothing was added."])
            #expect(try configBytes(paths) == before)
        }
    }
}

@MainActor
@Suite("menu add source: view model")
struct MenuAddSourceModelTests {
    private struct World {
        let model: MenuModel
        let http: SourceHTTP
        let dir: URL
    }

    private func world(config: Config?, http: SourceHTTP) async throws -> World {
        let dir = try makeTempDir()
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        if let config { try await seed(paths, config: config, ledger: Ledger()) }
        let runner = SlowDeviceRunner(
            menuDeviceScript(
                devices: deviceListJSON(phoneEntryJSON(seed: "1")), apps: { _ in .apps([]) }))
        let services = Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: MutableClock(testNow),
            keychain: FakeKeychain(), home: paths, http: http)
        let model = MenuModel(services: services)
        model.reload(force: true)
        await model.loadTask?.value
        return World(model: model, http: http, dir: dir)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for a condition")
    }

    private func picker(_ model: MenuModel) -> MenuSourcePicker? {
        if case .addingSource(let picker) = model.actionState { return picker }
        return nil
    }

    private func confirming(_ model: MenuModel) -> (MenuAction, MenuPrompt)? {
        if case .confirming(let action, let prompt) = model.actionState { return (action, prompt) }
        return nil
    }

    @Test(
        "input, preview, confirm, run: the source is written and the new app is on Add app… afterwards"
    )
    func flow() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([widgetAPI: widgetRelease()]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(w.model.canAddSource)

        w.model.openAddSource()
        #expect(picker(w.model) == .entering(url: "", problem: nil) && !w.model.controlsEnabled)
        #expect(!w.model.canAddSource && w.http.getRequests.isEmpty)

        w.model.previewSource(url: "  \(widgetURL) ")
        #expect(picker(w.model) == .looking(url: widgetURL))
        try await until { confirming(w.model) != nil }
        let (action, prompt) = try #require(confirming(w.model))
        #expect(prompt.confirmLabel == "Add source" && prompt.title == "Add a source for Widget")
        guard case .addSource(let source) = action else {
            Issue.record("expected addSource, got \(action)")
            return
        }
        #expect(w.http.getRequests.count == 1 && w.http.downloadCount == 0)
        // Nothing is written before the click.
        #expect(try w.model.services.store.load().extra["customSources"] == nil)

        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected a result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.kind == .done && outcome.headline == "Added the source for Widget")
        #expect(w.http.getRequests.count == 2, "the click repeated the read")
        #expect(try w.model.services.store.load().extra["customSources"]?.array?.count == 1)
        #expect(source.confirm.count == 16)

        // The panel redraws from the config at once (no device read) and Add app… knows the app.
        try await until {
            if case .loaded(let snapshot) = w.model.panel {
                return snapshot.addSources.contains { $0.app == "widget" }
            }
            return false
        }
        #expect(w.model.controlsEnabled)
    }

    @Test("an index of several apps asks which; the pick opens the confirm")
    func choosing() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([sourceIndexURL: indexJSON(manyApps)]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddSource()
        w.model.previewSource(url: sourceIndexURL)
        try await until {
            if case .choosing = picker(w.model) { return true }
            return false
        }
        guard case .choosing(let choices) = picker(w.model) else { return }
        #expect(choices.choices.count == 3 && w.http.getRequests.count == 1)
        w.model.chooseSource(choices, choices.choices[0])
        let (action, _) = try #require(confirming(w.model))
        #expect(action.device.isEmpty)
        guard case .addSource(let source) = action else { return }
        #expect(source.appId == "one" && w.http.getRequests.count == 1)
    }

    @Test("a refused address returns to the field with the address kept and the code shown")
    func refused() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP(["https://example.org/page": Data("x".utf8)]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddSource()
        w.model.previewSource(url: "https://example.org/page")
        try await until {
            if case .entering = picker(w.model) { return true }
            return false
        }
        guard case .entering(let url, let problem) = picker(w.model) else { return }
        #expect(url == "https://example.org/page" && problem?.code == "SOURCE_KIND_UNKNOWN")
        // A bad address never leaves the field.
        w.model.previewSource(url: "http://example.org/x")
        #expect(w.http.getRequests.count == 1)
        w.model.dismiss()
        #expect(w.model.actionState == .idle && w.model.controlsEnabled)
    }

    @Test("Cancel while the source is read closes the card, and the late answer does not reopen it")
    func cancelWhileReading() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([widgetAPI: widgetRelease()]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.http.hold(true)
        w.model.openAddSource()
        w.model.previewSource(url: widgetURL)
        try await until { !w.http.getRequests.isEmpty }
        w.model.dismiss()
        #expect(w.model.actionState == .idle && w.model.controlsEnabled)
        w.http.hold(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(w.model.actionState == .idle)
    }

    @Test("Cancel at the confirm writes nothing")
    func cancelAtConfirm() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([widgetAPI: widgetRelease()]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddSource()
        w.model.previewSource(url: widgetURL)
        try await until { confirming(w.model) != nil }
        let before = try Data(contentsOf: URL(fileURLWithPath: w.model.services.home.config))
        w.model.dismiss()
        #expect(w.model.actionState == .idle)
        #expect(try Data(contentsOf: URL(fileURLWithPath: w.model.services.home.config)) == before)
        #expect(w.http.getRequests.count == 1)
    }

    @Test(
        "the busy gate: no Add source… while a card is open or an action runs, and the click is ignored then"
    )
    func busyGate() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([widgetAPI: widgetRelease()]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddSource()
        w.model.openAddSource()  // already open: no second card
        #expect(picker(w.model) == .entering(url: "", problem: nil))
        w.model.dismiss()
        w.model.openAddDevice()
        #expect(!w.model.canAddSource)
        w.model.openAddSource()
        #expect(
            { if case .addingDevice = w.model.actionState { return true } else { return false } }())
        w.model.dismiss()

        w.model.openAddSource()
        w.model.previewSource(url: widgetURL)
        try await until { confirming(w.model) != nil }
        #expect(!w.model.canAddSource)
        w.model.confirm()
        #expect(w.model.actionBusy)
        // A running action takes no new card and no new preview.
        w.model.openAddSource()
        w.model.previewSource(url: widgetURL)
        #expect(!w.model.canAddSource)
        try await until { !w.model.actionBusy }
        #expect(w.model.canAddSource, "a finished result is replaced by the next action")
    }

    @Test(
        "a changed source is SOURCE_CHANGED in the result, and the model offers no retry of the stale confirm"
    )
    func changedResult() async throws {
        let w = try await world(
            config: menuConfig(), http: SourceHTTP([sourceIndexURL: indexJSON([IndexEntry()])]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        w.model.openAddSource()
        w.model.previewSource(url: sourceIndexURL)
        try await until { confirming(w.model) != nil }
        w.http.set(
            sourceIndexURL, indexJSON([IndexEntry(url: "https://evil.example.net/Widget.ipa")]))
        w.model.confirm()
        try await until { !w.model.actionBusy }
        guard case .finished(let outcome) = w.model.actionState else {
            Issue.record("expected a result, got \(w.model.actionState)")
            return
        }
        #expect(outcome.headline == "The source changed since you reviewed it")
        #expect(outcome.issues.first?.code == "SOURCE_CHANGED" && outcome.lines.isEmpty)
        #expect(try w.model.services.store.load().extra["customSources"] == nil)
    }

    @Test(
        "first run has no bundleIdPrefix yet, so the preview says CONFIG_MISSING and nothing is written"
    )
    func firstRun() async throws {
        let w = try await world(config: nil, http: SourceHTTP([widgetAPI: widgetRelease()]))
        defer { try? FileManager.default.removeItem(at: w.dir) }
        #expect(w.model.canAddSource)
        w.model.openAddSource()
        w.model.previewSource(url: widgetURL)
        try await until {
            if case .entering(_, let problem) = picker(w.model) { return problem != nil }
            return false
        }
        guard case .entering(_, let problem) = picker(w.model) else { return }
        #expect(problem?.code == "CONFIG_MISSING")
        #expect(FileManager.default.fileExists(atPath: w.model.services.home.config) == false)
    }

    @Test("a config that does not parse has no Add source")
    func failedPanel() async throws {
        let w = try await world(config: nil, http: SourceHTTP())
        defer { try? FileManager.default.removeItem(at: w.dir) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: w.model.services.home.config))
        w.model.reload(force: true)
        await w.model.loadTask?.value
        #expect(!w.model.canAddSource)
        w.model.openAddSource()
        #expect(w.model.actionState == .idle)
    }
}
