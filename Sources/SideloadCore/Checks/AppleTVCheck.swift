/// Informational only. Never an error.
public struct AppleTVCheck: Check {
    public static let notPairedMessage = "not paired with this Mac (pair it in Xcode)"

    public let id = "appletv"

    public init() {}

    private var notPaired: CheckResult {
        CheckResult(id: id, severity: .info, message: Self.notPairedMessage, status: "not-paired")
    }

    public func run(_ services: Services) async throws -> [CheckResult] {
        let saved = try services.store.load().savedDevices(platform: "tvos")
        if saved.isEmpty { return [notPaired] }

        // A failed listing counts as an empty one here: the row then reads not-paired, never fail.
        let devices = try await services.deviceCtl.listDevices() ?? []
        return saved.map { d in
            switch DeviceList.visibilityOf(DeviceList.findSaved(devices, matching: d)) {
            case .ok:
                return CheckResult(id: id, severity: .ok, message: "\(d.alias): visible and paired.")
            case .unavailable:
                return CheckResult(
                    id: id, severity: .warn,
                    message: "\(d.alias): paired but unavailable (asleep or off-network).",
                    fix: "Wake the Apple TV and retry.")
            case .absent, .unpaired:
                return notPaired
            }
        }
    }
}
