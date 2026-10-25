import Foundation

public struct InspectOptions: Sendable, Equatable {
    public var path: String?

    public init(path: String? = nil) {
        self.path = path
    }
}

/// `inspect <path.ipa>`: what is in an IPA, read-only. No device, portal, network, keychain or lock. The IPA is
/// untrusted input (design section 8): it is checked before it is unpacked into a private scratch folder, which is
/// removed again whatever happens.
public enum InspectCommand {
    static let command = "inspect"

    public static func run(
        _ services: Services, _ options: InspectOptions, registry: ScratchRegistry = .shared,
        limits: InspectLimits = InspectLimits()
    ) async -> Envelope {
        guard let path = options.path, !path.isEmpty else {
            return .fail(command, code: "USAGE", message: "inspect needs the path of an .ipa file.", fix: "Run `sideload inspect <path.ipa>`.")
        }
        let inspector = IPAInspector(
            runner: services.runner, tmp: services.home.tmp, registry: registry, limits: limits, log: services.log)
        do {
            return .result(command, try await inspector.inspect(path: path))
        } catch {
            return .from(error, command: command)
        }
    }
}
