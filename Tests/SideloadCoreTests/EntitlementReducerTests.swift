import Foundation
import Testing

@testable import SideloadCore

// The reduction table (design section 18, `sign` step 4): of the main app's originals only what the free profile
// grants survives, and everything else is listed.

private let appId = Team.free + "." + "io.github.dividedby.free.stremio"

private func reduce(_ original: JSONValue?) -> EntitlementReduction {
    EntitlementReducer.reduce(original: original, applicationIdentifier: appId, team: Team.free, getTaskAllow: true)
}

@Suite("EntitlementReducer")
struct EntitlementReducerTests {
    @Test("a full set of originals: identifiers from the profile, get-task-allow from the profile, keychain group rewritten, the rest dropped and listed")
    func table() throws {
        let original: JSONValue = [
            "application-identifier": "ABCDE12345.com.stremio.pal",
            "com.apple.developer.team-identifier": "ABCDE12345",
            "get-task-allow": false,
            "keychain-access-groups": ["ABCDE12345.com.stremio.pal", "ABCDE12345.shared"],
            "aps-environment": "production",
            "com.apple.security.application-groups": ["group.a", "group.b"],
            "com.apple.developer.associated-domains": ["applinks:example.com"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.usernotifications.time-sensitive": true,
        ]
        let r = reduce(original)
        #expect(r.applicationIdentifier == appId && r.teamIdentifier == Team.free)
        #expect(r.getTaskAllow == true, "the profile's value, not the original's false")
        #expect(r.keychainGroup == appId)
        #expect(r.dropped == [
            "aps-environment", "com.apple.developer.associated-domains", "com.apple.developer.icloud-services",
            "com.apple.developer.usernotifications.time-sensitive", "com.apple.security.application-groups",
        ])
        #expect(r.appGroups == ["group.a", "group.b"])
        // What codesign is given.
        let plist = r.plist
        #expect(Set(plist.keys) == ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"])
        #expect(plist["application-identifier"] as? String == appId)
        #expect(plist["com.apple.developer.team-identifier"] as? String == Team.free)
        #expect(plist["get-task-allow"] as? Bool == true)
        #expect(plist["keychain-access-groups"] as? [String] == [appId], "one group, the new app ID")
    }

    @Test("get-task-allow is always the profile's value, whatever the original had, and is never listed as dropped")
    func getTaskAllow() {
        for original: JSONValue in [[:], ["get-task-allow": false], ["get-task-allow": true], ["get-task-allow": "yes"], ["get-task-allow": 1]] {
            let r = reduce(original)
            #expect(r.getTaskAllow == true && r.plist["get-task-allow"] as? Bool == true, "\(original)")
            #expect(!r.dropped.contains("get-task-allow"), "\(original)")
        }
        // The value is the profile's, passed in.
        let off = EntitlementReducer.reduce(original: ["get-task-allow": true], applicationIdentifier: appId, team: Team.free, getTaskAllow: false)
        #expect(off.plist["get-task-allow"] as? Bool == false)
    }

    @Test("keychain-access-groups is rewritten only when the original had groups")
    func keychain() {
        #expect(reduce([:]).keychainGroup == nil)
        #expect(reduce(["keychain-access-groups": []]).keychainGroup == nil)
        #expect(reduce(["keychain-access-groups": []]).dropped == ["keychain-access-groups"])
        #expect(reduce(["keychain-access-groups": "oops"]).keychainGroup == nil)
        #expect(reduce(["keychain-access-groups": ["A.b"]]).keychainGroup == appId)
        #expect(reduce(["keychain-access-groups": ["A.b"]]).dropped.isEmpty)
    }

    @Test("an unsigned or unreadable original (null, nothing, not an object) gives only the two identifiers and get-task-allow")
    func empty() {
        for original: JSONValue? in [nil, .null, [], "x"] {
            let r = reduce(original)
            #expect(r.dropped.isEmpty && r.appGroups.isEmpty && r.keychainGroup == nil)
            #expect(Set(r.plist.keys) == ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow"])
        }
    }

    @Test("the identifiers come from the profile even when the original disagrees, and are never listed as dropped")
    func identifiers() {
        let r = reduce(["application-identifier": "OTHER.x", "com.apple.developer.team-identifier": "OTHER"])
        #expect(r.dropped.isEmpty)
        #expect(r.plist["application-identifier"] as? String == appId)
    }

    @Test("the plist is XML that reads back to the same dictionary")
    func data() throws {
        let r = reduce(["get-task-allow": true, "keychain-access-groups": ["x"]])
        let text = String(decoding: try r.plistData(), as: UTF8.self)
        #expect(text.hasPrefix("<?xml"))
        let back = try #require(
            try PropertyListSerialization.propertyList(from: try r.plistData(), options: [], format: nil) as? [String: Any])
        #expect(back["get-task-allow"] as? Bool == true && back["keychain-access-groups"] as? [String] == [appId])
    }

    @Test("groups the main app declares and groups only a stripped extension used are told apart")
    func groups() {
        func stripped(_ groups: [String]) -> StrippedBundle {
            StrippedBundle(path: "PlugIns/X.appex", bundleId: nil, extensionPoint: nil, entitlementKeys: [], appGroups: groups)
        }
        let split = EntitlementReducer.groupSplit(
            app: ["group.shared", "group.app"], stripped: [stripped(["group.shared", "group.ext"]), stripped(["group.ext", "group.other"])])
        #expect(split.declaredByApp == ["group.app", "group.shared"])
        #expect(split.extensionsOnly == ["group.ext", "group.other"])
        let none = EntitlementReducer.groupSplit(app: [], stripped: [])
        #expect(none.declaredByApp.isEmpty && none.extensionsOnly.isEmpty)
    }
}
