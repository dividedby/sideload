import CryptoKit
import Darwin
import Foundation

/// Opens an untrusted IPA and reports what is in it, without installing, signing or contacting anything.
///
/// The archive is checked in three steps. The central directory is read and refused if any entry is unsafe
/// (`ZipListing`). `ditto` then unpacks it into a 0700 folder under `$SIDELOAD_HOME/tmp` while the folder's size is
/// watched, and the result is walked with `lstat` (`ExtractedTree`) before any file in it is opened. Binaries are
/// read by Apple's own tools (`BinaryTools`). The folder is removed on every path, including an interrupt
/// (`ScratchRegistry`).
struct IPAInspector: Sendable {
    let runner: any Runner
    let tmp: String
    let registry: ScratchRegistry
    let limits: InspectLimits
    let log: @Sendable (String) -> Void

    private var tools: BinaryTools { BinaryTools(runner: runner, limits: limits) }

    /// The IPA as it was when it was opened: listed, hashed, and its identity (device, inode, size, mtime) kept so
    /// the path can be checked again after the extraction.
    struct OpenedIPA {
        var path: String
        var before: stat
        var size: UInt64
        var sha256: String
    }

    /// What `inspect(path:keeping:)` leaves for a caller that works on the unpacked app (`sign`).
    struct Unpacked {
        var report: [String: JSONValue]
        /// `<scratch>/x/Payload/<Name>.app`, inside the caller's scratch folder.
        var appDir: String
        /// The SHA-256 of the archive that was listed and unpacked.
        var sha256: String
    }

    /// The same checks and report as `inspect(path:)`, but the archive is unpacked into the caller's `scratch` and
    /// left there, so `sign` works on exactly the tree that was inspected. The caller removes the scratch folder.
    func inspect(path rawPath: String, keeping scratch: ScratchDirectory) async throws -> Unpacked {
        let ipa = try openIPA(rawPath)
        let analysis = try await analyze(ipa: ipa, scratch: scratch)
        return Unpacked(report: analysis.report, appDir: analysis.appDir, sha256: ipa.sha256)
    }

    /// Opens without following a symlink, requires a regular file within the size limit, reads the central
    /// directory (`IPA_UNSAFE_ENTRY` and friends) and streams the SHA-256.
    private func openIPA(_ rawPath: String) throws -> OpenedIPA {
        let path = resolvePath(rawPath)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SideloadError(
                "IPA_NOT_FOUND", "No readable IPA file at that path (a symbolic link is not followed).",
                fix: "Pass the real path of an .ipa file.")
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw SideloadError("IPA_NOT_FOUND", "The path is not a regular file.", fix: "Pass the path of an .ipa file.")
        }
        let size = UInt64(max(before.st_size, 0))
        if size > limits.maxFileBytes {
            throw SideloadError("IPA_TOO_LARGE", "The file is larger than the \(limits.maxFileBytes >> 30) GiB limit.", fix: "Inspect a normal IPA.")
        }

        _ = try ZipListing.read(fd: fd, fileSize: size, limits: limits)
        return OpenedIPA(path: path, before: before, size: size, sha256: try Self.sha256(fd: fd, size: size))
    }

    func inspect(path rawPath: String) async throws -> [String: JSONValue] {
        let ipa = try openIPA(rawPath)
        let scratch = try ScratchDirectory.create(under: tmp, registry: registry)
        let outcome: Result<[String: JSONValue], any Error>
        do {
            outcome = .success(try await analyze(ipa: ipa, scratch: scratch).report)
        } catch {
            outcome = .failure(error)
        }
        let removed = scratch.remove()
        let leftover = CanaryCommand.warning(
            "SCRATCH_NOT_REMOVED", "The scratch folder under $SIDELOAD_HOME/tmp could not be removed.",
            "Delete the inspect-* folders in $SIDELOAD_HOME/tmp.")
        if !removed { log("inspect: the scratch folder could not be removed") }
        switch outcome {
        case .success(var data):
            if !removed { data["warnings"] = .array((data["warnings"]?.items ?? []) + [leftover]) }
            return data
        case .failure(let error):
            // The failure stays the answer; the leftover folder is reported next to it.
            throw removed ? error : Self.carrying(leftover, error)
        }
    }

    /// `error` with the leftover-folder warning attached. A `SideloadError` keeps its code and message; any other
    /// error becomes `INTERNAL_ERROR` with a fixed message, because its description could quote the archive.
    static func carrying(_ warning: JSONValue, _ error: any Error) -> SideloadError {
        let known =
            (error as? SideloadError)
            ?? SideloadError("INTERNAL_ERROR", "inspect failed unexpectedly.", fix: "This is a bug in sideload; re-run and report the code.")
        var data = known.data
        data["warnings"] = .array((data["warnings"]?.items ?? []) + [warning])
        return SideloadError(known.code, known.message, fix: known.fix, data: data)
    }

    // MARK: analysis

    private func analyze(ipa: OpenedIPA, scratch: ScratchDirectory) async throws -> (report: [String: JSONValue], appDir: String) {
        let (path, before, size, sha256) = (ipa.path, ipa.before, ipa.size, ipa.sha256)
        var warnings: [JSONValue] = []
        let dest = scratch.path + "/x"
        guard mkdir(dest, 0o700) == 0 else { throw ioError("mkdir") }

        log("inspect: unpacking")
        try await extract(ipa: path, into: dest)
        if registry.isClosed { throw SideloadError("CANCELLED", "inspect was interrupted.", fix: "Re-run the command.") }

        // The listing and the hash describe the file that was opened; make sure the path still names it.
        var after = stat()
        guard stat(path, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else {
            throw SideloadError("IPA_CHANGED", "The file changed while it was being inspected.", fix: "Re-run the command.")
        }
        let facts = try ExtractedTree.verify(root: dest, limits: limits)

        let payload = dest + "/Payload"
        let apps = (ExtractedTree.children(of: payload) ?? []).filter { $0.hasSuffix(".app") && Self.isDirectory(payload + "/" + $0) }
        guard !apps.isEmpty else {
            throw SideloadError("IPA_NO_APP", "The IPA has no Payload/<name>.app folder.", fix: "Inspect an iOS or tvOS app archive.")
        }
        guard apps.count == 1 else {
            throw SideloadError("IPA_MULTIPLE_APPS", "The IPA holds \(apps.count) apps under Payload/.", fix: "Inspect an archive with exactly one app.")
        }
        let appDir = payload + "/" + apps[0]

        log("inspect: reading the app")
        let info = try bundleInfo(dir: appDir, role: "app")
        let executable = appDir + "/" + info.executable
        let architectures = try await tools.architectures(of: executable, role: "app")
        let signature = try await describe(bundle: appDir, label: "app", warnings: &warnings)
        let build = await tools.buildVersion(of: executable)
        if build == nil {
            warnings.append(CanaryCommand.warning("BUILD_VERSION_UNREADABLE", "vtool could not read the app's platform and minimum OS; the Info.plist values are used.", "Run `sideload doctor`."))
        }

        let minOS = build?.minOS ?? Self.string(info.plist, "MinimumOSVersion")
        let platform = build?.platform ?? Self.plistPlatform(info.plist)
        let app: [String: JSONValue] = [
            "bundleId": .string(info.bundleId),
            "name": Self.optional(Self.string(info.plist, "CFBundleDisplayName") ?? Self.string(info.plist, "CFBundleName")),
            "version": Self.optional(Self.string(info.plist, "CFBundleShortVersionString")),
            "build": Self.optional(Self.string(info.plist, "CFBundleVersion")),
            "minOS": Self.optional(minOS),
            "platform": Self.optional(platform),
            "deviceFamily": Self.deviceFamily(info.plist),
            "executable": .string(BinaryTools.cut(info.executable)),
            "architectures": .array(architectures.map { .string($0) }),
            "signed": signature.signed, "entitlements": signature.entitlements,
            "appGroups": .array(signature.appGroups.map { .string($0) }),
        ]

        // PlugIns/*.appex
        var extensions: [JSONValue] = []
        var groups = Set(signature.appGroups)
        let appexNames = (ExtractedTree.children(of: appDir + "/PlugIns") ?? []).filter { $0.hasSuffix(".appex") }
        if appexNames.count > limits.maxExtensions {
            warnings.append(CanaryCommand.warning("EXTENSIONS_TRUNCATED", "Only the first \(limits.maxExtensions) of \(appexNames.count) extensions are reported.", "Review the IPA's PlugIns folder by hand."))
        }
        for name in appexNames.prefix(limits.maxExtensions) {
            let dir = appDir + "/PlugIns/" + name
            guard Self.isDirectory(dir) else {
                warnings.append(CanaryCommand.warning("EXTENSION_NOT_A_BUNDLE", "A PlugIns entry named *.appex is not a folder; it was skipped.", "Review the IPA by hand."))
                continue
            }
            log("inspect: reading an extension")
            let extensionInfo = try bundleInfo(dir: dir, role: "extension")
            let archs = try await tools.architectures(of: dir + "/" + extensionInfo.executable, role: "extension")
            let sig = try await describe(bundle: dir, label: "extension", warnings: &warnings)
            groups.formUnion(sig.appGroups)
            var point: String?
            if let ns = extensionInfo.plist["NSExtension"] as? [String: Any] { point = Self.string(ns, "NSExtensionPointIdentifier") }
            extensions.append([
                "path": .string(BinaryTools.cut("PlugIns/" + name)), "bundleId": .string(extensionInfo.bundleId),
                "extensionPoint": Self.optional(point), "executable": .string(BinaryTools.cut(extensionInfo.executable)),
                "architectures": .array(archs.map { .string($0) }), "signed": sig.signed, "entitlements": sig.entitlements,
                "appGroups": .array(sig.appGroups.map { .string($0) }),
            ])
        }

        let frameworks = (ExtractedTree.children(of: appDir + "/Frameworks") ?? []).filter { $0.hasSuffix(".framework") }.count
        let watchApps = (ExtractedTree.children(of: appDir + "/Watch") ?? []).filter { $0.hasSuffix(".app") }.count

        let report: [String: JSONValue] = [
            "ipa": ["path": .string(path), "sizeBytes": .number(Double(size)), "sha256": .string(sha256)],
            "app": .object(app),
            "extensions": .array(extensions),
            "appGroups": .array(groups.sorted().map { .string($0) }),
            "hasEmbeddedProvision": .bool(Self.isFile(appDir + "/embedded.mobileprovision")),
            "otherCode": [
                "frameworks": .number(Double(frameworks)), "dylibs": .number(Double(facts.dylibs)),
                "watchApps": .number(Double(watchApps)),
            ],
            "warnings": .array(warnings),
        ]
        return (report, appDir)
    }

    // MARK: extraction

    private enum Raced { case ditto(RunResult), overBudget, stopped }

    private func extract(ipa: String, into dest: String) async throws {
        let spec = CommandSpec(
            executable: "/usr/bin/ditto", args: ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", ipa, dest],
            timeout: limits.extractTimeout, maxOutputBytes: 64 * 1024)
        let (result, overBudget) = await withTaskGroup(of: Raced.self) { group in
            group.addTask { .ditto(await runner.run(spec)) }
            // A header can lie about sizes, so the folder is measured while ditto writes; passing the cap stops it.
            group.addTask {
                while true {
                    do { try await Task.sleep(for: limits.monitorInterval) } catch { return .stopped }
                    if ExtractedTree.measure(root: dest, cap: limits.maxTotalBytes, maxEntries: limits.maxEntries * 2) > limits.maxTotalBytes {
                        return .overBudget
                    }
                }
            }
            var result: RunResult?
            var over = false
            for await item in group {
                switch item {
                case .ditto(let r):
                    result = r
                    group.cancelAll()
                case .overBudget:
                    over = true
                    group.cancelAll()
                case .stopped: break
                }
            }
            return (result, over)
        }
        if overBudget {
            throw SideloadError("IPA_TOO_LARGE", "Unpacking was stopped: the data written passed the size limit.", fix: "Do not use this IPA.")
        }
        guard let result else { throw SideloadError("CANCELLED", "inspect was interrupted.", fix: "Re-run the command.") }
        if result.spawnError == "INTERRUPTED" || (result.code == nil && result.signal != nil && Task.isCancelled) {
            throw SideloadError("CANCELLED", "inspect was interrupted.", fix: "Re-run the command.")
        }
        if let spawnError = result.spawnError {
            throw SideloadError("TOOL_FAILED", "ditto could not be started (\(spawnError)).", fix: "Run `sideload doctor`.")
        }
        if result.timedOut {
            throw SideloadError("IPA_EXTRACT_TIMEOUT", "Unpacking took longer than \(limits.extractTimeout.components.seconds) s and was stopped.", fix: "Do not use this IPA.")
        }
        guard result.code == 0 else {
            throw SideloadError("IPA_EXTRACT_FAILED", "ditto could not unpack the archive (status \(result.code.map(String.init) ?? "unknown")).", fix: "The IPA may be damaged; download it again.")
        }
    }

    // MARK: bundles

    struct BundleInfo {
        var plist: [String: Any]
        var bundleId: String
        var executable: String
    }

    /// Reads `<dir>/Info.plist`, requires a bundle identifier and a plain executable name, and checks that the
    /// executable is a regular file inside the bundle. Messages never contain file contents.
    private func bundleInfo(dir: String, role: String) throws -> BundleInfo {
        let plist = try Self.readPlist(dir + "/Info.plist", role: role, maxBytes: limits.maxPlistBytes)
        guard let bundleId = plist["CFBundleIdentifier"] as? String, !bundleId.isEmpty else {
            throw SideloadError("INFO_PLIST_INVALID", "The \(role)'s Info.plist has no CFBundleIdentifier.", fix: "Do not use this IPA.")
        }
        guard let executable = plist["CFBundleExecutable"] as? String, Self.isPlainName(executable) else {
            throw SideloadError(
                "IPA_EXECUTABLE_INVALID", "The \(role)'s CFBundleExecutable is missing or is not a plain file name.",
                fix: "Do not use this IPA; the executable name must not contain a path.")
        }
        guard Self.isFile(dir + "/" + executable) else {
            throw SideloadError("IPA_EXECUTABLE_INVALID", "The \(role)'s executable is not a regular file in the bundle.", fix: "Do not use this IPA.")
        }
        return BundleInfo(plist: plist, bundleId: BinaryTools.cut(bundleId), executable: executable)
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".."
            && !name.utf8.contains(where: { $0 == 0x2f || $0 == 0 || $0 < 0x20 })
    }

    static func readPlist(_ path: String, role: String, maxBytes: Int) throws -> [String: Any] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw SideloadError("INFO_PLIST_MISSING", "The \(role) has no readable Info.plist.", fix: "Do not use this IPA.")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw SideloadError("INFO_PLIST_MISSING", "The \(role) has no readable Info.plist.", fix: "Do not use this IPA.")
        }
        guard st.st_size <= maxBytes else {
            throw SideloadError("INFO_PLIST_TOO_LARGE", "The \(role)'s Info.plist is larger than \(maxBytes >> 20) MiB.", fix: "Do not use this IPA.")
        }
        let length = Int(st.st_size)
        var bytes = [UInt8](repeating: 0, count: length)
        var done = 0
        while done < length {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, length - done) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if n == 0 { break }
            done += n
        }
        let data = Data(bytes[0..<done])
        // The parser's own error text can quote the document, so it is dropped.
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = object as? [String: Any]
        else {
            throw SideloadError("INFO_PLIST_INVALID", "The \(role)'s Info.plist is not a property-list dictionary.", fix: "Do not use this IPA.")
        }
        return dictionary
    }

    // MARK: report pieces

    private struct Described {
        var signed: JSONValue
        var entitlements: JSONValue
        var appGroups: [String]
    }

    private func describe(bundle: String, label: String, warnings: inout [JSONValue]) async throws -> Described {
        switch await tools.signature(of: bundle) {
        case .unsigned:
            return Described(signed: false, entitlements: .null, appGroups: [])
        case .signed(let entitlements, let warning):
            if let warning {
                warnings.append(CanaryCommand.warning(warning, "The \(label)'s entitlements could not be read in full.", "Review the IPA with `codesign -d --entitlements - --xml` by hand."))
            }
            return Described(signed: true, entitlements: entitlements ?? .null, appGroups: BinaryTools.appGroups(entitlements))
        case .unknown(let why):
            if why.hasSuffix("was interrupted") { throw SideloadError("CANCELLED", "inspect was interrupted.", fix: "Re-run the command.") }
            warnings.append(CanaryCommand.warning("CODESIGN_FAILED", "\(why) for the \(label).", "Review the IPA with `codesign -dvv` by hand."))
            return Described(signed: .null, entitlements: .null, appGroups: [])
        }
    }

    static func string(_ dictionary: [String: Any], _ key: String) -> String? {
        (dictionary[key] as? String).map(BinaryTools.cut)
    }

    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    static func deviceFamily(_ plist: [String: Any]) -> JSONValue {
        guard let list = plist["UIDeviceFamily"] as? [Any] else { return .null }
        return .array(list.prefix(8).compactMap { ($0 as? NSNumber).map { .number($0.doubleValue) } })
    }

    /// `CFBundleSupportedPlatforms` (`iPhoneOS`, `AppleTVOS`) in vtool's spelling, for when vtool said nothing.
    static func plistPlatform(_ plist: [String: Any]) -> String? {
        guard let first = (plist["CFBundleSupportedPlatforms"] as? [Any])?.first as? String else { return nil }
        let lower = BinaryTools.cut(first).lowercased()
        return lower == "iphoneos" ? "ios" : lower == "appletvos" ? "tvos" : lower
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private static func isFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    private static func sha256(fd: Int32, size: UInt64) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: UInt64 = 0
        while offset < size {
            let want = Int(min(UInt64(buffer.count), size - offset))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, want, off_t(offset)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ioError("read")
            }
            if n == 0 { throw SideloadError("IPA_CHANGED", "The file changed while it was being inspected.", fix: "Re-run the command.") }
            hasher.update(data: buffer[0..<n])
            offset += UInt64(n)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONValue {
    var items: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
