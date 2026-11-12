import Testing

@testable import SideloadCore

@Suite("relevant app delta")
struct AppSnapshotDeltaTests {
    private let ours = "io.github.dividedby.free.stremio"
    private let prefix: String? = "io.github.dividedby"

    private func relevant(
        _ before: [String: Bool], _ after: [String: Bool], profiles: FreeTeamProfiles? = nil
    ) -> AppSnapshot.RelevantDelta {
        AppSnapshot.delta(
            from: AppSnapshot(apps: before), to: AppSnapshot(apps: after), relevantTo: ours,
            prefix: prefix, profiles: profiles)
    }

    @Test("App Store apps that appear or vanish are counted as other, the relevant delta is empty")
    func appStoreChurn() {
        let result = relevant(
            [ours: true, "com.apple.store.old": false],
            [ours: true, "com.example.store.new": false, "com.example.store.newer": false])
        #expect(result.delta.isEmpty)
        #expect(result.otherAdded == 2 && result.otherRemoved == 1)
        #expect(!result.strict)
        #expect(result.hasOtherChanges)
        #expect(result.otherAppsWarning != nil)
    }

    @Test("our own app is relevant, with other churn counted beside it")
    func ownApp() {
        let first = relevant([:], [ours: true], profiles: nil)
        // Not in the before snapshot, flagged in the after one: the flag is trusted.
        #expect(first.delta.added == [ours] && first.delta.removed.isEmpty && !first.strict)
        let gone = relevant([ours: true, "com.example.store": false], [:])
        #expect(gone.delta.removed == [ours] && gone.otherRemoved == 1 && !gone.strict)
    }

    @Test("a free-prefix ID is relevant even when devicectl does not flag it")
    func ownPrefix() {
        let result = relevant(
            [ours: true], [ours: true, "io.github.dividedby.free.other": false])
        #expect(result.delta.added == ["io.github.dividedby.free.other"])
        #expect(result.otherAdded == 0 && !result.strict)
    }

    @Test(
        "a developer-signed app is relevant whether the flag is in the before or the after snapshot"
    )
    func developerSigned() {
        let added = relevant([ours: true], [ours: true, "com.example.dev": true])
        #expect(added.delta.added == ["com.example.dev"] && added.otherAdded == 0)
        let removed = relevant([ours: true, "com.example.dev": true], [ours: true])
        #expect(removed.delta.removed == ["com.example.dev"] && removed.otherRemoved == 0)
    }

    @Test("an app listed in the free-team profiles is relevant without the developer flag")
    func profileListed() {
        let profiles = FreeTeamProfiles(bundleIds: ["com.example.profiled"])
        let withProfiles = relevant(
            [ours: true], [ours: true, "com.example.profiled": false, "com.example.store": false],
            profiles: profiles)
        #expect(withProfiles.delta.added == ["com.example.profiled"])
        #expect(withProfiles.otherAdded == 1)
        // Profiles not read: that criterion is simply dropped.
        let without = relevant(
            [ours: true], [ours: true, "com.example.profiled": false], profiles: nil)
        #expect(without.delta.isEmpty && without.otherAdded == 1)
    }

    @Test(
        "our app present but not flagged in a snapshot: the flag is untrusted, every ID is relevant"
    )
    func targetNotFlagged() {
        for (before, after) in [
            ([ours: false], [ours: true, "com.example.store": false]),
            ([ours: true], [ours: false, "com.example.store": false]),
            ([ours: false], [ours: false, "com.example.store": false]),
        ] {
            let result = relevant(before, after)
            #expect(result.strict)
            #expect(result.delta.added == ["com.example.store"])
            #expect(result.otherAdded == 0 && result.otherRemoved == 0)
            #expect(result.otherAppsWarning == nil)
        }
    }

    @Test("our app in neither snapshot: no evidence the flag works, every ID is relevant")
    func targetAbsent() {
        let result = relevant(["com.example.a": false], ["com.example.b": false])
        #expect(result.strict)
        #expect(
            result.delta.added == ["com.example.b"] && result.delta.removed == ["com.example.a"])
        #expect(result.otherAdded == 0 && result.otherRemoved == 0)
    }

    @Test("the warning carries counts only")
    func warningShape() throws {
        let result = relevant([ours: true], [ours: true, "com.example.secret.id": false])
        let warning = try #require(result.otherAppsWarning)
        #expect(warning["code"] == "OTHER_APPS_CHANGED")
        #expect(warning["data"]?["addedCount"] == 1 && warning["data"]?["removedCount"] == 0)
        #expect(!String(describing: warning).contains("secret"))
    }
}
