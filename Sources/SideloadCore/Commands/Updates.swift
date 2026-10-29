import Foundation

public struct UpdatesOptions: Sendable, Equatable {
    public var app: String?
    /// Skip the 6 h / 1 h waits (the 5-minute floor and a server's rate limit still hold).
    public var force: Bool

    public init(app: String? = nil, force: Bool = false) {
        self.app = app
        self.force = force
    }
}

/// `updates [--app <a>] [--force]` (design section 8): what each approved source offers now, against what is installed on the
/// saved devices. Read-only: one metadata GET per source through `Services.http` (cadence in `UpdateCadence`), the answer kept
/// in `updates.json`, and nothing else; no `.op.lock`, no device, no subprocess, no download of an IPA. It is safe for an
/// agent to run. A newer version is only a fact about upstream: getting it is still `fetch`, the owner's `--approve`, `sign`
/// and `install`.
public enum UpdatesCommand {
    static let command = "updates"

    public static func run(_ services: Services, _ options: UpdatesOptions) async -> Envelope {
        do {
            return envelope(try await UpdateCheck.run(services, app: options.app, force: options.force))
        } catch {
            return .from(error, command: command)
        }
    }

    private static func envelope(_ report: UpdateCheck.Report) -> Envelope {
        let stamp = ISO8601DateFormatter()
        let date: (Date?) -> JSONValue = { $0.map { .string(stamp.string(from: $0)) } ?? .null }
        let sources = report.sources.map { source -> JSONValue in
            var object: [String: JSONValue] = [
                "app": .string(source.app), "status": .string(source.status.rawValue), "checkedAt": date(source.checkedAt),
                "fromCache": .bool(source.fromCache), "upstream": upstream(source.upstream),
            ]
            if let code = source.failure?.code { object["code"] = .string(code) }
            return .object(object)
        }
        let installs = report.installs.map { install -> JSONValue in
            .object([
                "device": .string(install.device), "app": .string(install.app), "installed": .string(install.installed),
                "state": .string(install.state.rawValue),
            ])
        }
        let failed = report.sources.filter { $0.status == .error }
        let data: [String: JSONValue] = [
            "checkedAt": date(report.checkedAt), "sources": .array(sources), "installs": .array(installs),
            "warnings": .array(report.warnings),
        ]
        return Envelope(
            ok: failed.isEmpty, command: command, data: data,
            errors: failed.compactMap { source in
                source.failure.map { .init(code: $0.code, message: "\(source.app): \($0.message)", fix: $0.fix) }
            })
    }

    private static func upstream(_ value: UpdateUpstream?) -> JSONValue {
        guard let value else { return .null }
        return .object([
            "version": .string(value.version), "build": value.build.map(JSONValue.string) ?? .null,
            "minOS": value.minOS.map(JSONValue.string) ?? .null, "size": .number(Double(value.size)),
            "sha256": .string(value.sha256),
        ])
    }
}
