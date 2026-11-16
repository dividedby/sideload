import Foundation

// Add source (design section 12): the owner types an address, the panel reads it once (the same read-only preview `source add`
// prints), an index of several apps asks which one, and the confirm card shows what would be written. The confirm click is the
// owner's `source add --yes` with the preview's confirm value, so a source that changed in between ends as `SOURCE_CHANGED`.
// Pure, apart from `preview` and `choose`, which read through `Services`. Nothing here downloads an IPA or writes: the write is
// `MenuAction.addSource`, run by `MenuActionRunner` through `SourceCommand`.

/// A source the owner is reviewing: what the confirm shows and exactly what the click writes.
public struct MenuSourcePlan: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let plan: SourcePlan

    /// The app's display name ("Widget").
    public var name: String { plan.name }
    public var appId: String { plan.appId }
    /// The confirm value the preview computed and the click passes back.
    public var confirm: String { plan.confirm }

    // A printed action carries no address.
    public var description: String { "source for \(plan.appId)" }
    public var debugDescription: String { description }
}

/// One app of an index, as the picker lists it.
public struct MenuSourceChoice: Sendable, Hashable, Identifiable {
    public var id: Int
    /// "Widget · 1.2.0 · io.example.widget", upstream strings cut to printable ASCII.
    public var title: String
    var bundleId: String
    /// Why it cannot be added (no SHA-256); nil when it can.
    public var blocked: String?
}

/// An index that lists several apps: the one read of it, held so a pick needs no second request.
public struct MenuSourceChoices: Sendable, Equatable {
    public var url: String
    public var choices: [MenuSourceChoice]
    /// The index lists more apps than the picker shows.
    public var truncated: Bool
    let probe: SourceProbe
}

/// The Add source card before the confirm.
public enum MenuSourcePicker: Sendable, Equatable {
    /// The address field. `problem` is why the last read stopped (the field keeps the address).
    case entering(url: String, problem: MenuIssue?)
    case looking(url: String)
    case choosing(MenuSourceChoices)
}

/// What one read of an address led to.
public enum MenuSourceStep: Sendable, Equatable {
    case confirm(MenuSourcePlan)
    case choose(MenuSourceChoices)
    case failed(MenuIssue)
}

public enum MenuSourceAdd {
    public static let truncatedNote =
        "Only the first \(SourceAdd.maxListed) apps are listed. To add another, use `sideload source add --bundle` in a terminal."
    public static let thirdPartyWarning =
        "Third-party source: sideload did not choose it and cannot vouch for it. Add only a source you trust."
    static let addedNote =
        "Nothing was downloaded. Add app… on a device card fetches it, and you approve the version and SHA-256 you see."
    static let changedNote = "Nothing was added. Choose Add source… again to review it."

    public static func trimmedURL(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why this address cannot be read; nil when it can. The rules are `source add`'s (`SourceURL`), checked before any request.
    public static func urlProblem(_ text: String) -> String? {
        let url = trimmedURL(text)
        if url.isEmpty { return "Type the address of a GitHub repository or an AltStore index" }
        if case .failure(let reason) = SourceURL.parseHTTPS(url) {
            return "Not allowed: \(reason.text)"
        }
        return nil
    }

    // MARK: reading

    /// One metadata GET of `url` and the plan it leads to, or the picker's list when an index has several apps. Read-only:
    /// nothing is written, no lock is taken and no IPA is downloaded.
    public static func preview(_ services: Services, url raw: String) async -> MenuSourceStep {
        do {
            let probe = try await SourceAdd.probe(services, url: trimmedURL(raw))
            if case .altstore = probe.kind {
                let listed = try SourceAdd.listing(probe)
                if listed.apps.count > 1 {
                    return .choose(choices(probe, listed))
                }
            }
            return try plan(probe, bundle: nil, services: services)
        } catch {
            return .failed(MenuIssue(error))
        }
    }

    /// The owner's pick out of `choices`; reads only the config.
    public static func choose(
        _ choices: MenuSourceChoices, _ choice: MenuSourceChoice, services: Services
    ) -> MenuSourceStep {
        do {
            return try plan(choices.probe, bundle: choice.bundleId, services: services)
        } catch {
            return .failed(MenuIssue(error))
        }
    }

    private static func plan(_ probe: SourceProbe, bundle: String?, services: Services) throws
        -> MenuSourceStep
    {
        let preview = try SourceAdd.preview(
            probe, request: SourceAddRequest(url: probe.url, bundle: bundle),
            config: try services.store.load())
        return .confirm(MenuSourcePlan(plan: preview.plan))
    }

    private static func choices(
        _ probe: SourceProbe, _ listed: (apps: [SourceCandidate], truncated: Bool)
    ) -> MenuSourceChoices {
        let choices = listed.apps.enumerated().compactMap { index, app -> MenuSourceChoice? in
            guard let bundleId = app.bundleId else { return nil }
            return MenuSourceChoice(
                id: index, title: "\(app.name) · \(app.version) · \(bundleId)", bundleId: bundleId,
                blocked: app.hasDigest ? nil : "It publishes no SHA-256, so it cannot be fetched")
        }
        return MenuSourceChoices(
            url: probe.url, choices: choices, truncated: listed.truncated, probe: probe)
    }

    // MARK: the confirm and the run

    /// The inline confirm: the address, the metadata host, every download host, the upstream bundle ID and version, the app and
    /// its platform, the free bundle ID and the third-party warning.
    static func prompt(_ source: MenuSourcePlan) -> MenuPrompt {
        let plan = source.plan
        let os = AppDefinition.osName(devicePlatform: plan.platform)
        let upstream =
            plan.bundleId.map { "Upstream app \($0) · latest \(plan.version)" }
            ?? "Latest release \(plan.version) · its bundle ID is read from the IPA at the first fetch"
        let app =
            plan.attaches
            ? "Gives the existing app \(plan.appId) (\(os)) this source"
            : "Adds the app \(plan.appId) for \(os), shown as \(plan.name)"
        return MenuPrompt(
            title: "Add a source for \(plan.name)",
            lines: [
                thirdPartyWarning,
                "Address \(plan.url)",
                "Metadata from \(plan.metadataHost)",
                "Downloads from \(plan.downloadHosts.joined(separator: ", "))",
                upstream,
                app,
                "Bundle ID \(plan.freeBundleId)",
                "Saves the source in config.json and approves it. Nothing is downloaded: Add app… fetches it, and you approve each version.",
            ],
            confirmLabel: "Add source", destructive: false, runningLabel: "Adding the source…",
            apps: [], monospacedLines: [1])
    }

    /// What the click runs: `source add --yes` with the preview's confirm value, every choice spelled out as in the command
    /// the preview prints.
    static func options(_ source: MenuSourcePlan) -> SourceOptions {
        let plan = source.plan
        return SourceOptions(
            sub: "add", url: plan.url, app: plan.appId, bundle: plan.bundleId,
            platform: plan.platform, name: plan.attaches ? nil : plan.name, confirm: plan.confirm,
            yes: true)
    }
}
