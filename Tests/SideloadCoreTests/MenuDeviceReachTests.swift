import Foundation
import Testing

@testable import SideloadCore

// `MenuDeviceReach` (issue 48): what a saved device that cannot be reached says on its card and in `doctor`. Pure; the
// builder tests below only prove it is wired to the list's answer.

private let iosFix = "Unlock it, or connect it to the Mac or the same Wi-Fi."
private let seen3h = testNow.addingTimeInterval(-3 * 3_600)

private struct Row: CustomTestStringConvertible, Sendable {
    var visibility: DeviceVisibility
    var platform: String?
    var autoRenew: Bool
    var available: Bool
    var lastSeen: Date?
    var line: String
    var fix: String

    var testDescription: String {
        "\(visibility) \(platform ?? "nil") renew:\(autoRenew) available:\(available) seen:\(lastSeen != nil)"
    }
}

private let table: [Row] = [
    // Unavailable, iOS: the fix is the same whatever the auto-renew setting; the line carries the setting.
    Row(
        visibility: .unavailable, platform: "ios", autoRenew: true, available: true,
        lastSeen: seen3h,
        line: "Can't reach it right now · Seen 3 h ago · renews when back on Wi-Fi or USB",
        fix: iosFix),
    Row(
        visibility: .unavailable, platform: "ios", autoRenew: false, available: true,
        lastSeen: seen3h, line: "Can't reach it right now · Seen 3 h ago · auto-renew off",
        fix: iosFix),
    Row(
        visibility: .unavailable, platform: "ios", autoRenew: true, available: false,
        lastSeen: seen3h, line: "Can't reach it right now · Seen 3 h ago", fix: iosFix),
    Row(
        visibility: .unavailable, platform: "ios", autoRenew: false, available: false,
        lastSeen: nil, line: "Can't reach it right now", fix: iosFix),
    // A platform that was never recorded reads as iOS.
    Row(
        visibility: .unavailable, platform: nil, autoRenew: true, available: true, lastSeen: nil,
        line: "Can't reach it right now · renews when back on Wi-Fi or USB", fix: iosFix),
    // Unavailable, tvOS: asleep is the likely reason; renewals are promised only when auto-renew is on and its wording is.
    Row(
        visibility: .unavailable, platform: "tvos", autoRenew: true, available: true,
        lastSeen: seen3h, line: "Can't reach it right now · Seen 3 h ago",
        fix: "It may just be asleep; renewals will try again."),
    Row(
        visibility: .unavailable, platform: "tvos", autoRenew: false, available: true,
        lastSeen: seen3h, line: "Can't reach it right now · Seen 3 h ago · auto-renew off",
        fix: "It may just be asleep."),
    Row(
        visibility: .unavailable, platform: "tvos", autoRenew: true, available: false,
        lastSeen: seen3h, line: "Can't reach it right now · Seen 3 h ago",
        fix: "It may just be asleep."),
    Row(
        visibility: .unavailable, platform: "tvos", autoRenew: false, available: false,
        lastSeen: nil, line: "Can't reach it right now", fix: "It may just be asleep."),
    // Not in the list: a listed-nowhere device has no last-seen date.
    Row(
        visibility: .absent, platform: "ios", autoRenew: true, available: true, lastSeen: nil,
        line: "Not seen by this Mac · renews when back on Wi-Fi or USB", fix: iosFix),
    Row(
        visibility: .absent, platform: "ios", autoRenew: false, available: true, lastSeen: nil,
        line: "Not seen by this Mac · auto-renew off", fix: iosFix),
    Row(
        visibility: .absent, platform: "ios", autoRenew: true, available: false, lastSeen: nil,
        line: "Not seen by this Mac", fix: iosFix),
    Row(
        visibility: .absent, platform: "tvos", autoRenew: true, available: true, lastSeen: nil,
        line: "Not seen by this Mac", fix: "It may just be asleep; renewals will try again."),
    Row(
        visibility: .absent, platform: "tvos", autoRenew: false, available: true, lastSeen: nil,
        line: "Not seen by this Mac · auto-renew off", fix: "It may just be asleep."),
    Row(
        visibility: .absent, platform: "tvos", autoRenew: false, available: false, lastSeen: nil,
        line: "Not seen by this Mac", fix: "It may just be asleep."),
    // Not paired: nothing renews until it is paired again, on either platform.
    Row(
        visibility: .unpaired, platform: "ios", autoRenew: true, available: true,
        lastSeen: seen3h, line: "No longer paired · Seen 3 h ago · renews once paired again",
        fix: "Pair it in Xcode."),
    Row(
        visibility: .unpaired, platform: "ios", autoRenew: false, available: true,
        lastSeen: seen3h, line: "No longer paired · Seen 3 h ago · auto-renew off",
        fix: "Pair it in Xcode."),
    Row(
        visibility: .unpaired, platform: "ios", autoRenew: true, available: false,
        lastSeen: seen3h, line: "No longer paired · Seen 3 h ago", fix: "Pair it in Xcode."),
    Row(
        visibility: .unpaired, platform: "tvos", autoRenew: true, available: true,
        lastSeen: seen3h, line: "No longer paired · Seen 3 h ago · renews once paired again",
        fix: "Pair it in Xcode."),
    Row(
        visibility: .unpaired, platform: "tvos", autoRenew: false, available: true,
        lastSeen: nil, line: "No longer paired · auto-renew off", fix: "Pair it in Xcode."),
    Row(
        visibility: .unpaired, platform: "tvos", autoRenew: false, available: false,
        lastSeen: nil, line: "No longer paired", fix: "Pair it in Xcode."),
]

@Suite("menu device reach: the line and the fix")
struct MenuDeviceReachTests {
    @Test("each state, platform and auto-renew setting says exactly this", arguments: table)
    fileprivate func row(_ row: Row) {
        let reach = MenuDeviceReach.of(
            row.visibility, platform: row.platform, autoRenew: row.autoRenew,
            autoRefreshAvailable: row.available, lastSeen: row.lastSeen, now: testNow)
        #expect(reach == MenuDeviceReach(line: row.line, fix: row.fix))
    }

    @Test("a paired, reachable device says nothing, on either platform and any setting")
    func okIsSilent() {
        for platform: String? in ["ios", "tvos", nil] {
            for renew in [true, false] {
                for available in [true, false] {
                    #expect(
                        MenuDeviceReach.of(
                            .ok, platform: platform, autoRenew: renew,
                            autoRefreshAvailable: available, lastSeen: seen3h, now: testNow) == nil)
                }
            }
        }
        #expect(MenuDeviceReach.headline(.ok) == nil)
        #expect(
            MenuDeviceReach.fix(.ok, platform: "ios", autoRenew: true, autoRefreshAvailable: true)
                == nil)
    }

    @Test(
        "every combination names the state, has a fix, never says the device is broken, and fits a line pair"
    )
    func everyCombination() {
        let broken = ["broken", "fail", "error", "unavailable", "dead", "lost"]
        for visibility in DeviceVisibility.allCases where visibility != .ok {
            for platform: String? in ["ios", "tvos", nil] {
                for renew in [true, false] {
                    for available in [true, false] {
                        for lastSeen: Date? in [nil, seen3h] {
                            let context =
                                "\(visibility) \(platform ?? "nil") \(renew) \(available) \(lastSeen != nil)"
                            let reach = MenuDeviceReach.of(
                                visibility, platform: platform, autoRenew: renew,
                                autoRefreshAvailable: available, lastSeen: lastSeen, now: testNow)
                            let value = try? #require(reach, Comment(rawValue: context))
                            let line = value?.line ?? ""
                            #expect(line.hasPrefix(MenuDeviceReach.headline(visibility) ?? "?"))
                            #expect(
                                value?.fix?.isEmpty == false, Comment(rawValue: context))
                            #expect(
                                line.count <= 80, Comment(rawValue: "\(line.count): \(context)"))
                            for word in broken {
                                #expect(
                                    !line.lowercased().contains(word)
                                        && !(value?.fix?.lowercased().contains(word) ?? false),
                                    Comment(rawValue: "\(word): \(context)"))
                            }
                            // No auto-renew wording at all while it is not available.
                            if !available {
                                #expect(
                                    !line.contains("renew") && !line.contains("Renew"),
                                    Comment(rawValue: context))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Suite("menu device reach: on the card")
struct MenuDeviceReachCardTests {
    private func card(
        _ probe: DeviceProbe, device: String = "iphone", auto: Bool = false,
        available: Bool = true
    ) -> MenuDeviceCard {
        menuBuild(
            config: menuConfig(auto: auto ? [device] : [], devices: [device]), probe: probe,
            autoRefreshAvailable: available
        ).devices[0]
    }

    @Test("the card carries the line and the fix for each way the list reads the device")
    func cardPerState() {
        let asleep = card(.listed([menuListed(link: "unavailable", lastSeen: seen3h)]), auto: true)
        #expect(
            asleep.reach
                == MenuDeviceReach(
                    line:
                        "Can't reach it right now · Seen 3 h ago · renews when back on Wi-Fi or USB",
                    fix: iosFix))
        let unpaired = card(.listed([menuListed(paired: false, lastSeen: seen3h)]))
        #expect(
            unpaired.reach
                == MenuDeviceReach(
                    line: "No longer paired · Seen 3 h ago · auto-renew off",
                    fix: "Pair it in Xcode."
                ))
        let missing = card(.listed([]))
        #expect(
            missing.reach
                == MenuDeviceReach(line: "Not seen by this Mac · auto-renew off", fix: iosFix))
        // A device that is not listed has no other device's entry to borrow a state from.
        #expect(
            card(.listed([menuListed("2", link: "unavailable")])).reach?.line.hasPrefix("Not seen")
                == true)
    }

    @Test("an Apple TV card uses the tvOS wording")
    func tvCard() {
        let tv = card(
            .listed([menuListed(link: "unavailable", lastSeen: seen3h)]), device: "appletv",
            auto: true)
        #expect(tv.platform == "tvos")
        #expect(
            tv.reach
                == MenuDeviceReach(
                    line: "Can't reach it right now · Seen 3 h ago",
                    fix: "It may just be asleep; renewals will try again."))
    }

    @Test("a paired, reachable device has no reach line, over USB or Wi-Fi, connected or idle")
    func visibleIsSilent() {
        for link in ["connected", "disconnected"] {
            for transport in [DeviceTransport.wired, .network] {
                let visible = card(.listed([menuListed(link: link, transport: transport)]))
                #expect(visible.reach == nil)
                #expect(visible.presence.isVisible)
            }
        }
    }

    @Test(
        "a listing that failed or is pending is never offline or not paired: no line, no fix, presence unknown or checking"
    )
    func listingFailureIsNotOffline() {
        for auto in [true, false] {
            let failed = card(.failed, auto: auto)
            #expect(failed.reach == nil)
            #expect(failed.presence == .unknown)
            #expect(failed.connectionLabel == "status unknown")
            #expect(!failed.dotFilled)
            let checking = card(.checking, auto: auto)
            #expect(checking.reach == nil)
            #expect(checking.presence == .checking)
        }
        // Even when a device that would read as not paired is all the last good list had.
        #expect(card(.failed).reach?.line.contains("paired") != true)
    }
}

@Suite("menu device reach: sources")
struct MenuDeviceReachSourceTests {
    @Test("no source names `manage pair`: nothing pairs a device, Xcode does")
    func noPairing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var seen = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            seen += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("manage pair"), "\(url.lastPathComponent) names `manage pair`")
        }
        #expect(seen > 20)
    }
}
