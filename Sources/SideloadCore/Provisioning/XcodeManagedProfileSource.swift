import Foundation

/// Profiles Xcode manages: `~/Library/Developer/Xcode/UserData/Provisioning Profiles` (Xcode 16+) and the legacy
/// `~/Library/MobileDevice/Provisioning Profiles`. Each `*.mobileprovision` is decoded with `security cms -D -i`
/// through the `Runner` (argument array, 30 s timeout). Nothing is written; the original files are untouched.
public struct XcodeManagedProfileSource: ProfileSource {
    public static let toolTimeout = Duration.seconds(30)
    /// More files than this are not decoded; the rest count as skipped.
    public static let maxFiles = 1000

    public let runner: any Runner
    public let directories: [String]

    public init(runner: any Runner, directories: [String]) {
        self.runner = runner
        self.directories = directories
    }

    public static func defaultDirectories(homeDirectory: String) -> [String] {
        [
            homeDirectory + "/Library/Developer/Xcode/UserData/Provisioning Profiles",
            homeDirectory + "/Library/MobileDevice/Provisioning Profiles",
        ]
    }

    public func candidates() async throws -> ProfileScan {
        var files: [String] = []
        for dir in directories {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                continue
            } catch {
                throw SideloadError(
                    "PROFILES_UNREADABLE", "A provisioning profile folder could not be listed.",
                    fix: "Check that the folder exists and is readable.")
            }
            files += names.filter { $0.hasSuffix(".mobileprovision") }.sorted().map { dir + "/" + $0 }
        }

        var skipped = max(0, files.count - Self.maxFiles)
        var byUUID: [String: ProvisioningProfile] = [:]
        for path in files.prefix(Self.maxFiles) {
            let result = await runner.run(
                CommandSpec(executable: "/usr/bin/security", args: ["cms", "-D", "-i", path], timeout: Self.toolTimeout))
            guard result.code == 0, let profile = ProvisioningProfile.parse(result.stdout, file: path) else {
                skipped += 1
                continue
            }
            // The same UUID in both folders: keep the one that lives longer, the first on a tie.
            if let existing = byUUID[profile.uuid],
                (existing.expires ?? .distantPast) >= (profile.expires ?? .distantPast)
            {
                continue
            }
            byUUID[profile.uuid] = profile
        }
        return ProfileScan(profiles: byUUID.values.sorted { $0.uuid < $1.uuid }, skipped: skipped)
    }
}
