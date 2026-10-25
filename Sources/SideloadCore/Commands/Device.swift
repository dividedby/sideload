/// Options for `device save|list|auto-refresh|slots`. `sub` is the first positional after `device`.
public struct DeviceOptions: Sendable, Equatable {
    public var sub: String?
    public var alias: String?
    public var match: String?
    public var platform: String?
    /// `--on` / `--off` for `auto-refresh`.
    public var on: Bool
    public var off: Bool
    /// `--reserved <0-3>` for `slots`, as typed.
    public var reserved: String?
    /// `--app <a>` / `--none` for `lendable`.
    public var app: String?
    public var none: Bool
    /// Owner confirmation (design section 8); agents must not pass it.
    public var yes: Bool

    public init(
        sub: String? = nil, alias: String? = nil, match: String? = nil, platform: String? = nil,
        on: Bool = false, off: Bool = false, reserved: String? = nil, app: String? = nil, none: Bool = false,
        yes: Bool = false
    ) {
        self.sub = sub
        self.alias = alias
        self.match = match
        self.platform = platform
        self.on = on
        self.off = off
        self.reserved = reserved
        self.app = app
        self.none = none
        self.yes = yes
    }
}

/// `device save | list | auto-refresh | slots | lendable`. IDs are read from `devicectl list devices` output, never typed by hand.
public enum DeviceCommand {
    static let platforms = ["ios", "tvos"]

    public static func run(_ services: Services, _ options: DeviceOptions) async -> Envelope {
        do {
            if options.sub != "lendable", options.app != nil || options.none {
                return .fail(
                    "device", code: "USAGE", message: "--app and --none belong to `device lendable`.",
                    fix: "sideload device lendable --alias <alias> --app <app>|--none --yes")
            }
            switch options.sub {
            case "save": return try await save(services, options)
            case "list": return try await list(services)
            case "auto-refresh": return try await autoRefresh(services, options)
            case "slots": return try await slots(services, options)
            case "lendable": return try await lendable(services, options)
            default:
                return .fail(
                    "device", code: "USAGE", message: "Unknown device subcommand \"\(options.sub ?? "")\".",
                    fix: "Use `sideload device save|list|auto-refresh|slots|lendable`.")
            }
        } catch {
            return .from(error, command: "device")
        }
    }

    // `^[a-z0-9][a-z0-9_-]{0,31}$`, ASCII, case-insensitive.
    static func isValidAlias(_ alias: String) -> Bool {
        let bytes = Array(alias.utf8)
        func alnum(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        guard (1...32).contains(bytes.count), alnum(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { alnum($0) || $0 == 0x2D || $0 == 0x5F }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func tail(_ id: String?) -> JSONValue {
        nonEmpty(id).map { .string(Redactor.tail4($0)) } ?? .null
    }

    /// The device name is never echoed: it can carry the owner's name.
    private static func redacted(_ d: ListedDevice) -> [String: JSONValue] {
        ["name": "<device>", "platform": .string(d.platform), "udid": tail(d.udid), "coreDeviceId": tail(d.coreDeviceId)]
    }

    private static func listDevices(_ services: Services) async throws -> [ListedDevice] {
        guard let devices = try await services.deviceCtl.listDevices() else {
            throw SideloadError(
                "DEVICECTL_FAILED", "devicectl could not list devices.", fix: "Check that Xcode is installed, then retry.")
        }
        return devices
    }

    private static func save(_ services: Services, _ options: DeviceOptions) async throws -> Envelope {
        let command = "device save"
        if options.on || options.off || options.reserved != nil {
            return .fail(
                command, code: "USAGE", message: "device save does not take --on, --off or --reserved.",
                fix: "Use `device auto-refresh` or `device slots` for those.")
        }
        guard let alias = nonEmpty(options.alias), let match = nonEmpty(options.match),
            let platform = nonEmpty(options.platform)
        else {
            return .fail(
                command, code: "USAGE", message: "device save needs --alias, --match and --platform.",
                fix: "sideload device save --alias <alias> --match <device name|udid> --platform ios|tvos --yes")
        }
        guard isValidAlias(alias) else {
            return .fail(
                command, code: "USAGE", message: "Alias must be 1-32 chars of letters, digits, \"-\" or \"_\".",
                fix: "Choose a simpler alias, e.g. iphone.")
        }
        guard platforms.contains(platform) else {
            return .fail(
                command, code: "USAGE", message: "Unknown platform \"\(platform)\".",
                fix: "Use --platform ios or --platform tvos.")
        }

        let devices = try await listDevices(services)
        let candidates = DeviceList.findCandidates(devices, query: match, platform: platform)
        if candidates.isEmpty {
            return .fail(
                command, code: "DEVICE_NOT_FOUND", message: "No physical device of that platform matched.",
                fix: platform == "tvos"
                    ? "The Apple TV must first be paired with this Mac in Xcode (owner action: Settings > Remotes and Devices)."
                    : "Connect the device by USB, unlock it, trust this Mac, and match by its exact name or UDID.")
        }
        if candidates.count > 1 {
            return .fail(
                command, code: "AMBIGUOUS_MATCH", message: "\(candidates.count) devices matched.",
                fix: "Match by UDID instead of name.",
                data: ["candidates": .array(candidates.map { .object(redacted($0)) })])
        }
        let dev = candidates[0]
        let udid = nonEmpty(dev.udid)
        let coreDeviceId = nonEmpty(dev.coreDeviceId)
        if udid == nil && coreDeviceId == nil {
            return .fail(
                command, code: "DEVICE_NOT_FOUND", message: "The matched device has no usable ID.",
                fix: "Reconnect the device and retry.")
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED", message: "Owner confirmation is required to save this device.",
                fix: "Check the candidate is your device, then re-run with --yes (owner only).",
                data: ["candidate": .object(redacted(dev))])
        }

        // Names and hostnames are kept only so canary logs can be scrubbed; never echoed in output.
        try await services.store.update { config in
            let prior = config.devices[alias]
            if let prior, prior.udid != udid || prior.coreDeviceId != coreDeviceId {
                throw SideloadError(
                    "ALIAS_EXISTS", "Alias \"\(alias)\" is already saved for a different device.",
                    fix: "Pick another alias, or remove the entry from config.json yourself.")
            }
            config.devices[alias] = SavedDevice(
                udid: udid, coreDeviceId: coreDeviceId, platform: platform,
                name: prior?.name ?? nonEmpty(dev.name),
                hostnames: (prior?.hostnames.isEmpty == false ? prior?.hostnames : nil) ?? dev.hostnames,
                autoRefresh: prior?.autoRefresh ?? false, freeSlotsReserved: prior?.freeSlotsReservedRaw ?? 0,
                lendableApp: prior?.lendableApp, extra: prior?.extra ?? [:])
        }
        var device = redacted(dev)
        device["alias"] = .string(alias)
        return .result(command, ["device": .object(device)])
    }

    private static func list(_ services: Services) async throws -> Envelope {
        let config = try services.store.load()
        let saved = try config.savedDevices()
        var warnings: [JSONValue] = []
        var visible: [ListedDevice]?
        if !saved.isEmpty {
            do {
                visible = try await listDevices(services)
            } catch {
                let e = error as? SideloadError
                warnings.append([
                    "code": .string(e?.code ?? "DEVICECTL_FAILED"),
                    "message": .string(e?.message ?? String(describing: error)),
                    "fix": e?.fix.map(JSONValue.string) ?? .null,
                ])
            }
        }
        for d in saved where config.devices[d.alias]?.freeSlotsReserved == nil {
            warnings.append([
                "code": "CONFIG_INVALID",
                "message": .string("Saved device \"\(d.alias)\" has a freeSlotsReserved outside 0 to 3; its free-team operations are disabled."),
                "fix": .string("Run `sideload device slots --alias \(d.alias) --reserved <0-3> --yes` (owner) or fix config.json."),
            ])
        }
        let devices: [JSONValue] = saved.map { d in
            let listed = visible.flatMap { DeviceList.findSaved($0, matching: d) }
            let visibility = visible.map { _ in DeviceList.visibilityOf(listed).rawValue } ?? "unknown"
            let saved = config.devices[d.alias] ?? SavedDevice()
            return [
                "alias": .string(d.alias),
                "platform": d.platform.map(JSONValue.string) ?? .null,
                "udid": tail(d.udid),
                "coreDeviceId": tail(d.coreDeviceId),
                "visibility": .string(visibility),
                "transport": .string((listed?.transport ?? .unknown).rawValue),
                "autoRefresh": .bool(saved.autoRefresh),
                "freeSlotsReserved": saved.freeSlotsReserved.map { .number(Double($0)) } ?? .null,
                "autoEligible": .bool(DeviceList.autoEligible(saved, listed: listed)),
            ]
        }
        return .result("device list", ["devices": .array(devices), "warnings": .array(warnings)])
    }

    // MARK: - Owner config: auto-refresh and slots

    /// Shared front of the two config commands, after usage: the alias must be saved, then `--yes`. Touches no device.
    private static func requireSavedAndConfirmed(
        _ services: Services, _ options: DeviceOptions, command: String, confirmFix: String
    ) throws -> Envelope? {
        let config = try services.store.load()
        guard config.devices[options.alias ?? ""] != nil else {
            throw SideloadError(
                "DEVICE_NOT_SAVED", "No saved device with alias \"\(options.alias ?? "")\".",
                fix: "sideload device save --alias <alias> --match <device name> --platform ios|tvos --yes")
        }
        guard options.yes else {
            return .fail(
                command, code: "CONFIRM_REQUIRED", message: "Owner confirmation is required to change this device's settings.",
                fix: confirmFix)
        }
        return nil
    }

    private static func configured(_ command: String, alias: String, _ d: SavedDevice) -> Envelope {
        .result(
            command,
            [
                "device": [
                    "alias": .string(alias), "platform": d.platform.map(JSONValue.string) ?? .null,
                    "udid": tail(d.udid), "coreDeviceId": tail(d.coreDeviceId),
                    "autoRefresh": .bool(d.autoRefresh),
                    "freeSlotsReserved": d.freeSlotsReserved.map { .number(Double($0)) } ?? .null,
                ]
            ])
    }

    /// `device auto-refresh --alias a --on|--off --yes`: the owner's opt-in for `refresh --auto` (design section 18).
    private static func autoRefresh(_ services: Services, _ options: DeviceOptions) async throws -> Envelope {
        let command = "device auto-refresh"
        let usageFix = "sideload device auto-refresh --alias <alias> --on|--off --yes"
        if options.reserved != nil {
            return .fail(
                command, code: "USAGE", message: "device auto-refresh does not take --reserved.",
                fix: "Use `device slots` for that.")
        }
        guard let alias = nonEmpty(options.alias), options.on != options.off else {
            return .fail(
                command, code: "USAGE", message: "device auto-refresh needs --alias and exactly one of --on or --off.",
                fix: usageFix)
        }
        if let stop = try requireSavedAndConfirmed(
            services, options, command: command,
            confirmFix: "Re-run with --yes (owner only): \(usageFix)")
        { return stop }
        let updated = try await services.store.update { config -> SavedDevice in
            guard var d = config.devices[alias] else {
                throw SideloadError("DEVICE_NOT_SAVED", "No saved device with alias \"\(alias)\".")
            }
            if options.on { _ = try d.requireFreeSlotsReserved(alias: alias) }
            d.autoRefresh = options.on
            config.devices[alias] = d
            return d
        }
        return configured(command, alias: alias, updated)
    }

    /// `device slots --alias a --reserved 0-3 --yes`: dev-signed apps sideload does not manage (design section 18).
    private static func slots(_ services: Services, _ options: DeviceOptions) async throws -> Envelope {
        let command = "device slots"
        let usageFix = "sideload device slots --alias <alias> --reserved 0|1|2|3 --yes"
        if options.on || options.off {
            return .fail(
                command, code: "USAGE", message: "device slots does not take --on or --off.",
                fix: "Use `device auto-refresh` for that.")
        }
        guard let alias = nonEmpty(options.alias), let raw = nonEmpty(options.reserved) else {
            return .fail(command, code: "USAGE", message: "device slots needs --alias and --reserved.", fix: usageFix)
        }
        guard let reserved = Int(raw), SavedDevice.freeSlotRange.contains(reserved) else {
            return .fail(command, code: "USAGE", message: "--reserved must be a whole number from 0 to 3.", fix: usageFix)
        }
        if let stop = try requireSavedAndConfirmed(
            services, options, command: command,
            confirmFix: "Re-run with --yes (owner only): \(usageFix)")
        { return stop }
        let updated = try await services.store.update { config -> SavedDevice in
            guard var d = config.devices[alias] else {
                throw SideloadError("DEVICE_NOT_SAVED", "No saved device with alias \"\(alias)\".")
            }
            try d.setFreeSlotsReserved(reserved)
            config.devices[alias] = d
            return d
        }
        return configured(command, alias: alias, updated)
    }

    /// `device lendable --alias a --app <app>|--none --yes`: the one app the lab may borrow the slot of through
    /// `slot lend` (design section 18). Owner-only; touches no device.
    private static func lendable(_ services: Services, _ options: DeviceOptions) async throws -> Envelope {
        let command = "device lendable"
        let usageFix = "sideload device lendable --alias <alias> --app <\(ProvisionApp.names.joined(separator: "|"))>|--none --yes"
        if options.on || options.off || options.reserved != nil || options.match != nil || options.platform != nil {
            return .fail(
                command, code: "USAGE", message: "device lendable takes only --alias, --app or --none, and --yes.", fix: usageFix)
        }
        guard let alias = nonEmpty(options.alias), (nonEmpty(options.app) != nil) != options.none else {
            return .fail(
                command, code: "USAGE", message: "device lendable needs --alias and exactly one of --app or --none.",
                fix: usageFix)
        }
        var chosen: ProvisionApp?
        if let name = nonEmpty(options.app) {
            guard let app = ProvisionApp(rawValue: name) else {
                return .fail(
                    command, code: "USAGE", message: "Unknown app \"\(printableCut(name))\".",
                    fix: "Use one of: \(ProvisionApp.names.joined(separator: ", ")).")
            }
            chosen = app
        }
        if let stop = try requireSavedAndConfirmed(
            services, options, command: command, confirmFix: "Re-run with --yes (owner only): \(usageFix)")
        { return stop }
        let updated = try await services.store.update { config -> SavedDevice in
            guard var d = config.devices[alias] else {
                throw SideloadError("DEVICE_NOT_SAVED", "No saved device with alias \"\(alias)\".")
            }
            if let chosen {
                guard d.platform == chosen.devicePlatform else {
                    throw SideloadError(
                        "PLATFORM_MISMATCH",
                        "\(chosen.rawValue) needs a \(chosen.devicePlatform) device; the saved device is \(d.platform ?? "of unknown platform").",
                        fix: "Pick an app that fits the device.")
                }
            }
            d.lendableApp = chosen?.rawValue
            config.devices[alias] = d
            return d
        }
        return .result(
            command,
            [
                "device": [
                    "alias": .string(alias), "platform": updated.platform.map(JSONValue.string) ?? .null,
                    "udid": tail(updated.udid), "coreDeviceId": tail(updated.coreDeviceId),
                    "lendableApp": updated.lendableApp.map(JSONValue.string) ?? .null,
                ]
            ])
    }
}
