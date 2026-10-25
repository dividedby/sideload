import Foundation

/// What a profile source found: the decodable profiles, and how many candidates it had to skip.
public struct ProfileScan: Sendable, Equatable {
    public var profiles: [ProvisioningProfile]
    /// Files that could not be decoded, or were past the scan cap. Counted, never fatal.
    public var skipped: Int

    public init(profiles: [ProvisioningProfile] = [], skipped: Int = 0) {
        self.profiles = profiles
        self.skipped = skipped
    }
}

/// Where provisioning profiles come from. Today: Xcode's own folders (`XcodeManagedProfileSource`). The
/// read-only `portal` command is meant to implement the same protocol later; nothing depends on which.
public protocol ProfileSource: Sendable {
    func candidates() async throws -> ProfileScan
}

/// The default in `Services`: a test that forgets to inject a source can never read the real profile folders.
public struct UnavailableProfileSource: ProfileSource {
    public init() {}

    public func candidates() async throws -> ProfileScan {
        throw SideloadError(
            "PROFILES_UNAVAILABLE", "No profile source is configured.",
            fix: "Inject a ProfileSource (Services.live wires the Xcode folders).")
    }
}
