import Foundation

public struct SourceOptions: Sendable, Equatable {
    public var sub: String?
    public var url: String?
    public var app: String?
    public var yes: Bool

    public init(sub: String? = nil, url: String? = nil, app: String? = nil, yes: Bool = false) {
        self.sub = sub
        self.url = url
        self.app = app
        self.yes = yes
    }
}

/// `source list` (design section 8, custom sources): every source `fetch` knows, built-in and custom, with the metadata URL, the
/// exact hosts and whether the owner approved it in `approvedSources`. Read-only and offline: no network, no `.op.lock`, no
/// write, no device; it is safe for an agent to run. A `customSources` entry that was left out is a `CUSTOM_SOURCE_IGNORED`
/// warning. `source add` and `source remove` are not built yet (issue #47, PR B); today the owner adds an entry by hand.
public enum SourceCommand {
    static let command = "source"

    public static func run(_ services: Services, _ options: SourceOptions) -> Envelope {
        switch options.sub {
        case "list":
            if options.url != nil || options.app != nil || options.yes {
                return .fail(
                    "source list", code: "USAGE", message: "source list takes no options.",
                    fix: "Run `sideload source list` with no options.")
            }
            do {
                return .result("source list", try list(services))
            } catch {
                return .from(error, command: "source list")
            }
        case "add", "remove":
            return .fail(
                "source \(options.sub ?? "")", code: "NOT_IMPLEMENTED",
                message: "\"source \(options.sub ?? "")\" is not built yet.",
                fix: "Not built yet; see docs/design.md section 8. `sideload source list` is built."
            )
        default:
            return .fail(
                command, code: "USAGE", message: "source needs a subcommand.",
                fix: "Run `sideload source list`.")
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
                "kind": .string(kindName(source.kind)),
                "url": .string(source.metadataURL.absoluteString),
                "metadataHosts": .array(source.metadataHosts.sorted().map(JSONValue.string)),
                "downloadHosts": .array(source.downloadHosts.sorted().map(JSONValue.string)),
                "approved": .bool(approved != nil),
            ])
        }
        return ["sources": .array(sources), "warnings": .array(registry.warnings)]
    }

    private static func kindName(_ kind: FetchSource.Kind) -> String {
        switch kind {
        case .githubRelease, .customGithubRelease: "githubRelease"
        case .altstoreIndex, .customAltstoreIndex: "altstoreIndex"
        }
    }
}
