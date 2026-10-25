import Darwin
import Foundation

/// Signs an unpacked app with one identity (design section 18, `sign` step 5), through the Runner: argument arrays,
/// a timeout on every call, nothing from the tools' output echoed. The free path passes the pinned certificate's SHA-1
/// as `identity`, never a name; `"-"` (ad hoc) is for tests only.
///
/// Order: every nested framework and dylib, innermost first, with `codesign -f -s <identity> --timestamp=none`; then
/// the app itself with `--entitlements <plist> --generate-entitlement-der`; then `codesign --verify --strict --deep`.
struct BundleSigner: Sendable {
    let runner: any Runner
    let identity: String
    /// A signing call can wait for the owner to answer a keychain prompt.
    var signTimeout: Duration = .seconds(300)
    var verifyTimeout: Duration = .seconds(120)

    static let codesign = "/usr/bin/codesign"

    /// Nested code `codesign` must seal before the app: `*.framework` folders and `*.dylib` files anywhere under
    /// `app` (never followed through a link), sorted deepest first so a library inside a framework goes before it.
    static func nestedCode(in app: String, limits: InspectLimits = InspectLimits()) -> [String] {
        var found: [(path: String, depth: Int)] = []
        var pending: [(path: String, depth: Int)] = [(app, 0)]
        var entries = 0
        while let (dir, depth) = pending.popLast() {
            guard depth < limits.maxTreeDepth else { continue }
            for name in ExtractedTree.children(of: dir) ?? [] {
                entries += 1
                if entries > limits.maxEntries * 2 { return sorted(found) }
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let lower = name.lowercased()
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    if lower.hasSuffix(".framework") { found.append((path, depth + 1)) }
                    pending.append((path, depth + 1))
                case S_IFREG:
                    if lower.hasSuffix(".dylib") { found.append((path, depth + 1)) }
                default: break
                }
            }
        }
        return sorted(found)
    }

    /// Nested code the signer does not handle, as paths relative to `app` (sorted): a nested `*.app`, `*.xpc`, `*.appex`
    /// or `*.kext`, a `*.bundle` that has an executable (its Info.plist names a regular file), and any loose Mach-O
    /// file (by magic bytes) that is not the app's own executable and not a `*.dylib`; inside a `*.framework` the only
    /// other Mach-O allowed is the framework's own `CFBundleExecutable`.
    /// Such code would keep its foreign signature, so `sign` refuses it instead of signing it. Nothing inside a refused
    /// bundle is looked at further, and inside a framework only its own `CFBundleExecutable` (and any `*.dylib`) is allowed to be Mach-O. `lstat` only; a link is never followed.
    static func unsupportedNestedCode(in app: String, limits: InspectLimits = InspectLimits()) -> [String] {
        let mainExecutable = (try? IPAInspector.readPlist(app + "/Info.plist", role: "app", maxBytes: limits.maxPlistBytes))
            .flatMap { $0["CFBundleExecutable"] as? String }
        var found: [String] = []
        var pending: [(path: String, depth: Int, framework: String?)] = [(app, 0, nil)]
        var frameworkExecutables: [String: String?] = [:]
        var entries = 0
        let refusedSuffixes = [".app", ".xpc", ".appex", ".kext"]
        while let (dir, depth, framework) = pending.popLast() {
            guard depth < limits.maxTreeDepth else { continue }
            for name in ExtractedTree.children(of: dir) ?? [] {
                entries += 1
                if entries > limits.maxEntries * 2 { return found.sorted() }
                let path = dir + "/" + name
                let relative = String(path.dropFirst(app.count + 1))
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let lower = name.lowercased()
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    if refusedSuffixes.contains(where: lower.hasSuffix) {
                        found.append(relative)
                    } else if lower.hasSuffix(".bundle"), hasExecutable(path, limits: limits) {
                        found.append(relative)
                    } else {
                        pending.append((path, depth + 1, lower.hasSuffix(".framework") ? path : framework))
                    }
                case S_IFREG:
                    if dir == app, name == mainExecutable { continue }
                    if lower.hasSuffix(".dylib") { continue }
                    guard isMachO(path) else { continue }
                    // Inside a framework only its own binary is sealed by signing the framework.
                    if let framework {
                        if frameworkExecutables[framework] == nil {
                            frameworkExecutables[framework] = executableName(of: framework, limits: limits)
                        }
                        if let own = frameworkExecutables[framework] ?? nil, path == framework + "/" + own { continue }
                    }
                    found.append(relative)
                default: break
                }
            }
        }
        return found.sorted()
    }

    /// The bundle's `CFBundleExecutable` when its Info.plist names a plain file name.
    private static func executableName(of bundle: String, limits: InspectLimits) -> String? {
        guard let plist = try? IPAInspector.readPlist(bundle + "/Info.plist", role: "bundle", maxBytes: limits.maxPlistBytes),
            let name = plist["CFBundleExecutable"] as? String, IPAInspector.isPlainName(name)
        else { return nil }
        return name
    }

    /// A bundle whose Info.plist names a `CFBundleExecutable` that is a regular file inside it.
    private static func hasExecutable(_ bundle: String, limits: InspectLimits) -> Bool {
        guard let name = executableName(of: bundle, limits: limits) else { return false }
        var st = stat()
        return lstat(bundle + "/" + name, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    /// The first four bytes are a Mach-O or universal-binary magic number (either byte order).
    static func isMachO(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var magic = [UInt8](repeating: 0, count: 4)
        guard read(fd, &magic, 4) == 4 else { return false }
        let value = magic.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca, 0xcafe_babf, 0xbfba_feca].contains(value)
    }

    private static func sorted(_ found: [(path: String, depth: Int)]) -> [String] {
        found.sorted { ($1.depth, $0.path) < ($0.depth, $1.path) }.map(\.path)
    }

    /// The argv of each step, in order (what `sign` runs).
    func plan(app: String, entitlements: String, nested: [String]) -> [[String]] {
        nested.map { ["-f", "-s", identity, "--timestamp=none", $0] }
            + [
                [
                    "-f", "-s", identity, "--timestamp=none", "--entitlements", entitlements, "--generate-entitlement-der",
                    app,
                ],
                ["--verify", "--strict", "--deep", app],
            ]
    }

    func sign(app: String, entitlements: String) async throws {
        // Code this signer does not handle would keep its foreign signature: refuse before signing anything.
        let unsupported = Self.unsupportedNestedCode(in: app)
        if let first = unsupported.first {
            throw SideloadError(
                "NESTED_CODE_UNSUPPORTED",
                "The app contains nested code sign does not handle (\(BinaryTools.cut(first))\(unsupported.count > 1 ? " and \(unsupported.count - 1) more" : "")). Nothing was signed.",
                fix: "Do not use this IPA; only frameworks and dylibs can be re-signed.",
                data: ["nestedCode": .array(unsupported.prefix(20).map { .string(BinaryTools.cut($0)) })])
        }
        let nested = Self.nestedCode(in: app)
        let steps = plan(app: app, entitlements: entitlements, nested: nested)
        for (index, args) in steps.enumerated() {
            let isVerify = args.first == "--verify"
            let result = await runner.run(
                CommandSpec(
                    executable: Self.codesign, args: args, timeout: isVerify ? verifyTimeout : signTimeout,
                    maxOutputBytes: 1 << 20))
            let isApp = index == steps.count - 2
            if let failure = Self.failure(
                result, step: isVerify ? "verify" : isApp ? "app" : "nested",
                label: isVerify ? "verifying the signed app" : isApp ? "signing the app" : "signing a nested framework or library")
            {
                throw failure
            }
        }
    }

    /// Maps a failed `codesign` call to an error that names the step and the exit status, never the tool's text.
    /// Two stderr phrases that need a different fix are recognised by name.
    static func failure(_ result: RunResult, step: String, label: String) -> SideloadError? {
        if let spawn = result.spawnError {
            if spawn == "INTERRUPTED" { return SideloadError("CANCELLED", "sign was interrupted.", fix: "Re-run the command.") }
            return SideloadError(
                "TOOL_FAILED", "codesign could not be started (\(spawn)).", fix: "Run `sideload doctor`.")
        }
        if result.timedOut || result.overflow {
            return SideloadError(
                "CODESIGN_FAILED",
                "codesign \(result.timedOut ? "timed out" : "printed more output than the limit") while \(label).",
                fix: "A keychain prompt may be waiting for the owner; unlock the login keychain and retry.",
                data: ["step": .string(step)])
        }
        guard let code = result.code else {
            return SideloadError(
                "CODESIGN_FAILED", "codesign was killed while \(label).", fix: "Retry.", data: ["step": .string(step)])
        }
        if code == 0 { return nil }
        let text = result.stderr
        if text.contains("errSecInternalComponent") || text.contains("User interaction is not allowed") {
            return SideloadError(
                "KEYCHAIN_LOCKED", "codesign could not use the signing key; the login keychain is locked or the key prompt was denied.",
                fix: "Unlock the login keychain, then retry and choose Always Allow / Allow when the key prompt appears (owner action).",
                data: ["step": .string(step)])
        }
        if text.contains("no identity found") {
            return SideloadError(
                "FREE_IDENTITY_MISSING", "codesign found no identity with the pinned fingerprint.",
                fix: "Check Xcode > Settings > Accounts > Manage Certificates and the login keychain (owner action).",
                data: ["step": .string(step)])
        }
        return SideloadError(
            "CODESIGN_FAILED", "codesign failed (status \(code)) while \(label).",
            fix: "Run `sideload inspect` on the IPA; if it repeats, report the step.", data: ["step": .string(step)])
    }
}
