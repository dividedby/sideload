import Foundation

/// Everything the report needs, already fetched. The report is a pure projection onto an allowlist of
/// redaction-safe fields (design section 7): it cannot print a name, a serial number, a common name, a full
/// fingerprint or a full UDID because it never reads one.
struct PortalReportInput {
    var requested: [PortalResource]
    var results: [PortalResource: Result<PortalListing, SideloadError>]
    /// The key's role as recorded in key.json, and the last four characters of its id.
    var role: String?
    var keyIdTail: String
    var bundleIdPrefix: String?
    /// Saved device UDIDs, lower-cased; nil when config.json is absent.
    var savedUDIDs: Set<String>?
    /// SHA-1 references (upper-case hex) of the signing identities in the login keychain; nil when unreadable.
    /// Asked for only when a development certificate is listed.
    var keychainReferences: () -> Set<String>?
    var now: Date
    var showIdentifiers: Bool
}

enum PortalReport {
    static let command = "portal"
    static let otherIdentifier = "<other>"

    /// One list, decoded once and shared by the team guard and the projections.
    struct Context {
        let input: PortalReportInput
        let certificates: [(cert: PortalCertificate, read: KeychainCertificate?)]
        let bundleIds: [PortalBundleId]
        let devices: [PortalDevice]
        let profiles: [PortalProfile]

        init(_ input: PortalReportInput, listings: [PortalResource: PortalListing]) {
            self.input = input
            certificates = (listings[.certificates]?.items ?? []).map { item in
                let cert = PortalCertificate(item)
                return (cert, cert.der.flatMap { CertificateReader.read(der: $0) })
            }
            bundleIds = (listings[.bundleIds]?.items ?? []).map(PortalBundleId.init)
            devices = (listings[.devices]?.items ?? []).map(PortalDevice.init)
            profiles = (listings[.profiles]?.items ?? []).map(PortalProfile.init)
        }
    }

    /// A projected item and the key it sorts by (then id), so the output is deterministic.
    struct Row {
        let sortKey: String
        let id: String
        let item: JSONValue
    }

    /// The summary counters and warnings the projections add to.
    struct Accumulator {
        var summary: [String: JSONValue] = [:]
        var warnings: [JSONValue] = []

        /// Adds one to `summary[group][label]` (`unknown` when the label is missing).
        mutating func increment(_ group: String, label: String?) {
            guard case .object(var counts) = summary[group] ?? .object([:]) else { return }
            let name = label ?? "unknown"
            if case .number(let n)? = counts[name] { counts[name] = .number(n + 1) } else { counts[name] = .number(1) }
            summary[group] = .object(counts)
        }

        mutating func warn(_ code: String, _ message: String, _ fix: String) {
            warnings.append(["code": .string(code), "message": .string(message), "fix": .string(fix)])
        }
    }

    static func build(_ input: PortalReportInput) -> Envelope {
        let listings: [PortalResource: PortalListing] = input.results.compactMapValues { try? $0.get() }
        let context = Context(input, listings: listings)

        let base: [String: JSONValue] = [
            "team": .string(Team.id),
            "key": ["role": input.role.map(JSONValue.string) ?? .null, "idTail": .string(input.keyIdTail)],
        ]

        // Guard: the data itself must belong to the locked team before any of it is listed.
        let reads = context.certificates.compactMap(\.read)
        if let failure = teamGuard(reads, context.bundleIds) {
            var counts: [String: JSONValue] = [:]
            for resource in input.requested {
                if let listing = listings[resource] { counts[resource.rawValue] = jsonNumber(listing.items.count) }
            }
            var data = base
            data["counts"] = .object(counts)
            return Envelope(
                ok: false, command: command, data: data,
                errors: [Envelope.Entry(code: failure.code, message: failure.message, fix: failure.fix)])
        }

        var accumulator = Accumulator()
        // The team check needs a readable certificate or an App ID seed; without either it did not run.
        if reads.isEmpty && !context.bundleIds.contains(where: { $0.seedId != nil }) {
            accumulator.warn(
                "TEAM_UNVERIFIED",
                "No certificate or App ID was available to confirm this data belongs to team \(Team.id).",
                "List certificates and App IDs too (`sideload portal` with no argument) with a key that can read them.")
        }

        var sections: [String: JSONValue] = [:]
        var errors: [Envelope.Entry] = []
        for resource in PortalResource.allCases {
            guard input.requested.contains(resource), let result = input.results[resource] else {
                sections[resource.rawValue] = ["status": "skipped", "count": 0, "truncated": false, "items": []]
                continue
            }
            switch result {
            case .failure(let error):
                sections[resource.rawValue] = [
                    "status": "error", "count": 0, "truncated": false, "items": [], "code": .string(error.code),
                ]
                errors.append(Envelope.Entry(code: error.code, message: error.message, fix: error.fix))
            case .success(let listing):
                let rows = resource.rows(context, &accumulator)
                    .sorted { ($0.sortKey, $0.id) < ($1.sortKey, $1.id) }
                var section: [String: JSONValue] = [
                    "status": "ok", "count": jsonNumber(rows.count), "truncated": false, "items": .array(rows.map(\.item)),
                ]
                if listing.truncated {
                    section["status"] = "error"
                    section["truncated"] = true
                    section["code"] = "PORTAL_TRUNCATED"
                    errors.append(
                        Envelope.Entry(
                            code: "PORTAL_TRUNCATED",
                            message: "Listing \(resource.label) stopped at \(PortalClient.maxPages) pages; the list is incomplete.",
                            fix: "Report this: a team this large needs a paging change."))
                }
                sections[resource.rawValue] = .object(section)
            }
        }

        var data = base
        data["sections"] = .object(sections)
        data["summary"] = .object(accumulator.summary)
        data["warnings"] = .array(accumulator.warnings)
        return Envelope(ok: errors.isEmpty, command: command, data: data, errors: errors)
    }

    // MARK: Guard

    /// Nil when every certificate and App ID that could be read belongs to the locked team.
    static func teamGuard(_ certificates: [KeychainCertificate], _ bundleIds: [PortalBundleId]) -> SideloadError? {
        let seeds = bundleIds.compactMap(\.seedId)
        if certificates.contains(where: { $0.info.carriesDeniedOU }) || seeds.contains(where: Team.denied.contains) {
            return SideloadError(
                "FREE_TEAM_SELECTED", "The portal data belongs to the deny-listed free team; the listing was withheld.",
                fix: "Use the App Store Connect API key of the paid team \(Team.id).")
        }
        if certificates.contains(where: { $0.info.teamOU != Team.id }) || seeds.contains(where: { $0 != Team.id }) {
            return SideloadError(
                "TEAM_MISMATCH", "The portal data does not belong to team \(Team.id); the listing was withheld.",
                fix: "Use the App Store Connect API key of the paid team \(Team.id).")
        }
        return nil
    }

    // MARK: Values and dates

    fileprivate static func jsonNumber(_ n: Int) -> JSONValue { .number(Double(n)) }

    fileprivate static func stringOrNull(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    /// Apple's timestamps (`2027-10-16T22:39:42.000+0000`), tolerant of a missing fraction, of `+00:00` and of `Z`.
    private static let timestampStyles: [Date.ISO8601FormatStyle] = [true, false].flatMap { fraction in
        [Date.ISO8601FormatStyle.TimeZoneSeparator.omitted, .colon].map { separator in
            Date.ISO8601FormatStyle(timeZoneSeparator: separator, includingFractionalSeconds: fraction, timeZone: .gmt)
        }
    }

    private static let dayStyle = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()

    static func date(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        for style in timestampStyles {
            if let parsed = try? Date(timestamp, strategy: style) { return parsed }
        }
        return nil
    }

    /// `YYYY-MM-DD` of a timestamp, in UTC whatever offset it carries and whatever the Mac's time zone is.
    /// A date-only string is kept as it is; nil when it is neither.
    static func utcDay(_ timestamp: String?) -> String? {
        if let parsed = date(timestamp) { return utcDay(of: parsed) }
        guard let timestamp, timestamp.count == 10 else { return nil }
        for (i, c) in timestamp.enumerated() {
            if i == 4 || i == 7 {
                if c != "-" { return nil }
            } else if !(c.isASCII && c.isNumber) {
                return nil
            }
        }
        return timestamp
    }

    static func utcDay(of date: Date) -> String { date.formatted(dayStyle) }

    private static func utcDayValue(_ date: Date?) -> JSONValue { date.map { .string(utcDay(of: $0)) } ?? .null }

    // MARK: Projections

    fileprivate static func certificateRows(_ ctx: Context, _ acc: inout Accumulator) -> [Row] {
        var references: Set<String>?
        var askedKeychain = false
        var notInKeychain = 0
        var unreadable = 0
        acc.summary["certificatesByType"] = .object([:])
        var rows: [Row] = []
        for (cert, read) in ctx.certificates {
            if read == nil { unreadable += 1 }
            var inKeychain: JSONValue = .null
            if cert.type == "DEVELOPMENT", let read {
                if !askedKeychain {
                    askedKeychain = true
                    references = ctx.input.keychainReferences()
                }
                if let references {
                    let present = references.contains(read.reference.uppercased())
                    inKeychain = .bool(present)
                    if !present { notInKeychain += 1 }
                }
            }
            acc.increment("certificatesByType", label: cert.type)
            let expires = utcDay(cert.expires)
            rows.append(
                Row(
                    sortKey: expires ?? "", id: cert.id,
                    item: [
                        "id": .string(cert.id), "type": stringOrNull(cert.type), "platform": stringOrNull(cert.platform),
                        "activated": cert.activated.map(JSONValue.bool) ?? .null,
                        "expires": stringOrNull(expires), "issued": utcDayValue(read?.info.notBefore),
                        "certFp": read.map { .string(EvidenceBuilder.certFp($0.reference)) } ?? .null,
                        "inKeychain": inKeychain,
                    ]))
        }
        acc.summary["certificatesNotInKeychain"] = jsonNumber(notInKeychain)
        if askedKeychain && references == nil {
            acc.warn(
                "KEYCHAIN_UNREADABLE", "The login keychain could not be read, so inKeychain is unknown.",
                "Run `sideload doctor` and check the keychain.")
        }
        if notInKeychain > 0 {
            acc.warn(
                "CERT_NOT_IN_KEYCHAIN",
                "\(notInKeychain) development certificate(s) on the team have no signing identity on this Mac.",
                "Another tool or Mac may have created them; revoke any you do not recognise in the developer portal.")
        }
        if unreadable > 0 {
            acc.warn(
                "CERT_UNREADABLE", "\(unreadable) certificate(s) had content sideload could not parse.",
                "Compare their ids with the developer portal.")
        }
        return rows
    }

    fileprivate static func bundleIdRows(_ ctx: Context, _ acc: inout Accumulator) -> [Row] {
        let input = ctx.input
        var rows: [Row] = []
        var other = 0
        for bundle in ctx.bundleIds {
            let identifier = bundle.identifier
            let underPrefix: Bool? = input.bundleIdPrefix.map { prefix in
                guard let identifier else { return false }
                return identifier == prefix || identifier.hasPrefix(prefix + ".")
            }
            if underPrefix != true { other += 1 }
            let shown = input.showIdentifiers || underPrefix == true || identifier == "*"
            let components = identifier.map { $0.split(separator: ".", omittingEmptySubsequences: false).count }
            // Sorted by id alone: a hidden identifier must not leak through the order.
            rows.append(
                Row(
                    sortKey: "", id: bundle.id,
                    item: [
                        "id": .string(bundle.id), "platform": stringOrNull(bundle.platform),
                        "underPrefix": underPrefix.map(JSONValue.bool) ?? .null,
                        "identifier": shown ? stringOrNull(identifier) : .string(otherIdentifier),
                        "components": components.map(jsonNumber) ?? .null,
                    ]))
        }
        acc.summary["otherPrefixBundleIds"] = jsonNumber(other)
        if input.bundleIdPrefix == nil && !ctx.bundleIds.isEmpty {
            acc.warn(
                "BUNDLE_ID_PREFIX_UNSET", "config.json has no bundleIdPrefix, so App ID identifiers are hidden.",
                "Set bundleIdPrefix in $SIDELOAD_HOME/config.json, or pass --show-identifiers.")
        }
        return rows
    }

    fileprivate static func deviceRows(_ ctx: Context, _ acc: inout Accumulator) -> [Row] {
        acc.summary["devicesByClass"] = .object([:])
        return ctx.devices.map { device in
            acc.increment("devicesByClass", label: device.deviceClass)
            let savedLocally: JSONValue = {
                guard let saved = ctx.input.savedUDIDs, let udid = device.udid else { return .null }
                return .bool(saved.contains(udid.lowercased()))
            }()
            let added = utcDay(device.added)
            return Row(
                sortKey: added ?? "", id: device.id,
                item: [
                    "udid": device.udid.map { .string(Redactor.tail4($0)) } ?? .null,
                    "platform": stringOrNull(device.platform), "deviceClass": stringOrNull(device.deviceClass),
                    "model": stringOrNull(device.model), "status": stringOrNull(device.status),
                    "added": stringOrNull(added), "savedLocally": savedLocally,
                ])
        }
    }

    fileprivate static func profileRows(_ ctx: Context, _ acc: inout Accumulator) -> [Row] {
        var expiredCount = 0
        acc.summary["profilesByType"] = .object([:])
        acc.summary["profilesByState"] = .object([:])
        let rows = ctx.profiles.map { profile in
            acc.increment("profilesByType", label: profile.type)
            acc.increment("profilesByState", label: profile.state)
            let expired: JSONValue = date(profile.expires).map { .bool($0 < ctx.input.now) } ?? .null
            if expired == .bool(true) { expiredCount += 1 }
            let created = utcDay(profile.created)
            return Row(
                sortKey: created ?? "", id: profile.id,
                item: [
                    "id": .string(profile.id), "type": stringOrNull(profile.type), "state": stringOrNull(profile.state),
                    "platform": stringOrNull(profile.platform), "created": stringOrNull(created),
                    "expires": stringOrNull(utcDay(profile.expires)), "expired": expired,
                ])
        }
        acc.summary["expiredProfiles"] = jsonNumber(expiredCount)
        return rows
    }
}

extension PortalResource {
    /// The projection of this list's items: the one place that knows which fields it shows.
    fileprivate func rows(_ context: PortalReport.Context, _ accumulator: inout PortalReport.Accumulator)
        -> [PortalReport.Row]
    {
        switch self {
        case .certificates: PortalReport.certificateRows(context, &accumulator)
        case .bundleIds: PortalReport.bundleIdRows(context, &accumulator)
        case .devices: PortalReport.deviceRows(context, &accumulator)
        case .profiles: PortalReport.profileRows(context, &accumulator)
        }
    }
}
