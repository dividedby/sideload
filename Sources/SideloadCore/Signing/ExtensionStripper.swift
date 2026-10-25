import Darwin
import Foundation

/// One bundle `sign` removed from an app: an extension, or a watch app. Strings come from the archive and are cut.
struct StrippedBundle: Equatable, Sendable {
    /// Relative to the app bundle, e.g. `PlugIns/Widget.appex`.
    var path: String
    var bundleId: String?
    var extensionPoint: String?
    var entitlementKeys: [String]
    var appGroups: [String]

    var json: JSONValue {
        .object([
            "path": .string(path), "bundleId": bundleId.map(JSONValue.string) ?? .null,
            "extensionPoint": extensionPoint.map(JSONValue.string) ?? .null,
            "entitlementKeys": .array(entitlementKeys.map { .string($0) }),
            "appGroups": .array(appGroups.map { .string($0) }),
        ])
    }
}

struct StripOutcome: Sendable {
    var stripped: [StrippedBundle]
    var warnings: [JSONValue]
}

/// Removes every app extension and watch app from an unpacked `.app` (owner decision, design section 18): each
/// `*.appex` wherever it sits, then `PlugIns/` if it is empty (other content is kept with a warning), all of
/// `Extensions/` and all of `Watch/`. One App ID per app is what a free team can give. Before a bundle goes, what it
/// declared is read (`stripped[]`) so the owner can see what was lost.
///
/// The tree is the one `ExtractedTree.verify` already checked (no symlinks, no hard links), and every step here uses
/// `lstat`, so nothing is followed. `remaining(in:)` is the independent re-walk: whatever it finds after stripping is
/// `EXTENSION_REMAINS`.
struct ExtensionStripper: Sendable {
    let runner: any Runner
    let limits: InspectLimits
    /// Removes a path; true when it is gone. Injectable so a test can make a removal fail.
    var remove: @Sendable (String) -> Bool = { ScratchDirectory.removeTree($0) }

    private var tools: BinaryTools { BinaryTools(runner: runner, limits: limits) }

    /// Lower-cased names of the app root's folders that hold extensions.
    private static let pluginsName = "plugins"
    private static let wholeFolderNames: Set<String> = ["extensions", "watch"]

    func strip(app: String) async throws -> StripOutcome {
        var warnings: [JSONValue] = []
        let rootNames = ExtractedTree.children(of: app) ?? []
        var wholeFolders: [String] = []
        var plugins: String?
        for name in rootNames where Self.isDirectory(app + "/" + name) {
            let lower = name.lowercased()
            if Self.wholeFolderNames.contains(lower) { wholeFolders.append(name) }
            if lower == Self.pluginsName { plugins = name }
        }

        // Bundles to read and remove: every *.appex outside the whole-folder roots, then what those roots hold.
        var targets = Self.appexPaths(in: app, skipping: Set(wholeFolders.map { $0.lowercased() }), limits: limits)
        for folder in wholeFolders.sorted() {
            for name in ExtractedTree.children(of: app + "/" + folder) ?? [] where Self.isBundle(app + "/" + folder + "/" + name) {
                targets.append(folder + "/" + name)
            }
        }
        targets.sort()

        var stripped: [StrippedBundle] = []
        for relative in targets.prefix(limits.maxExtensions) {
            stripped.append(try await describe(app: app, relative: relative, warnings: &warnings))
        }
        if targets.count > limits.maxExtensions {
            warnings.append(
                CanaryCommand.warning(
                    "EXTENSIONS_TRUNCATED",
                    "\(targets.count) extensions were removed; only the first \(limits.maxExtensions) are listed.",
                    "Review the IPA with `sideload inspect` by hand."))
        }

        // Remove the appexes first (a failed removal is found by the re-walk), then the whole folders, then PlugIns.
        for relative in Self.appexPaths(in: app, skipping: Set(wholeFolders.map { $0.lowercased() }), limits: limits) {
            _ = remove(app + "/" + relative)
        }
        for folder in wholeFolders { _ = remove(app + "/" + folder) }
        if let plugins {
            let path = app + "/" + plugins
            if let rest = ExtractedTree.children(of: path) {
                if rest.isEmpty {
                    _ = remove(path)
                } else {
                    warnings.append(
                        CanaryCommand.warning(
                            "PLUGINS_NOT_EMPTY", "PlugIns/ holds content that is not an extension; it was kept.",
                            "Review the app with `sideload inspect` if the signed app misbehaves."))
                }
            }
        }
        return StripOutcome(stripped: stripped, warnings: warnings)
    }

    // MARK: re-walk

    /// What is still in the app that must not be: any entry named `*.appex` (case-insensitive; a symlink counts), a
    /// root `Extensions/` or `Watch/` folder, and any nested bundle that is a watch app. Relative paths, sorted.
    /// Bounded like the extraction check (depth and entry count); a tree past either is reported as remaining.
    static func remaining(in app: String, limits: InspectLimits = InspectLimits()) -> [String] {
        var found: [String] = []
        var entries = 0
        var pending: [(path: String, depth: Int)] = [(app, 0)]
        while let (dir, depth) = pending.popLast() {
            guard depth < limits.maxTreeDepth, let names = ExtractedTree.children(of: dir) else {
                found.append(relative(dir, to: app).isEmpty ? "." : relative(dir, to: app))
                continue
            }
            for name in names {
                entries += 1
                if entries > limits.maxEntries * 2 {
                    found.append(".")
                    return found.sorted()
                }
                let path = dir + "/" + name
                let rel = relative(path, to: app)
                let lower = name.lowercased()
                if lower.hasSuffix(".appex") || (dir == app && wholeFolderNames.contains(lower)) {
                    found.append(rel)
                    continue
                }
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                if lower.hasSuffix(".app"), isWatchApp(path) {
                    found.append(rel)
                    continue
                }
                pending.append((path, depth + 1))
            }
        }
        return found.sorted()
    }

    /// A bundle whose Info.plist says it is a watchOS app.
    static func isWatchApp(_ bundle: String) -> Bool {
        guard let plist = try? IPAInspector.readPlist(bundle + "/Info.plist", role: "bundle", maxBytes: 4 << 20) else {
            return false
        }
        if (plist["WKWatchKitApp"] as? Bool) == true || (plist["WKApplication"] as? Bool) == true { return true }
        if plist["WKCompanionAppBundleIdentifier"] is String { return true }
        let platforms = (plist["CFBundleSupportedPlatforms"] as? [Any])?.compactMap { $0 as? String } ?? []
        return platforms.contains { ["watchos", "watchsimulator"].contains($0.lowercased()) }
    }

    // MARK: pieces

    /// Relative paths of every `*.appex` under `app`, not looking inside an appex or a root folder named in `skipping`.
    private static func appexPaths(in app: String, skipping roots: Set<String>, limits: InspectLimits) -> [String] {
        var found: [String] = []
        var pending = [app]
        var entries = 0
        while let dir = pending.popLast() {
            for name in ExtractedTree.children(of: dir) ?? [] {
                entries += 1
                guard entries <= limits.maxEntries * 2 else { return found.sorted() }
                let path = dir + "/" + name
                let lower = name.lowercased()
                if lower.hasSuffix(".appex") {
                    found.append(relative(path, to: app))
                } else if !(dir == app && roots.contains(lower)), isDirectory(path) {
                    pending.append(path)
                }
            }
        }
        return found.sorted()
    }

    private func describe(app: String, relative: String, warnings: inout [JSONValue]) async throws -> StrippedBundle {
        let path = app + "/" + relative
        var bundleId: String?
        var point: String?
        if let plist = try? IPAInspector.readPlist(path + "/Info.plist", role: "extension", maxBytes: limits.maxPlistBytes) {
            bundleId = (plist["CFBundleIdentifier"] as? String).map(BinaryTools.cut)
            point = ((plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String).map(BinaryTools.cut)
        } else {
            warnings.append(
                CanaryCommand.warning(
                    "EXTENSION_UNREADABLE", "A removed extension's Info.plist could not be read.",
                    "It was removed anyway; review the IPA with `sideload inspect` if this matters."))
        }
        var keys: [String] = []
        var groups: [String] = []
        switch await tools.signature(of: path) {
        case .signed(let entitlements, _):
            if case .object(let object)? = entitlements { keys = object.keys.sorted() }
            groups = BinaryTools.appGroups(entitlements)
        case .unsigned: break
        case .unknown(let why):
            if why.hasSuffix("was interrupted") { throw SideloadError("CANCELLED", "sign was interrupted.", fix: "Re-run the command.") }
        }
        return StrippedBundle(
            path: BinaryTools.cut(relative), bundleId: bundleId, extensionPoint: point, entitlementKeys: keys, appGroups: groups)
    }

    private static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : ""
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    private static func isBundle(_ path: String) -> Bool {
        isDirectory(path) && { var st = stat(); return lstat(path + "/Info.plist", &st) == 0 }()
    }
}
