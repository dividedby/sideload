import Foundation

/// What Apple's `lipo`, `vtool` and `codesign` say about one binary, run through the `Runner` (argument arrays, a
/// timeout and an output cap on every call). Tool output is parsed, never echoed: a failure names the tool and the
/// exit status, nothing from stdout or stderr.
struct BinaryTools: Sendable {
    let runner: any Runner
    let limits: InspectLimits

    static let lipo = "/usr/bin/lipo"
    static let vtool = "/usr/bin/vtool"
    static let codesign = "/usr/bin/codesign"

    enum Outcome: Equatable {
        case ok(String)
        case exited(Int32, stderr: String)
        case failed(String)
    }

    func run(_ executable: String, _ args: [String]) async -> Outcome {
        let result = await runner.run(
            CommandSpec(executable: executable, args: args, timeout: limits.toolTimeout, maxOutputBytes: limits.maxToolOutputBytes))
        if let spawnError = result.spawnError {
            return .failed(spawnError == "INTERRUPTED" ? "was interrupted" : "could not be started (\(spawnError))")
        }
        if result.timedOut { return .failed("timed out") }
        if result.overflow { return .failed("printed more output than the limit") }
        guard let code = result.code else { return .failed("was killed") }
        return code == 0 ? .ok(result.stdout) : .exited(code, stderr: result.stderr)
    }

    // MARK: lipo

    /// Architectures of a Mach-O file (thin or universal). A file that is not Mach-O is `IPA_NOT_MACHO`.
    func architectures(of executable: String, role: String) async throws -> [String] {
        switch await run(Self.lipo, ["-archs", executable]) {
        case .ok(let out):
            let names = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard !names.isEmpty, names.count <= 16,
                names.allSatisfy({ $0.count <= 24 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") } })
            else { throw toolFailure("lipo", "printed an architecture list inspect cannot read") }
            return names
        case .exited:
            throw SideloadError(
                "IPA_NOT_MACHO", "The \(role) executable is not a Mach-O file.", fix: "Do not use this IPA; it is not a normal app archive.")
        case .failed(let why):
            throw toolFailure("lipo", why)
        }
    }

    // MARK: vtool

    struct BuildVersion: Equatable {
        var platform: String
        var minOS: String
    }

    /// The first slice's platform and minimum OS, or nil when `vtool` could not say.
    func buildVersion(of executable: String) async -> BuildVersion? {
        guard case .ok(let out) = await run(Self.vtool, ["-show-build", executable]) else { return nil }
        return Self.parseBuildVersion(out)
    }

    static func parseBuildVersion(_ text: String) -> BuildVersion? {
        enum Kind { case build, versionMin }
        var kind: Kind?
        var platform: String?
        var minOS: String?
        func finished() -> BuildVersion? {
            guard let platform, let minOS else { return nil }
            return BuildVersion(platform: platform.lowercased(), minOS: minOS)
        }
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]), value = String(parts[1])
            if key == "cmd" {
                if let found = finished() { return found }
                platform = nil
                minOS = nil
                kind = nil
                if value == "LC_BUILD_VERSION" {
                    kind = .build
                } else if value.hasPrefix("LC_VERSION_MIN_") {
                    kind = .versionMin
                    platform = String(value.dropFirst("LC_VERSION_MIN_".count))
                        .replacingOccurrences(of: "IPHONEOS", with: "IOS").replacingOccurrences(of: "MACOSX", with: "MACOS")
                }
            } else if kind == .build, key == "platform", isToken(value) {
                platform = value
            } else if key == "minos" || (kind == .versionMin && key == "version"), isVersion(value) {
                minOS = value
            }
        }
        return finished()
    }

    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }

    private static func isVersion(_ s: String) -> Bool {
        s.wholeMatch(of: /[0-9]{1,5}(\.[0-9]{1,5}){0,2}/) != nil
    }

    // MARK: codesign

    enum Signature {
        case unsigned
        case signed(entitlements: JSONValue?, warning: String?)
        case unknown(String)
    }

    /// `codesign -d --entitlements - --xml <bundle>`: an unsigned bundle is `.unsigned`; a signed one without an
    /// entitlements blob has `{}`; an entitlements document that cannot be read is `.signed` with a warning code.
    func signature(of bundle: String) async -> Signature {
        switch await run(Self.codesign, ["-d", "--entitlements", "-", "--xml", bundle]) {
        case .ok(let out):
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .signed(entitlements: [:], warning: nil) }
            guard let data = trimmed.data(using: .utf8),
                let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                let dictionary = plist as? [String: Any]
            else { return .signed(entitlements: nil, warning: "ENTITLEMENTS_UNREADABLE") }
            var budget = 4000
            return .signed(entitlements: Self.json(dictionary, depth: 0, budget: &budget), warning: budget < 0 ? "ENTITLEMENTS_TRUNCATED" : nil)
        case .exited(let code, let stderr):
            // codesign prints "<path>: code object is not signed at all" and exits 1. Matching the whole line with the
            // path we passed (not a substring) keeps a path or an error that merely contains the words from counting.
            if code == 1, stderr.split(separator: "\n", omittingEmptySubsequences: true).contains(where: { $0 == "\(bundle): code object is not signed at all" }) {
                return .unsigned
            }
            return .unknown("codesign could not read the signature")
        case .failed(let why):
            return .unknown("codesign \(why)")
        }
    }

    /// A bounded copy of a property list: depth 8, 4000 nodes, 256 elements per array, strings cut to 256 characters.
    /// A budget that goes negative means something was left out.
    static func json(_ value: Any, depth: Int, budget: inout Int) -> JSONValue {
        budget -= 1
        if budget < 0 || depth > 8 { return .null }
        if let string = value as? String { return .string(cut(string)) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let array = value as? [Any] {
            var items: [JSONValue] = []
            for element in array.prefix(256) { items.append(json(element, depth: depth + 1, budget: &budget)) }
            if array.count > 256 { budget = min(budget, -1) }
            return .array(items)
        }
        if let dictionary = value as? [String: Any] {
            var object: [String: JSONValue] = [:]
            for key in dictionary.keys.sorted().prefix(256) { object[cut(key)] = json(dictionary[key]!, depth: depth + 1, budget: &budget) }
            if dictionary.count > 256 { budget = min(budget, -1) }
            return .object(object)
        }
        if value is Data { return .string("<data>") }
        if value is Date { return .string("<date>") }
        return .null
    }

    static func cut(_ s: String) -> String { String(s.prefix(256)) }

    static func appGroups(_ entitlements: JSONValue?) -> [String] {
        guard case .object(let object)? = entitlements, case .array(let items)? = object["com.apple.security.application-groups"] else { return [] }
        return items.compactMap { if case .string(let s) = $0 { s } else { nil } }.prefix(100).map { $0 }
    }

    private func toolFailure(_ tool: String, _ why: String) -> SideloadError {
        if why == "was interrupted" { return SideloadError("CANCELLED", "inspect was interrupted.", fix: "Re-run the command.") }
        return SideloadError(
            "TOOL_FAILED", "\(tool) \(why).", fix: "Run `sideload doctor`; the Xcode command-line tools must be installed.")
    }
}
