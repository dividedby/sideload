import Foundation
import Testing

@testable import SideloadCore

// The profile-carrier project (design section 18, build step 5): generated at run time under builds/carrier/.

private func readText(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

private func mtime(_ path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
}

/// Every regular file under `root` with its bytes, by relative path.
private func snapshot(_ root: String) throws -> [String: Data] {
    var out: [String: Data] = [:]
    let walk = FileManager.default.enumerator(atPath: root)
    while let relative = walk?.nextObject() as? String {
        var isDir: ObjCBool = false
        let full = root + "/" + relative
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
            out[relative] = try Data(contentsOf: URL(fileURLWithPath: full))
        }
    }
    return out
}

@Suite("carrier project")
struct CarrierProjectTests {
    @Test("writes the project, the source file and the Info.plist under the directory, and returns the xcodeproj")
    func contents() async throws {
        try await withTestHome { paths, _ in
            let project = try CarrierProject.write(to: paths.carrierProject)
            #expect(project == paths.builds + "/carrier/Carrier.xcodeproj")
            #expect(paths.carrierProject == paths.builds + "/carrier")
            #expect(
                try snapshot(paths.carrierProject).keys.sorted() == [
                    "Carrier.xcodeproj/project.pbxproj", "Carrier.xcodeproj/xcshareddata/xcschemes/Carrier.xcscheme",
                    "Carrier/App.swift", "Carrier/Info.plist",
                ])
            let source = try readText(paths.carrierProject + "/Carrier/App.swift")
            #expect(source.contains("@main"))
            #expect(source.contains("import SwiftUI"))
            #expect(!source.contains("import UIKit"))
        }
    }

    @Test("multiplatform, no entitlements, no capabilities, and the bundle id is not baked in")
    func settings() async throws {
        try await withTestHome { paths, _ in
            try CarrierProject.write(to: paths.carrierProject)
            let pbx = try readText(paths.carrierProject + "/Carrier.xcodeproj/project.pbxproj")
            #expect(pbx.contains(#"SUPPORTED_PLATFORMS = "iphoneos appletvos";"#))
            #expect(pbx.contains(#"TARGETED_DEVICE_FAMILY = "1,2,3";"#))
            #expect(pbx.contains("SDKROOT = auto;"))
            #expect(pbx.contains("CODE_SIGN_STYLE = Automatic;"))
            #expect(pbx.contains("defaultConfigurationName = Debug;"))
            for forbidden in [
                "CODE_SIGN_ENTITLEMENTS", "PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY",
                "SystemCapabilities", ".entitlements", "PBXCopyFilesBuildPhase", "PBXTargetDependency",
            ] {
                #expect(!pbx.contains(forbidden), "\(forbidden)")
            }
            let info = try #require(
                try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: URL(fileURLWithPath: paths.carrierProject + "/Carrier/Info.plist")),
                    options: [], format: nil) as? [String: Any])
            #expect(info["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
            #expect(info.keys.allSatisfy { !$0.lowercased().contains("entitlement") })
            let scheme = try readText(paths.carrierProject + "/Carrier.xcodeproj/xcshareddata/xcschemes/Carrier.xcscheme")
            #expect(scheme.contains(#"BlueprintName = "Carrier""#))
            #expect(scheme.contains(#"BuildableName = "Carrier.app""#))
        }
    }

    @Test("the project file is an old-style property list whose ids line up")
    func pbxprojIsAPlist() async throws {
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(CarrierProject.pbxproj.utf8), options: [], format: nil)
                as? [String: Any])
        let objects = try #require(plist["objects"] as? [String: Any])
        let root = try #require(plist["rootObject"] as? String)
        let project = try #require(objects[root] as? [String: Any])
        let targets = try #require(project["targets"] as? [String])
        #expect(targets.count == 1)
        let target = try #require(objects[targets[0]] as? [String: Any])
        #expect(target["name"] as? String == "Carrier")
        // Every id mentioned as a reference resolves to an object.
        for id in ["buildConfigurationList", "productReference"] {
            #expect(objects[try #require(target[id] as? String)] != nil, "\(id)")
        }
        for phase in try #require(target["buildPhases"] as? [String]) { #expect(objects[phase] != nil) }
        #expect(CarrierProject.xcscheme.contains(targets[0]), "the scheme points at the target")
    }

    @Test("directories are 0700 and files 0600")
    func modes() async throws {
        try await withTestHome { paths, _ in
            try CarrierProject.write(to: paths.carrierProject)
            for dir in [
                paths.carrierProject, paths.carrierProject + "/Carrier.xcodeproj",
                paths.carrierProject + "/Carrier.xcodeproj/xcshareddata", paths.carrierProject + "/Carrier",
            ] {
                #expect(modeOf(dir) == 0o700, "\(dir)")
            }
            for file in try snapshot(paths.carrierProject).keys {
                #expect(modeOf(paths.carrierProject + "/" + file) == 0o600, "\(file)")
            }
        }
    }

    @Test("a second write is a no-op: same bytes, and files are not even rewritten")
    func idempotent() async throws {
        try await withTestHome { paths, _ in
            try CarrierProject.write(to: paths.carrierProject)
            let first = try snapshot(paths.carrierProject)
            // Age every file, so a rewrite would show as a newer modification time.
            let old = Date(timeIntervalSince1970: 1_000_000_000)
            for file in first.keys {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: paths.carrierProject + "/" + file)
            }
            try CarrierProject.write(to: paths.carrierProject)
            #expect(try snapshot(paths.carrierProject) == first)
            for file in first.keys { #expect(mtime(paths.carrierProject + "/" + file) == old, "\(file)") }
        }
    }

    @Test("it is deterministic: two homes get identical projects")
    func deterministic() async throws {
        let a = try await withTestHome { paths, _ -> [String: Data] in
            try CarrierProject.write(to: paths.carrierProject)
            return try snapshot(paths.carrierProject)
        }
        let b = try await withTestHome { paths, _ -> [String: Data] in
            try CarrierProject.write(to: paths.carrierProject)
            return try snapshot(paths.carrierProject)
        }
        #expect(a == b)
    }

    @Test("a changed or loosened file is put back")
    func repairs() async throws {
        try await withTestHome { paths, _ in
            try CarrierProject.write(to: paths.carrierProject)
            let source = paths.carrierProject + "/Carrier/App.swift"
            try Data("tampered".utf8).write(to: URL(fileURLWithPath: source))
            _ = chmod(source, 0o644)
            try CarrierProject.write(to: paths.carrierProject)
            #expect(try readText(source) == CarrierProject.appSwift)
            #expect(modeOf(source) == 0o600)
            let info = paths.carrierProject + "/Carrier/Info.plist"
            _ = chmod(info, 0o666)
            try CarrierProject.write(to: paths.carrierProject)
            #expect(modeOf(info) == 0o600, "an unchanged file is still tightened")
        }
    }

    @Test("it never reads or writes the paid canary project, and writes only inside its own directory")
    func canaryUntouched() async throws {
        let canaryDir = URL(fileURLWithPath: CanaryCommand.defaultProject).deletingLastPathComponent().path
        let before = try snapshot(canaryDir)
        #expect(!before.isEmpty)
        try await withTestHome { paths, _ in
            try CarrierProject.write(to: paths.carrierProject)
            #expect(listing(paths.builds) == ["carrier"], "no canary folder, no derived data")
            #expect(!FileManager.default.fileExists(atPath: paths.builds + "/canary"))
        }
        #expect(try snapshot(canaryDir) == before)
        #expect(!CarrierProject.pbxproj.contains("Canary"))
    }
}
