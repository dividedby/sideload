import Foundation

/// What a source says to download: one IPA, its expected SHA-256 and size. Built from untrusted metadata, so
/// every field is validated before it becomes a path component or a URL.
struct ResolvedAsset: Sendable, Equatable {
    let app: String
    /// Names the folder under `downloads/<app>/`. Apollo: the suffix after `_` in the tag. Stremio: `<ver>b<build>`.
    let version: String
    /// The IPA's file name, a plain name (letters, digits, `.`, `_`, `-`).
    let fileName: String
    let url: URL
    /// The publisher's SHA-256 (lowercase hex), recorded as `upstreamDigest`.
    let upstreamDigest: String
    /// The size the source declares; also the download's cap.
    let size: Int64
    /// The upstream build number (Stremio's `buildVersion`); nil when the source has none (Apollo).
    let build: String?
    /// The minimum OS the source declares (Stremio's `minOSVersion`); nil when it declares none (Apollo).
    let minOS: String?
}

/// Turns release or index metadata into a `ResolvedAsset`, or a precise refusal. Pure: no network, no files.
enum SourceResolver {
    // MARK: shared validation

    private static let safeToken = try! NSRegularExpression(pattern: #"^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$"#)
    private static let digestPattern = try! NSRegularExpression(pattern: #"^[0-9a-f]{64}$"#)

    static func isSafeToken(_ text: String) -> Bool {
        safeToken.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            && !text.contains("..")
    }

    /// `sha256:<hex>` (GitHub) or bare hex (the Stremio index), either case. Anything else is not a digest.
    static func parseDigest(_ raw: String?, prefixed: Bool) throws -> String {
        var text = (raw ?? "").lowercased()
        if prefixed {
            guard text.hasPrefix("sha256:") else { throw missingDigest }
            text.removeFirst("sha256:".count)
        } else if text.hasPrefix("sha256:") {
            text.removeFirst("sha256:".count)
        }
        guard digestPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { throw missingDigest }
        return text
    }

    private static var missingDigest: SideloadError {
        SideloadError(
            "UPSTREAM_DIGEST_MISSING", "The source published no usable SHA-256 for this file.",
            fix: "Nothing is downloaded without a digest to check it against. Wait for the publisher to fix the metadata.")
    }

    private static func invalid(_ what: String) -> SideloadError {
        SideloadError(
            "SOURCE_INVALID", "The source metadata is not usable: \(what).",
            fix: "Retry later; if it persists the publisher changed the format and fetch needs an update.")
    }

    private static func notAllowed(_ what: String) -> SideloadError {
        SideloadError(
            "SOURCE_NOT_ALLOWED", "The source offered nothing fetch accepts: \(what).",
            fix: "Fetch only takes the pinned asset shape (docs/design.md section 8, approved sources).")
    }

    private static func checkSize(_ size: Int64?) throws -> Int64 {
        guard let size, size > 0 else { throw invalid("no file size") }
        guard size <= FetchLimits.maxIPABytes else {
            throw SideloadError(
                "DOWNLOAD_TOO_LARGE", "The source declares a file over the \(FetchLimits.maxIPABytes >> 30) GiB limit.",
                fix: "Nothing was downloaded.")
        }
        return size
    }

    // MARK: Apollo Reborn (GitHub releases)

    private struct Release: Decodable {
        var tag_name: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String?
            var size: Int64?
            var digest: String?
            var browser_download_url: String?
            var state: String?
        }
    }

    /// Tag `v<x>_<ver>`; the asset must be named exactly `Apollo-Reborn-<ver>-GLASS-NOEXTENSIONS.ipa`, and its
    /// download URL exactly the repository's `releases/download/<tag>/<name>`. Look-alikes (`-NOEXTENSIONS`,
    /// `-GLASSICONS-NOEXTENSIONS`, `-GLASS`, dSYMs, `.deb`) never match, whatever their order.
    static func apollo(app: String, repo: String, json: Data) throws -> ResolvedAsset {
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: json) } catch { throw invalid("the release is not valid JSON") }
        if release.draft == true || release.prerelease == true { throw notAllowed("the latest release is a draft or pre-release") }
        guard let tag = release.tag_name else { throw invalid("no tag") }
        let parts = tag.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasPrefix("v"), isSafeToken(String(parts[0].dropFirst())), isSafeToken(String(parts[1])) else {
            throw notAllowed("the tag is not v<x>_<ver>")
        }
        let version = String(parts[1])
        let name = "Apollo-Reborn-\(version)-GLASS-NOEXTENSIONS.ipa"
        let matches = (release.assets ?? []).filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first else {
            throw notAllowed(matches.isEmpty ? "no asset named exactly the GLASS-NOEXTENSIONS IPA" : "more than one asset with the IPA's name")
        }
        if let state = asset.state, state != "uploaded" { throw notAllowed("the asset is not fully uploaded") }
        let digest = try parseDigest(asset.digest, prefixed: true)
        let size = try checkSize(asset.size)
        guard let link = asset.browser_download_url, let url = URL(string: link),
            url.absoluteString == "https://github.com/\(repo)/releases/download/\(tag)/\(name)"
        else { throw notAllowed("the asset's download URL is not the repository's release URL") }
        return ResolvedAsset(app: app, version: version, fileName: name, url: url, upstreamDigest: digest, size: size, build: nil, minOS: nil)
    }

    // MARK: Stremio (gorlev AltStore-style indexes)

    private struct Loose: Decodable {
        let text: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                text = s
            } else if let i = try? c.decode(Int.self) {
                text = String(i)
            } else if let d = try? c.decode(Double.self), d.isFinite {
                // `15.1` -> "15.1", `15.0` -> "15": the shortest form, with no float artefact.
                text = d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
            } else {
                text = nil
            }
        }
    }

    private struct Index: Decodable {
        var apps: [App]?

        struct App: Decodable {
            var bundleIdentifier: String?
            var versions: [Version]?
        }

        struct Version: Decodable {
            var version: Loose?
            var buildVersion: Loose?
            var downloadURL: String?
            var size: Int64?
            var sha256: String?
            var minOSVersion: Loose?
        }
    }

    /// The app with bundle ID `com.stremio.pal`, its first (latest) version. The URL must be https on
    /// `dl.strem.io`; for tvOS it must be exactly `/apple/<ver>b<build>/tvos/stremio_tvOS.ipa` (design section 8);
    /// for iOS the path is pinned only to a plain `.ipa` name until the first approved fetch shows its shape.
    static func stremio(app: String, tvos: Bool, json: Data) throws -> ResolvedAsset {
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: json) } catch { throw invalid("the index is not valid JSON") }
        let candidates = (index.apps ?? []).filter { $0.bundleIdentifier == FetchCatalog.stremioBundleId }
        guard candidates.count == 1 else { throw notAllowed("the index has \(candidates.count) apps with the Stremio bundle ID") }
        guard let latest = candidates[0].versions?.first else { throw invalid("the app has no versions") }
        guard let ver = latest.version?.text, isSafeToken(ver), let build = latest.buildVersion?.text, isSafeToken(build) else {
            throw invalid("the version or build is missing or has unexpected characters")
        }
        let digest = try parseDigest(latest.sha256, prefixed: false)
        let size = try checkSize(latest.size)
        var minOS: String?
        if let declared = latest.minOSVersion {
            guard let text = declared.text, text.range(of: #"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$"#, options: .regularExpression) != nil else {
                throw invalid("minOSVersion is not a version number")
            }
            minOS = text
        }
        let versionKey = "\(ver)b\(build)"
        guard isSafeToken(versionKey), let link = latest.downloadURL, let url = URL(string: link),
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.host == FetchCatalog.stremioHost, parts.port == nil, parts.user == nil,
            parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw notAllowed("the download URL is not https on \(FetchCatalog.stremioHost)") }
        let path = parts.percentEncodedPath
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components[0].isEmpty, let last = components.last.map(String.init), last.hasSuffix(".ipa"),
            isSafeToken(last), !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw notAllowed("the download path is not a plain .ipa path") }
        if tvos, path != "/apple/\(versionKey)/tvos/stremio_tvOS.ipa" {
            throw notAllowed("the tvOS download path is not /apple/<ver>b<build>/tvos/stremio_tvOS.ipa")
        }
        return ResolvedAsset(
            app: app, version: versionKey, fileName: last, url: url, upstreamDigest: digest, size: size, build: build, minOS: minOS)
    }

    static func resolve(_ source: FetchSource, json: Data) throws -> ResolvedAsset {
        switch source.kind {
        case .githubRelease(let repo): try apollo(app: source.app, repo: repo, json: json)
        case .altstoreIndex(_, let tvos): try stremio(app: source.app, tvos: tvos, json: json)
        }
    }
}
