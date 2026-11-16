import Foundation

public struct SourceOptions: Sendable, Equatable {
    public var sub: String?

    public init(sub: String? = nil) {
        self.sub = sub
    }
}

/// `source list` (design section 8, custom sources): every source `fetch` knows, built-in and custom, with the metadata URL, the
/// exact hosts and whether the owner approved it in `approvedSources`. Read-only and offline: no network, no `.op.lock`, no
/// write, no device; it is safe for an agent to run. A `customSources` entry that was left out is a `CUSTOM_SOURCE_IGNORED`
/// warning. Adding a source is by hand in `config.json` for now (issue #47).
public enum SourceCommand {
    static let command = "source"

    public static func run(_ services: Services, _ options: SourceOptions) -> Envelope {
        guard options.sub == "list" else {
            return .fail(
                command, code: "USAGE", message: "source needs the subcommand `list`.",
                fix: "Run `sideload source list`.")
        }
        do {
            return .result("source list", try list(services))
        } catch {
            return .from(error, command: "source list")
        }
    }

    private static func list(_ services: Services) throws -> [String: JSONValue] {
        let config = try services.store.load()
        let registry = config.appRegistry
        let sources = registry.fetchSources.map { declared -> JSONValue in
            // The approved source carries the hosts as `approvedSources` narrowed them: what a fetch may actually use.
            let approved = try? FetchCatalog.approved(app: declared.app, config: config)
            let source = approved ?? declared
            let builtIn = registry.app(declared.app)?.builtIn ?? false
            return .object([
                "app": .string(source.app), "builtIn": .bool(builtIn),
                "kind": .string(source.kind.configKind),
                "url": .string(source.metadataURL.absoluteString),
                "metadataHosts": .array(source.metadataHosts.sorted().map(JSONValue.string)),
                "downloadHosts": .array(source.downloadHosts.sorted().map(JSONValue.string)),
                "approved": .bool(approved != nil),
            ])
        }
        return ["sources": .array(sources), "warnings": .array(registry.warnings)]
    }
}
