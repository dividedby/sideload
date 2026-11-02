import Foundation

// Add device (design section 12): which physical devices `devicectl` lists that are not saved yet, how the panel names them, and
// what the confirm says. Pure, apart from `find` and `saveStop`, which read. It never pairs or unpairs anything, and saving
// changes nothing on the device or the portal; registering on the free team is its own confirm (`MenuAction.addRegister`).

/// One listed device that is not saved. The panel sees `title`, never the device's name or a full ID.
public struct MenuDeviceCandidate: Sendable, Hashable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Its place in the list.
    public var id: Int
    /// "iPad · USB · …ab12": its type, connection and last four UDID characters.
    public var title: String
    /// What `device save` would be matched by; stays inside `SideloadCore`.
    var match: String
    var platform: String
    /// The alias the field starts with.
    public var suggestedAlias: String
    /// Why it cannot be saved now (not paired, no UDID); nil when it can.
    public var blocked: String?

    // A printed action or state carries no ID.
    public var description: String { title }
    public var debugDescription: String { title }
}

/// What the Add device card shows.
public enum MenuDevicePicker: Sendable, Equatable {
    case looking
    case list([MenuDeviceCandidate])
    case failed(MenuIssue)
}

public enum MenuAddDevice {
    /// The list is empty.
    public static let noneFound = "No new device found. Pair it in Xcode first, then check again."

    private static func kind(_ device: ListedDevice) -> (title: String, alias: String)? {
        guard DeviceCommand.platforms.contains(device.platform) else { return nil }
        switch device.deviceType?.lowercased() {
        case "iphone": return ("iPhone", "iphone")
        case "ipad": return ("iPad", "ipad")
        case "appletv": return ("Apple TV", "appletv")
        default: return device.platform == "tvos" ? ("Apple TV", "appletv") : ("iOS device", "device")
        }
    }

    private static func connection(_ device: ListedDevice) -> String? {
        if device.link == "unavailable" { return "offline" }
        switch device.transport {
        case .wired: return "USB"
        case .network: return "Wi-Fi"
        case .unknown: return nil
        }
    }

    private static func blocked(_ device: ListedDevice) -> String? {
        if !device.paired {
            return device.platform == "tvos"
                ? "Not paired: pair it in Xcode first (on the Apple TV: Settings > Remotes and Devices)"
                : "Not paired: pair it in Xcode first (connect it by USB, unlock it, trust this Mac)"
        }
        if device.udid?.isEmpty != false { return "No UDID yet: connect it, unlock it and check again" }
        return nil
    }

    /// The physical iOS and tvOS devices that no saved device matches, the ones that can be saved first.
    static func candidates(_ devices: [ListedDevice], config: Config) -> [MenuDeviceCandidate] {
        var taken = Set(config.devices.keys.map { $0.lowercased() })
        var found: [MenuDeviceCandidate] = []
        for device in devices where device.physical {
            guard let kind = kind(device), let match = device.udid.nonEmpty ?? device.coreDeviceId.nonEmpty else { continue }
            guard !config.devices.values.contains(where: { DeviceList.findSaved([device], matching: $0) != nil }) else { continue }
            var alias = kind.alias
            var next = 2
            while taken.contains(alias) {
                alias = "\(kind.alias)-\(next)"
                next += 1
            }
            taken.insert(alias)
            let title = ([kind.title, connection(device), Redactor.tail4(match)] as [String?]).compactMap { $0 }.joined(separator: " · ")
            found.append(
                MenuDeviceCandidate(
                    id: 0, title: title, match: match, platform: device.platform, suggestedAlias: alias, blocked: blocked(device)))
        }
        // A sort that keeps `devicectl`'s order among equals.
        let ordered = found.filter { $0.blocked == nil } + found.filter { $0.blocked != nil }
        return ordered.enumerated().map { index, candidate in
            var candidate = candidate
            candidate.id = index
            return candidate
        }
    }

    /// One read-only `devicectl list devices` and the config, for the picker.
    public static func find(_ services: Services) async -> MenuDevicePicker {
        do {
            let config = try services.store.load()
            guard let devices = try await services.deviceCtl.listDevices() else {
                return .failed(
                    MenuIssue(code: "DEVICECTL_FAILED", message: "devicectl could not list devices.", fix: "Check that Xcode is installed, then retry."))
            }
            return .list(candidates(devices, config: config))
        } catch {
            return .failed(MenuIssue(error))
        }
    }

    /// The picker opens with the device already chosen when there is only one it could be.
    public static func preselected(_ candidates: [MenuDeviceCandidate]) -> MenuDeviceCandidate? {
        let open = candidates.filter { $0.blocked == nil }
        return open.count == 1 ? open[0] : nil
    }

    public static func trimmedAlias(_ alias: String) -> String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why this alias cannot be used; nil when it can. The rule is `device save`'s, and an alias differing only in case counts as taken.
    public static func aliasProblem(_ alias: String, taken: [String]) -> String? {
        let alias = trimmedAlias(alias)
        if alias.isEmpty { return "Type an alias" }
        guard DeviceCommand.isValidAlias(alias) else {
            return "Use up to 32 letters, digits, \"-\" or \"_\", starting with a letter or digit"
        }
        if taken.contains(where: { $0.lowercased() == alias.lowercased() }) { return "\(alias) is already saved" }
        return nil
    }

    static func availability(alias: String, candidate: MenuDeviceCandidate, taken: [String]) -> MenuAvailability {
        if let blocked = candidate.blocked { return .disabled(blocked) }
        if let problem = aliasProblem(alias, taken: taken) { return .disabled(problem) }
        return .enabled
    }

    static func prompt(alias: String, candidate: MenuDeviceCandidate) -> MenuPrompt {
        MenuPrompt(
            title: "Save this device as \(alias)",
            lines: [
                candidate.title,
                "Saves it in config.json; the device and the free team are unchanged",
                "Auto-renew will be on: its installs renew while you are logged in and it is reachable; turn it off from its card",
                "Registering it on the free team is a separate confirm, only if Apple asks when you add its first app",
            ],
            confirmLabel: "Save device", destructive: false, runningLabel: "Saving \(alias)…", apps: [])
    }

    /// Why the save must not run, from `config.json` as it is on disk: the alias is taken, or this device is already saved
    /// under another one. Nil when it is clear.
    static func saveStop(alias: String, candidate: MenuDeviceCandidate, services: Services) -> String? {
        let config: Config
        do {
            config = try services.store.load()
        } catch {
            return "config.json could not be read"
        }
        if let problem = aliasProblem(alias, taken: Array(config.devices.keys)) { return problem }
        for (saved, device) in config.devices.sorted(by: { $0.key < $1.key }) {
            if [device.udid, device.coreDeviceId].contains(where: { $0?.lowercased() == candidate.match.lowercased() }) {
                return "This device is already saved as \(saved)"
            }
        }
        return nil
    }
}

extension MenuSnapshot {
    /// What the actions are checked against before anything is saved: no devices, nothing in the ledger.
    static func firstRun(now: Date) -> MenuSnapshot {
        MenuSnapshotBuilder.build(MenuInputs(now: now, canaryStatus: nil, config: Config(), ledger: Ledger(), probe: .listed([])))
    }
}

extension MenuPanel {
    /// What actions are checked against: the loaded panel, or on first run a panel with no devices (only Add device can be
    /// available there). Nil while loading and on a config that does not parse.
    public func actionSnapshot(now: Date) -> MenuSnapshot? {
        switch self {
        case .loaded(let snapshot): snapshot
        case .firstRun: .firstRun(now: now)
        case .loading, .failed: nil
        }
    }
}

extension String? {
    /// The value, unless it is nil or empty.
    fileprivate var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
