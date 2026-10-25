import Foundation

public struct PortalOptions: Sendable, Equatable {
    /// One list, or nil for all four.
    public var resource: PortalResource?
    /// Print non-prefix App ID identifiers in full (never the App ID `name`).
    public var showIdentifiers: Bool

    public init(resource: PortalResource? = nil, showIdentifiers: Bool = false) {
        self.resource = resource
        self.showIdentifiers = showIdentifiers
    }
}

/// `portal`: a read-only audit of the paid team's developer portal (certificates, App IDs, devices, profiles)
/// through the App Store Connect API. Every request is a `GET`; there is no confirmation and no operation lock
/// because nothing on the portal or the device changes and no subprocess runs. It needs the owner's API key in
/// `$SIDELOAD_HOME/asc/`.
public enum PortalCommand {
    static let command = "portal"

    public static func run(_ services: Services, _ options: PortalOptions = PortalOptions()) async -> Envelope {
        do {
            return try await execute(services, options)
        } catch {
            return .from(error, command: command)
        }
    }

    private static func execute(_ services: Services, _ options: PortalOptions) async throws -> Envelope {
        let credentials = try ASCCredentials.load(services.home)
        let config = try services.store.load()
        let token = try ASCToken.make(credentials, now: services.clock.now())

        let client = PortalClient(
            transport: services.http, token: token, clock: services.clock, sleep: services.sleep, log: services.log)
        let requested = options.resource.map { [$0] } ?? PortalResource.allCases
        var results: [PortalResource: Result<PortalListing, SideloadError>] = [:]
        // One list at a time: gentle on the API's rate limit.
        for resource in requested {
            do {
                results[resource] = .success(try await client.list(resource))
            } catch let error as SideloadError {
                // A cancelled run ends here; it is not one more failed list.
                if error.code == "CANCELLED" { throw error }
                results[resource] = .failure(error)
            } catch {
                results[resource] = .failure(PortalClient.network(resource, nil))
            }
        }

        let configPresent = try pathExists(services.home.config)
        let saved = Set(config.devices.values.compactMap { $0.udid?.lowercased() })
        let keychain = services.keychain
        return PortalReport.build(
            PortalReportInput(
                requested: requested, results: results, role: credentials.role,
                keyIdTail: String(credentials.keyId.suffix(4)), bundleIdPrefix: config.bundleIdPrefix,
                savedUDIDs: configPresent ? saved : nil,
                keychainReferences: {
                    (try? keychain.developmentIdentities()).map { Set($0.map { $0.reference.uppercased() }) }
                },
                now: services.clock.now(), showIdentifiers: options.showIdentifiers))
    }
}
