import Foundation

/// How an upstream version compares with the installed one (design section 8, `updates`). Pure: no clock, no files.
///
/// Only the version strings the resolver produces and `installs[].version` stores are understood: Apollo's `3.9.0` and
/// Stremio's `<ver>b<build>` (`1.9.6b142`). That is one to four dot-separated whole numbers, optionally followed by `b` and
/// a whole build number. Components are compared as integers (`3.10.0` is newer than `3.9.0`), a missing component counts
/// as 0, and the build breaks a tie. Anything else (a pre-release suffix, a leading `v`, a build on one side only) is
/// `unknown`: there is no fallback to comparing the text, so nothing odd is ever offered as an update.
enum VersionOrder {
    enum State: String, Sendable, Equatable {
        /// Upstream is strictly greater than what is installed.
        case newer
        case current
        /// Upstream is lower; never offered.
        case older
        case unknown
    }

    struct Parsed: Equatable {
        let parts: [Int]
        let build: Int?
    }

    private static let shape = try! NSRegularExpression(pattern: #"^([0-9]{1,9}(?:\.[0-9]{1,9}){0,3})(?:b([0-9]{1,9}))?$"#)

    static func parse(_ text: String) -> Parsed? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = shape.firstMatch(in: text, range: range), let versionRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let parts = text[versionRange].split(separator: ".").compactMap { Int($0) }
        var build: Int?
        if let buildRange = Range(match.range(at: 2), in: text) {
            guard let value = Int(text[buildRange]) else { return nil }
            build = value
        }
        return Parsed(parts: parts, build: build)
    }

    /// `upstream` against `installed`.
    static func compare(installed: String, upstream: String) -> State {
        guard let have = parse(installed), let want = parse(upstream) else { return .unknown }
        guard (have.build == nil) == (want.build == nil) else { return .unknown }
        let width = max(have.parts.count, want.parts.count)
        let lhs = have.parts + Array(repeating: 0, count: width - have.parts.count)
        let rhs = want.parts + Array(repeating: 0, count: width - want.parts.count)
        if rhs != lhs { return rhs.lexicographicallyPrecedes(lhs) ? .older : .newer }
        guard let installedBuild = have.build, let upstreamBuild = want.build else { return .current }
        if upstreamBuild == installedBuild { return .current }
        return upstreamBuild > installedBuild ? .newer : .older
    }
}
