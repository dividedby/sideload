import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Profiles are plists built at runtime (no .mobileprovision fixture, no real UDID). The CMS wrapper is what
// `security cms -D` removes, so the fake runner returns the bare XML.

/// Fixed dates around `testNow` (2026-10-19 12:00 UTC).
func daysFromNow(_ days: Double) -> Date { testNow.addingTimeInterval(days * 86_400) }

func certDER(_ base64: String) throws -> Data {
    try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
}

func profileXML(
    uuid: String = UUID().uuidString, team: String = Team.id, applicationIdentifier: String? = nil,
    getTaskAllow: Any = true, devices: [String] = [savedUdid("1")], certs: [Data] = [],
    platform: [String] = ["iOS"], created: Date? = nil, expires: Date? = nil, extra: [String: Any] = [:]
) throws -> String {
    var dict: [String: Any] = [
        "UUID": uuid, "TeamIdentifier": [team], "Platform": platform,
        "CreationDate": created ?? daysFromNow(-30), "ExpirationDate": expires ?? daysFromNow(335),
        "ProvisionedDevices": devices, "DeveloperCertificates": certs,
        "Entitlements": ["application-identifier": applicationIdentifier ?? team + ".*", "get-task-allow": getTaskAllow],
    ]
    for (key, value) in extra { dict[key] = value }
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    return String(decoding: data, as: UTF8.self)
}

func paidProfile(
    uuid: String = UUID().uuidString, applicationIdentifier: String? = nil, devices: [String] = [savedUdid("1")],
    certs: [String] = [], expires: Date? = nil
) -> ProvisioningProfile {
    ProvisioningProfile(
        uuid: uuid, team: Team.id, applicationIdentifier: applicationIdentifier ?? Team.id + ".*", getTaskAllow: true,
        platforms: ["iOS"], created: daysFromNow(-30), expires: expires ?? daysFromNow(335),
        devices: devices.map { $0.lowercased() }, certFingerprints: certs)
}

/// Replays a fixed scan (or an error) and counts reads.
final class FakeProfileSource: ProfileSource {
    private let scan: ProfileScan
    private let failure: (any Error)?
    private let reads = Mutex(0)

    init(_ profiles: [ProvisioningProfile] = [], skipped: Int = 0, failure: (any Error)? = nil) {
        scan = ProfileScan(profiles: profiles, skipped: skipped)
        self.failure = failure
    }

    var readCount: Int { reads.withLock { $0 } }

    func candidates() async throws -> ProfileScan {
        reads.withLock { $0 += 1 }
        if let failure { throw failure }
        return scan
    }
}
