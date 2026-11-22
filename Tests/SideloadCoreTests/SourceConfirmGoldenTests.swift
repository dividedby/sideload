import Testing

@testable import SideloadCore

// The confirm value is what the owner confirmed for a source. The three literals below were computed from the sorted-key JSON the
// code at v0.9.0 (f620ef9) hashed; a source added without a template pin, tag rule, download path or required build must keep
// hashing to exactly them, or every printed `source add` command and every menu confirm would change.

private let target = SourceAdd.AppTarget(
    id: "myapp", suffix: "myapp", platform: "ios", name: "Myapp", attaches: false)
private let githubHosts = [
    "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
]

@Suite("source add: confirm values of existing source shapes")
struct SourceConfirmGoldenTests {
    @Test("an unpinned GitHub source")
    func unpinnedGithub() {
        #expect(
            SourceAdd.confirmValue(
                kind: "githubRelease", url: "https://github.com/acme/widget", repo: "acme/widget",
                bundleId: nil, app: target, metadataHosts: ["api.github.com"],
                downloadHosts: githubHosts) == "a555fc5621cb72f9")
    }

    @Test("an exact-asset GitHub source")
    func pinnedGithub() {
        #expect(
            SourceAdd.confirmValue(
                kind: "githubRelease", url: "https://github.com/acme/widget", repo: "acme/widget",
                asset: "Widget-iOS.ipa", bundleId: nil, app: target,
                metadataHosts: ["api.github.com"], downloadHosts: githubHosts)
                == "c85ed570a42ab30d")
    }

    @Test("an index source")
    func altstore() {
        #expect(
            SourceAdd.confirmValue(
                kind: "altstoreIndex", url: "https://idx.example.com/apps.json", repo: nil,
                bundleId: "com.acme.widget", app: target, metadataHosts: ["idx.example.com"],
                downloadHosts: ["cdn.example.com"]) == "364fddd1c85c53b9")
    }
}
