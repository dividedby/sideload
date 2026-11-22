import Foundation

// Remove source (design section 12): the owner picks one of the sources they added, the panel reads what `source remove` would
// remove and what stays (the same local, read-only preview the command prints), and the confirm click is the owner's
// `source remove --yes`. Built-in sources are not listed and the command refuses them. Pure, apart from `list`, `preview` and
// `stop`, which read local files through `Services`. Nothing here writes: the write is `MenuAction.removeSource`, run by
// `MenuActionRunner` through `SourceCommand`. There is no edit: changing a source is Remove source then Add source.

/// A source the owner is reviewing for removal: what the confirm shows. The click removes the app's entries by app ID.
public struct MenuSourceRemoval: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let preview: SourceRemovePreview
    /// The app's display name, or its ID when the `customApps` entry is gone or ignored.
    public var name: String

    public var appId: String { preview.app }

    // A printed action carries no address.
    public var description: String { "source removal for \(preview.app)" }
    public var debugDescription: String { description }
}

/// One source the picker lists.
public struct MenuRemovableSource: Sendable, Hashable, Identifiable {
    public var id: String { app }
    public var app: String
    /// "Widget · widget".
    public var title: String
    /// "AltStore index · apps.example.com".
    public var detail: String
}

/// The Remove source card before the confirm.
public enum MenuSourceRemovePicker: Sendable, Equatable {
    /// The owner's sources; empty when there are none. `problem` is why the last pick stopped.
    case choosing([MenuRemovableSource], problem: MenuIssue?)
    /// The config could not be read.
    case failed(MenuIssue)
}

/// What a pick led to.
public enum MenuSourceRemoveStep: Sendable, Equatable {
    case confirm(MenuSourceRemoval)
    case failed(MenuIssue)
}

public enum MenuSourceRemove {
    /// The words the views draw, here so they can be tested.
    public static let entryLabel = "Remove source…"
    public static let entryHelp = "Remove a download source you added"
    public static let cardTitle = "Remove source"
    public static let pickerIntro =
        "Pick the source to remove. The app, its downloaded builds and its installs stay; to change a source, remove it and add it again."
    public static let noneAdded =
        "There is no source to remove: only a source added with Add source… or `sideload source add` can be removed. Built-in sources are part of sideload."
    public static let confirmLabel = "Remove source"
    static let removedNote =
        "The app, its downloaded builds and its installs stay, and Renew keeps working. Add app… and updates no longer offer it; Add source… adds it again."
    static let changedNote = "Nothing was removed. Choose Remove source… again to review it."
    static let changedReason =
        "The source changed since you reviewed it. Nothing was removed. Choose Remove source… again to review it."

    // MARK: reading

    /// The owner's sources, from `config.json` only: no network, no lock, no write.
    public static func list(_ services: Services) -> MenuSourceRemovePicker {
        do {
            let config = try services.store.load()
            let registry = config.appRegistry
            let listed = try SourceRemove.removable(config).map { source in
                MenuRemovableSource(
                    app: source.app, title: "\(name(source.app, registry)) · \(source.app)",
                    detail: [kindLabel(source.kind), host(source.source)].compactMap { $0 }
                        .joined(separator: " · "))
            }
            return .choosing(listed, problem: nil)
        } catch {
            return .failed(MenuIssue(error))
        }
    }

    /// The pick's preview: what `source remove --app` without `--yes` reports. Reads local files only.
    public static func preview(_ services: Services, app: String) -> MenuSourceRemoveStep {
        do {
            let preview = try SourceRemove.preview(services, app: app)
            let registry = try services.store.load().appRegistry
            return .confirm(MenuSourceRemoval(preview: preview, name: name(app, registry)))
        } catch {
            return .failed(MenuIssue(error))
        }
    }

    /// Checked again just before the click runs: nil when the preview is still what the owner saw, else why nothing runs (the
    /// source was removed, or changed, meanwhile).
    static func stop(_ removal: MenuSourceRemoval, services: Services) -> String? {
        guard case .confirm(let now) = preview(services, app: removal.appId),
            now.preview.app == removal.preview.app, now.preview.kind == removal.preview.kind,
            now.preview.source == removal.preview.source,
            now.preview.sourceEntries == removal.preview.sourceEntries,
            now.preview.approvalEntries == removal.preview.approvalEntries
        else { return changedReason }
        return nil
    }

    private static func name(_ app: String, _ registry: AppRegistry) -> String {
        registry.app(app).map { printableCut($0.displayName) } ?? app
    }

    private static func kindLabel(_ kind: String) -> String? {
        switch kind {
        case "altstoreIndex": "AltStore index"
        case "githubRelease": "GitHub release"
        case "": nil
        default: kind
        }
    }

    private static func host(_ address: String) -> String? {
        URL(string: address)?.host() ?? (address.isEmpty ? nil : address)
    }

    // MARK: the confirm and the run

    /// The inline confirm: the address, what is removed from `config.json` and what stays.
    static func prompt(_ removal: MenuSourceRemoval) -> MenuPrompt {
        let p = removal.preview
        var lines: [String] = []
        lines.append(p.source.isEmpty ? "No address recorded" : "Address \(p.source)")
        if let kind = kindLabel(p.kind) { lines.append("Kind \(kind)") }
        lines.append(
            "Removes \(count(p.sourceEntries, "customSources entry", "customSources entries")) and \(count(p.approvalEntries, "approvedSources entry", "approvedSources entries")) from config.json"
        )
        var stays: [String] = []
        if p.customApp { stays.append("the app \(p.app)") }
        if let builds = p.manifestEntries, builds > 0 {
            stays.append(count(builds, "downloaded build", "downloaded builds"))
        }
        if let installs = p.installs, installs > 0 {
            stays.append(count(installs, "install", "installs"))
        }
        if !stays.isEmpty {
            lines.append("Stays: \(stays.joined(separator: ", ")). Renew keeps working.")
        }
        lines.append(
            "Add app… and updates no longer offer \(removal.name). Nothing is uninstalled or deleted."
        )
        return MenuPrompt(
            title: "Remove the source for \(removal.name)?", lines: lines,
            confirmLabel: confirmLabel, destructive: true, runningLabel: "Removing the source…",
            apps: [], monospacedLines: p.source.isEmpty ? [] : [0])
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// What the click runs: `source remove --app <id> --yes`.
    static func options(_ removal: MenuSourceRemoval) -> SourceOptions {
        SourceOptions(sub: "remove", app: removal.appId, yes: true)
    }
}
