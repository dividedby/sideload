import Foundation

private let timeout = Duration.seconds(20)

private let fixInstall =
    "Install Xcode 27 from the App Store, then select it with xcode-select -s /Applications/Xcode.app (owner action, needs root)."

/// First capture group of `pattern` (multi-line anchors) in `text`.
func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
        let r = Range(m.range(at: 1), in: text)
    else { return nil }
    return String(text[r])
}

/// xcodebuild >= 27, a selected developer directory (xcode-select), and devicectl present.
public struct XcodeCheck: Check {
    public let id = "xcode"

    public init() {}

    struct Version: Equatable {
        var version: String
        var build: String?
        var major: Int

        var label: String { version + (build.map { " (\($0))" } ?? "") }
    }

    static func parseVersion(_ text: String) -> Version? {
        guard let version = firstMatch(#"^Xcode\s+([0-9][0-9.]*)"#, in: text) else { return nil }
        let digits = version.prefix { $0.isASCII && $0.isNumber }
        return Version(
            version: version, build: firstMatch(#"^Build version\s+(\S+)"#, in: text), major: Int(digits) ?? 0)
    }

    /// `27.0 (27A266a)`: the label of `xcodebuild -version`, or nil when it cannot be read (the canary log
    /// records it).
    public static func versionLabel(runner: any Runner) async -> String? {
        let ver = await runner.run(CommandSpec(executable: "xcodebuild", args: ["-version"], timeout: timeout))
        guard ver.code == 0 else { return nil }
        return parseVersion(ver.stdout)?.label
    }

    public func run(_ services: Services) async throws -> [CheckResult] {
        let runner = services.runner
        let ver = await runner.run(CommandSpec(executable: "xcodebuild", args: ["-version"], timeout: timeout))
        guard ver.code == 0, let parsed = Self.parseVersion(ver.stdout) else {
            return [fail("xcodebuild is not available.")]
        }
        let sel = await runner.run(CommandSpec(executable: "xcode-select", args: ["-p"], timeout: timeout))
        if sel.code != 0 || sel.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [fail("No developer directory selected (xcode-select -p failed).")]
        }
        let dev = await runner.run(CommandSpec(executable: "xcrun", args: ["--find", "devicectl"], timeout: timeout))
        if dev.code != 0 {
            return [fail("devicectl was not found in the selected Xcode.")]
        }
        if parsed.major < 27 {
            return [
                CheckResult(
                    id: id, severity: .warn, message: "Xcode \(parsed.label) found; Xcode 27+ is expected.",
                    fix: "Update Xcode to 27 or later.")
            ]
        }
        return [
            CheckResult(
                id: id, severity: .ok, message: "Xcode \(parsed.label), developer directory and devicectl present.")
        ]
    }

    private func fail(_ message: String) -> CheckResult {
        CheckResult(id: id, severity: .fail, message: message, fix: fixInstall)
    }
}

/// The tools sideload needs resolve through xcrun (Xcode provides them). The standalone Command Line Tools
/// package is optional, so its absence is info, never fail.
public struct CLTCheck: Check {
    public static let tools = ["codesign", "clang", "swiftc"]
    private static let package = "com.apple.pkg.CLTools_Executables"

    public let id = "clt"

    public init() {}

    public func run(_ services: Services) async throws -> [CheckResult] {
        var missing: [String] = []
        for tool in Self.tools {
            let res = await services.runner.run(CommandSpec(executable: "xcrun", args: ["--find", tool], timeout: timeout))
            if res.code != 0 || res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append(tool)
            }
        }
        if !missing.isEmpty {
            return [
                CheckResult(
                    id: id, severity: .fail,
                    message: "Command-line tools not found via xcrun: \(missing.joined(separator: ", ")).",
                    fix: fixInstall)
            ]
        }
        let pkg = await services.runner.run(
            CommandSpec(executable: "/usr/sbin/pkgutil", args: ["--pkg-info", Self.package], timeout: timeout))
        let tools = Self.tools.joined(separator: ", ")
        if pkg.code == 0, firstMatch(#"^version:\s*(\S+)"#, in: pkg.stdout) != nil {
            return [
                CheckResult(
                    id: id, severity: .ok,
                    message: "\(tools) resolve via xcrun; standalone Command Line Tools package installed.")
            ]
        }
        return [
            CheckResult(
                id: id, severity: .info,
                message:
                    "\(tools) resolve via xcrun (provided by Xcode); standalone Command Line Tools package not installed, which is fine."
            )
        ]
    }
}
