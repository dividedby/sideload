/// Each saved iPhone must be visible to devicectl (matched on saved IDs only).
public struct DeviceCheck: Check {
    public static let fixSave = "sideload device save --alias iphone --match <device name> --platform ios --yes"

    public let id = "device"
    /// Restricts the check to these aliases (the canary preflight).
    public let aliases: [String]?

    public init(aliases: [String]? = nil) {
        self.aliases = aliases
    }

    public func run(_ services: Services) async throws -> [CheckResult] {
        var saved = try services.store.load().savedDevices(platform: "ios")
        if let aliases { saved = saved.filter { aliases.contains($0.alias) } }
        if saved.isEmpty {
            return [CheckResult(id: id, severity: .fail, message: "No saved iPhone.", fix: Self.fixSave)]
        }
        guard let devices = try await services.deviceCtl.listDevices() else {
            return saved.map {
                CheckResult(
                    id: id, severity: .fail,
                    message: "\($0.alias): `devicectl list devices` failed, so the device state is unknown.",
                    fix:
                        "Run `xcrun devicectl list devices` by hand. Check that Xcode 27 is installed and selected, connect and unlock the device, then retry."
                )
            }
        }
        return saved.map { d in
            let vis = DeviceList.visibilityOf(DeviceList.findSaved(devices, matching: d))
            switch vis {
            case .ok:
                return CheckResult(id: id, severity: .ok, message: "\(d.alias): visible and paired.")
            case .absent:
                return CheckResult(
                    id: id, severity: .fail, message: "\(d.alias): not visible to devicectl.",
                    fix: "Connect the device by USB, unlock it, and tap Trust if asked.")
            case .unpaired, .unavailable:
                return CheckResult(
                    id: id, severity: .warn,
                    message:
                        "\(d.alias): known but \(vis == .unpaired ? "not paired" : "unavailable (locked or unplugged)").",
                    fix: "Connect the device by USB and unlock it.")
            }
        }
    }
}
