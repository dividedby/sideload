import Foundation

/// Asks each approved source that has an install on a saved device what its latest release is, and compares that with the
/// installed version (design section 8, `updates`). Read-only toward everything but `updates.json`: no `.op.lock`, no
/// device, no subprocess and never an IPA download. One metadata GET per source, one after the other, through
/// `Services.http`; the cadence in `UpdateCadence` decides whether a source is asked at all.
enum UpdateCheck {
    enum Status: String, Sendable, Equatable {
        case ok, error, skipped
    }

    struct SourceReport: Sendable, Equatable {
        let app: String
        var status: Status
        /// When the values below were read from the source (the last good check, which may be an earlier run).
        var checkedAt: Date?
        /// True when this run made no request for the source: the values come from `updates.json`.
        var fromCache = false
        var upstream: UpdateUpstream?
        var failure: SideloadError?
    }

    struct InstallReport: Sendable, Equatable {
        let device: String
        let app: String
        let installed: String
        let state: VersionOrder.State
    }

    struct Report: Sendable, Equatable {
        var checkedAt: Date
        var sources: [SourceReport] = []
        var installs: [InstallReport] = []
        var warnings: [JSONValue] = []
    }

    static let skippedNotApproved = "SOURCE_NOT_ALLOWED"
    static let skippedNotInstalled = "NOT_INSTALLED"

    /// `app` limits the run to one source and, like `fetch`, refuses one that is unknown or not in `approvedSources`.
    static func run(_ services: Services, app named: String?, force: Bool) async throws -> Report {
        let config = try services.store.load()
        let named = named.flatMap { $0.isEmpty ? nil : $0 }
        if let named { _ = try FetchCatalog.approved(app: named, config: config) }
        let ledger = try services.ledgerStore.load()
        let now = services.clock.now()
        var report = Report(checkedAt: now)

        let store = UpdateCacheStore(paths: services.home)
        var cache = UpdateCache()
        var rewrite = false
        do {
            (cache, rewrite) = try store.load(now: now)
        } catch {
            rewrite = true
            report.warnings.append(
                CanaryCommand.warning(
                    "UPDATES_CACHE_UNREADABLE", "updates.json could not be read, so every source is checked.",
                    "Check the permissions of $SIDELOAD_HOME; the file is rewritten."))
        }

        let installed = installedRecords(ledger, saved: Set(config.devices.keys))
        var cancelled = false
        for catalog in FetchCatalog.sources where named == nil || catalog.app == named {
            if cancelled || Task.isCancelled {
                cancelled = true
                break
            }
            let app = catalog.app
            guard let source = try? FetchCatalog.approved(app: app, config: config) else {
                report.sources.append(skipped(app, skippedNotApproved, "\(app) is not in approvedSources in config.json."))
                continue
            }
            guard installed[app] != nil else {
                report.sources.append(skipped(app, skippedNotInstalled, "\(app) has no install on a saved device."))
                continue
            }
            switch UpdateCadence.decide(cache.apps[app], now: now, force: force) {
            case .wait(let until):
                report.sources.append(replay(app, cache.apps[app], until: until))
            case .check:
                services.log("updates: reading the \(app) metadata")
                let entry = cache.apps[app] ?? UpdateCacheEntry()
                do {
                    let asset = try await resolve(services, source)
                    let upstream = UpdateUpstream(asset)
                    cache.apps[app] = entry.succeeded(upstream, at: now)
                    rewrite = true
                    report.sources.append(SourceReport(app: app, status: .ok, checkedAt: now, upstream: upstream))
                } catch {
                    let failure = SourceMetadata.map(error, command: "updates")
                    if failure.code == "CANCELLED" {
                        cancelled = true
                        break
                    }
                    var asked: Int?
                    if case .number(let seconds)? = failure.data["retryAfter"] { asked = Int(seconds) }
                    let next = entry.failed(code: failure.code, retryAfter: asked, at: now)
                    cache.apps[app] = next
                    rewrite = true
                    report.sources.append(
                        SourceReport(
                            app: app, status: .error, checkedAt: next.checkedAt, upstream: next.upstream, failure: failure))
                }
            }
        }

        if rewrite {
            do {
                try store.save(cache)
            } catch {
                report.warnings.append(
                    CanaryCommand.warning(
                        "UPDATES_CACHE_NOT_WRITTEN", "updates.json could not be written, so the next run asks again.",
                        "Check the permissions and free space of $SIDELOAD_HOME."))
            }
        }
        if cancelled { throw SideloadError("CANCELLED", "updates was cancelled.", fix: "Re-run the command.") }

        for source in report.sources {
            for record in installed[source.app] ?? [] {
                let state = source.upstream.map { VersionOrder.compare(installed: record.version, upstream: $0.version) } ?? .unknown
                report.installs.append(InstallReport(device: record.device, app: record.app, installed: record.version, state: state))
            }
        }
        return report
    }

    // MARK: pieces

    /// One metadata GET, then the resolver's own checks, so an update is only reported when `fetch` would accept it.
    private static func resolve(_ services: Services, _ source: FetchSource) async throws -> ResolvedAsset {
        let response = try await SourceMetadata.get(services, source, command: "updates")
        guard response.status == 200 else {
            let rateLimited = response.status == 403 || response.status == 429
            throw SourceMetadata.httpError(response.status, retryAfter: rateLimited ? response.retryAfter : nil)
        }
        guard response.body.count <= URLSessionTransport.maxBodyBytes else {
            throw SourceMetadata.map(HTTPTransportError.bodyTooLarge)
        }
        let asset = try SourceResolver.resolve(source, json: response.body)
        guard DownloadPolicy.permits(asset.url, hosts: source.downloadHosts) else {
            throw SideloadError(
                "SOURCE_NOT_ALLOWED", "The download URL is not https on an allowed host for \(source.app).",
                fix: "Allowed hosts: \(source.downloadHosts.sorted().joined(separator: ", ")).")
        }
        return asset
    }

    private static func skipped(_ app: String, _ code: String, _ message: String) -> SourceReport {
        SourceReport(app: app, status: .skipped, failure: SideloadError(code, message))
    }

    /// A source not asked this run: what the file holds, with the last attempt's failure if it was one.
    private static func replay(_ app: String, _ entry: UpdateCacheEntry?, until: Date) -> SourceReport {
        var report = SourceReport(app: app, status: .ok, checkedAt: entry?.checkedAt, fromCache: true, upstream: entry?.upstream)
        if let entry, let code = entry.errorCode, let at = entry.errorAt {
            let stamp = ISO8601DateFormatter().string(from: until)
            report.status = .error
            report.failure = SideloadError(
                code, "The last check of \(app) failed (\(code)) at \(ISO8601DateFormatter().string(from: at)).",
                fix: "It is not asked again before \(stamp).")
        }
        return report
    }

    /// The installs that count: on a saved device, still there (or lent to the lab), grouped by app.
    private static func installedRecords(_ ledger: Ledger, saved: Set<String>) -> [String: [LedgerInstall]] {
        var out: [String: [LedgerInstall]] = [:]
        for record in ledger.installs where saved.contains(record.device) {
            let lent = ledger.slots.contains { $0.id == record.id && $0.lentTo != nil }
            guard record.present || lent else { continue }
            out[record.app, default: []].append(record)
        }
        return out.mapValues { $0.sorted { ($0.device, $0.id) < ($1.device, $1.id) } }
    }
}
