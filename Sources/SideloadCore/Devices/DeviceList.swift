import Foundation

/// How a device is reached, from `devicectl list devices`. The key and values are unverified until spike S1
/// (design section 18); anything unrecognised is `unknown`, which is never auto-eligible.
public enum DeviceTransport: String, Sendable, Equatable, CaseIterable {
    /// Wi-Fi / local network (`localNetwork` in devicectl output seen so far).
    case network
    /// USB cable.
    case wired
    case unknown

    /// Keys under the connection dictionary, tried in order.
    static let keys = ["transportType", "transport"]

    /// Maps a raw devicectl value (case, spaces, `-` and `_` ignored). The raw string is never kept.
    static func from(raw: String?) -> DeviceTransport {
        guard let raw else { return .unknown }
        let norm = String(raw.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic })
        switch norm {
        case "wired", "usb", "cable": return .wired
        case "localnetwork", "network", "wifi", "wireless": return .network
        default: return .unknown
        }
    }
}

/// One entry of `devicectl list devices --json-output` (jsonVersion 5), reduced to what sideload uses.
public struct ListedDevice: Sendable, Equatable {
    public var name: String
    public var udid: String?
    public var coreDeviceId: String?
    /// Lowercased with whitespace removed: `ios`, `tvos`, ...
    public var platform: String
    /// False for simulators.
    public var physical: Bool
    public var paired: Bool
    public var hostnames: [String]
    /// `tunnelState` (legacy) / `state` (modern): `connected`, `disconnected`, `unavailable`, else `unknown`.
    public var link: String
    /// OS version (`27.0.1`) and build (`24A446`) from `osVersionNumber` / `osBuildUpdate`; nil when absent or malformed.
    public var osVersion: String?
    public var osBuild: String?
    /// `connectionProperties.transportType` (also under `properties.connection`); `unknown` when absent or unrecognised.
    public var transport: DeviceTransport
    /// `connectionProperties.lastConnectionDate` (ISO 8601): when this Mac last connected to the device. The menu bar
    /// shows it as "seen N h ago" for an offline device. Nil when absent or unparseable.
    public var lastConnection: Date?

    public init(
        name: String = "", udid: String? = nil, coreDeviceId: String? = nil, platform: String = "",
        physical: Bool = true, paired: Bool = false, hostnames: [String] = [], link: String = "unknown",
        osVersion: String? = nil, osBuild: String? = nil, transport: DeviceTransport = .unknown,
        lastConnection: Date? = nil
    ) {
        self.name = name
        self.udid = udid
        self.coreDeviceId = coreDeviceId
        self.platform = platform
        self.physical = physical
        self.paired = paired
        self.hostnames = hostnames
        self.link = link
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.transport = transport
        self.lastConnection = lastConnection
    }
}

/// How a saved device shows up in `devicectl list devices`.
public enum DeviceVisibility: String, Sendable, Equatable, CaseIterable {
    /// Not listed.
    case absent
    /// Listed but not paired.
    case unpaired
    /// Paired but unplugged, locked, or off-network.
    case unavailable
    /// Paired and reachable.
    case ok
}

/// Anything that carries saved device IDs (`SavedDevice`, `ResolvedDevice`).
public protocol DeviceIdentifiers {
    var udid: String? { get }
    var coreDeviceId: String? { get }
}

extension SavedDevice: DeviceIdentifiers {}
extension ResolvedDevice: DeviceIdentifiers {}

/// Parsing and lookup over the `devicectl list devices` document (design section 3). Takes the parsed JSON from `DeviceCtl`; runs nothing.
public enum DeviceList {
    /// Reads the modern `properties` dictionary and falls back to the deprecated `hardwareProperties`,
    /// `deviceProperties` and `connectionProperties` keys. Missing or malformed input gives an empty list;
    /// entries that are not JSON objects are skipped.
    public static func parse(_ json: JSONValue?) -> [ListedDevice] {
        guard case .object(let top)? = json, case .object(let result)? = top["result"],
            case .array(let entries)? = result["devices"]
        else { return [] }

        return entries.compactMap { entry -> ListedDevice? in
            guard case .object(let d) = entry else { return nil }
            let properties = d["properties"]?.objectValue
            let legacyState = d["deviceProperties"]?.objectValue
            let hw = firstPresent(properties?["hardware"], d["hardwareProperties"])?.objectValue ?? [:]
            let conn = firstPresent(properties?["connection"], d["connectionProperties"])?.objectValue ?? [:]
            let state = firstPresent(properties?["state"], d["deviceProperties"])?.objectValue ?? [:]

            let visibility = firstPresent(d["visibilityClass"], state["visibilityClass"])
            let physical: Bool
            if let reality = hw["reality"], reality.isTruthy {
                physical = reality != .string("simulated")
            } else {
                physical = visibility != .string("simulators")
            }

            let hostnames: [String]
            if case .array(let items)? = conn["potentialHostnames"] {
                hostnames = items.compactMap(\.stringValue)
            } else {
                hostnames = []
            }

            return ListedDevice(
                name: state["name"]?.stringValue ?? legacyState?["name"]?.stringValue ?? "",
                udid: hw["udid"]?.stringValue,
                coreDeviceId: d["identifier"]?.stringValue,
                platform: normalizedPlatform(hw["platform"]?.stringValue),
                physical: physical,
                paired: conn["pairingState"] == .string("paired"),
                hostnames: hostnames,
                link: firstPresent(conn["tunnelState"], conn["state"])?.stringValue ?? "unknown",
                osVersion: validVersion(state["osVersionNumber"]?.stringValue ?? legacyState?["osVersionNumber"]?.stringValue),
                osBuild: validBuild(state["osBuildUpdate"]?.stringValue ?? legacyState?["osBuildUpdate"]?.stringValue),
                transport: transportType(conn),
                lastConnection: conn["lastConnectionDate"]?.stringValue.flatMap(parseDate))
        }
    }

    /// An ISO 8601 date with or without fractional seconds (`2026-10-23T09:15:00.000Z`).
    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle())
    }

    /// The transport named by the connection dictionary; `unknown` for a missing key or an unrecognised value.
    static func transportType(_ connection: [String: JSONValue]) -> DeviceTransport {
        for key in DeviceTransport.keys {
            if let value = connection[key]?.stringValue { return .from(raw: value) }
        }
        return .unknown
    }

    /// `27.0.1`: one to three dot-separated numbers. Anything else (it ends up in evidence) is dropped.
    static func validVersion(_ s: String?) -> String? {
        guard let s, s.wholeMatch(of: /[0-9]+(\.[0-9]+){0,2}/) != nil else { return nil }
        return s
    }

    /// `24A446`: a short alphanumeric build label.
    static func validBuild(_ s: String?) -> String? {
        guard let s, s.wholeMatch(of: /[0-9A-Za-z]{2,12}/) != nil else { return nil }
        return s
    }

    /// Physical devices of `platform` (`ios`, `tvos`) whose name matches exactly (curly apostrophes read as
    /// straight, case and outer whitespace ignored) or whose UDID or CoreDevice ID equals `query`.
    public static func findCandidates(_ devices: [ListedDevice], query: String, platform: String) -> [ListedDevice] {
        let q = normalizedName(query)
        return devices.filter {
            $0.physical && $0.platform == platform
                && (normalizedName($0.name) == q || idsEqual($0.udid, query) || idsEqual($0.coreDeviceId, query))
        }
    }

    /// The physical device whose CoreDevice ID or UDID equals the saved one (case-insensitive).
    public static func findSaved(_ devices: [ListedDevice], matching saved: some DeviceIdentifiers) -> ListedDevice? {
        devices.first {
            $0.physical
                && (idsEqual($0.coreDeviceId, saved.coreDeviceId) || idsEqual($0.udid, saved.udid))
        }
    }

    public static func visibilityOf(_ entry: ListedDevice?) -> DeviceVisibility {
        guard let entry else { return .absent }
        if !entry.paired { return .unpaired }
        if entry.link == "unavailable" { return .unavailable }
        return .ok
    }

    /// Whether `refresh --auto` may act on this device now (design section 18): the owner opted in
    /// (`autoRefresh`), the listed entry is paired and its link is `connected`, and it is reached over Wi-Fi or USB.
    /// An absent entry or an `unknown` transport is never eligible. Pure; says nothing about the install itself.
    public static func autoEligible(_ saved: SavedDevice, listed: ListedDevice?) -> Bool {
        guard saved.autoRefresh, saved.freeSlotsReserved != nil, let listed, listed.physical else { return false }
        guard listed.transport == .network || listed.transport == .wired else { return false }
        // Fail closed: only an explicitly `connected` link counts; `disconnected`, `unavailable` and any
        // unrecognised state do not (visibility alone treats everything but `unavailable` as ok).
        return visibilityOf(listed) == .ok && listed.link == "connected"
    }

    // MARK: - Helpers

    /// `a ?? b` over JSON values, where JSON null counts as absent (as in JavaScript).
    private static func firstPresent(_ a: JSONValue?, _ b: JSONValue?) -> JSONValue? {
        if let a, a != .null { return a }
        if let b, b != .null { return b }
        return nil
    }

    private static func normalizedPlatform(_ p: String?) -> String {
        String((p ?? "").lowercased().unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    private static func normalizedName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Both non-empty and equal ignoring case.
    private static func idsEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return a.lowercased() == b.lowercased()
    }
}

extension JSONValue {
    fileprivate var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    fileprivate var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// JavaScript truthiness.
    fileprivate var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        case .array, .object: true
        }
    }
}
