import Darwin
import Foundation

/// The "profile carrier": a minimal one-file SwiftUI app that exists only so `xcodebuild` has something to sign
/// with the free team, and so Xcode creates the App ID and the development profile for a bundle ID
/// (`provision`, design section 18). It is written at run time from the templates below into
/// `$SIDELOAD_HOME/builds/carrier/` (the binary stays self-contained). The bundle ID is not in the project; it
/// is passed on the `xcodebuild` command line (`PRODUCT_BUNDLE_IDENTIFIER=`).
///
/// Multiplatform (`SUPPORTED_PLATFORMS = "iphoneos appletvos"`, `TARGETED_DEVICE_FAMILY = 1,2,3`), no entitlements,
/// no capabilities, no extensions. Independent of the paid-team `canary/` project, which is never read or written.
public enum CarrierProject {
    public static let scheme = "Carrier"
    public static let projectName = "Carrier.xcodeproj"
    /// The built app's name: `<derived data>/Build/Products/Debug-<sdk>/Carrier.app`.
    public static let productName = "Carrier.app"

    /// Writes (or refreshes) the project under `directory` (0700; files 0600) and returns the `.xcodeproj` path.
    /// The content is fixed, so a second call changes nothing: a file whose bytes already match is left alone
    /// (its modification time stays, so Xcode has nothing to rebuild).
    @discardableResult
    public static func write(to directory: String) throws -> String {
        let project = directory + "/" + projectName
        for dir in [
            directory, project, project + "/xcshareddata", project + "/xcshareddata/xcschemes", directory + "/Carrier",
        ] {
            try makeDirectories(dir, mode: 0o700)
            if chmod(dir, 0o700) != 0 { throw ioError("chmod") }
        }
        for (path, content) in files(in: directory) {
            try writeIfChanged(Data(content.utf8), to: path)
        }
        return project
    }

    /// Every file the project consists of, by absolute path.
    static func files(in directory: String) -> [(path: String, content: String)] {
        let project = directory + "/" + projectName
        return [
            (project + "/project.pbxproj", pbxproj),
            (project + "/xcshareddata/xcschemes/Carrier.xcscheme", xcscheme),
            (directory + "/Carrier/App.swift", appSwift),
            (directory + "/Carrier/Info.plist", infoPlist),
        ]
    }

    private static func writeIfChanged(_ data: Data, to path: String) throws {
        if let existing = try readFile(path), existing == data {
            if chmod(path, 0o600) != 0 { throw ioError("chmod") }
            return
        }
        try AtomicFile.write(data, to: path, mode: 0o600)
    }

    static let appSwift = """
        import SwiftUI

        @main
        struct CarrierApp: App {
            var body: some Scene {
                WindowGroup {
                    Text("sideload profile carrier")
                }
            }
        }

        """

    static let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>$(EXECUTABLE_NAME)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>UIApplicationSceneManifest</key>
            <dict>
                <key>UIApplicationSupportsMultipleScenes</key>
                <false/>
            </dict>
            <key>UILaunchScreen</key>
            <dict/>
        </dict>
        </plist>

        """

    // Object IDs are fixed (24 hex digits), so the file is byte-identical on every write.
    static let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {
            };
            objectVersion = 56;
            objects = {

        /* Begin PBXBuildFile section */
                CC0000000000000000000011 /* App.swift in Sources */ = {isa = PBXBuildFile; fileRef = CC0000000000000000000001 /* App.swift */; };
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
                CC0000000000000000000001 /* App.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
                CC0000000000000000000002 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
                CC0000000000000000000003 /* Carrier.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Carrier.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXFrameworksBuildPhase section */
                CC0000000000000000000021 /* Frameworks */ = {
                    isa = PBXFrameworksBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
                CC0000000000000000000031 = {
                    isa = PBXGroup;
                    children = (
                        CC0000000000000000000032 /* Carrier */,
                        CC0000000000000000000033 /* Products */,
                    );
                    sourceTree = "<group>";
                };
                CC0000000000000000000032 /* Carrier */ = {
                    isa = PBXGroup;
                    children = (
                        CC0000000000000000000001 /* App.swift */,
                        CC0000000000000000000002 /* Info.plist */,
                    );
                    path = Carrier;
                    sourceTree = "<group>";
                };
                CC0000000000000000000033 /* Products */ = {
                    isa = PBXGroup;
                    children = (
                        CC0000000000000000000003 /* Carrier.app */,
                    );
                    name = Products;
                    sourceTree = "<group>";
                };
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
                CC0000000000000000000041 /* Carrier */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = CC0000000000000000000061 /* Build configuration list for PBXNativeTarget "Carrier" */;
                    buildPhases = (
                        CC0000000000000000000022 /* Sources */,
                        CC0000000000000000000021 /* Frameworks */,
                        CC0000000000000000000023 /* Resources */,
                    );
                    buildRules = (
                    );
                    dependencies = (
                    );
                    name = Carrier;
                    productName = Carrier;
                    productReference = CC0000000000000000000003 /* Carrier.app */;
                    productType = "com.apple.product-type.application";
                };
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
                CC0000000000000000000051 /* Project object */ = {
                    isa = PBXProject;
                    attributes = {
                        BuildIndependentTargetsInParallel = 1;
                        LastSwiftUpdateCheck = 1500;
                        LastUpgradeCheck = 1500;
                        TargetAttributes = {
                            CC0000000000000000000041 = {
                                CreatedOnToolsVersion = 15.0;
                            };
                        };
                    };
                    buildConfigurationList = CC0000000000000000000062 /* Build configuration list for PBXProject "Carrier" */;
                    compatibilityVersion = "Xcode 14.0";
                    developmentRegion = en;
                    hasScannedForEncodings = 0;
                    knownRegions = (
                        en,
                        Base,
                    );
                    mainGroup = CC0000000000000000000031;
                    productRefGroup = CC0000000000000000000033 /* Products */;
                    projectDirPath = "";
                    projectRoot = "";
                    targets = (
                        CC0000000000000000000041 /* Carrier */,
                    );
                };
        /* End PBXProject section */

        /* Begin PBXResourcesBuildPhase section */
                CC0000000000000000000023 /* Resources */ = {
                    isa = PBXResourcesBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXResourcesBuildPhase section */

        /* Begin PBXSourcesBuildPhase section */
                CC0000000000000000000022 /* Sources */ = {
                    isa = PBXSourcesBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                        CC0000000000000000000011 /* App.swift in Sources */,
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
                CC0000000000000000000071 /* Debug */ = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        ALWAYS_SEARCH_USER_PATHS = NO;
                        CLANG_ENABLE_MODULES = YES;
                        CLANG_ENABLE_OBJC_ARC = YES;
                        COPY_PHASE_STRIP = NO;
                        DEBUG_INFORMATION_FORMAT = dwarf;
                        ENABLE_STRICT_OBJC_MSGSEND = YES;
                        ENABLE_TESTABILITY = YES;
                        GCC_OPTIMIZATION_LEVEL = 0;
                        GCC_PREPROCESSOR_DEFINITIONS = (
                            "DEBUG=1",
                            "$(inherited)",
                        );
                        IPHONEOS_DEPLOYMENT_TARGET = 17.0;
                        ONLY_ACTIVE_ARCH = YES;
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
                        SWIFT_OPTIMIZATION_LEVEL = "-Onone";
                        TVOS_DEPLOYMENT_TARGET = 17.0;
                    };
                    name = Debug;
                };
                CC0000000000000000000072 /* Release */ = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        ALWAYS_SEARCH_USER_PATHS = NO;
                        CLANG_ENABLE_MODULES = YES;
                        CLANG_ENABLE_OBJC_ARC = YES;
                        COPY_PHASE_STRIP = NO;
                        DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
                        ENABLE_NS_ASSERTIONS = NO;
                        ENABLE_STRICT_OBJC_MSGSEND = YES;
                        IPHONEOS_DEPLOYMENT_TARGET = 17.0;
                        SWIFT_COMPILATION_MODE = wholemodule;
                        TVOS_DEPLOYMENT_TARGET = 17.0;
                        VALIDATE_PRODUCT = YES;
                    };
                    name = Release;
                };
                CC0000000000000000000073 /* Debug */ = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        CODE_SIGN_STYLE = Automatic;
                        CURRENT_PROJECT_VERSION = 1;
                        GENERATE_INFOPLIST_FILE = YES;
                        INFOPLIST_FILE = Carrier/Info.plist;
                        LD_RUNPATH_SEARCH_PATHS = (
                            "$(inherited)",
                            "@executable_path/Frameworks",
                        );
                        MARKETING_VERSION = 1.0;
                        PRODUCT_NAME = "$(TARGET_NAME)";
                        SDKROOT = auto;
                        SUPPORTED_PLATFORMS = "iphoneos appletvos";
                        SUPPORTS_MACCATALYST = NO;
                        SWIFT_EMIT_LOC_STRINGS = YES;
                        SWIFT_VERSION = 5.0;
                        TARGETED_DEVICE_FAMILY = "1,2,3";
                    };
                    name = Debug;
                };
                CC0000000000000000000074 /* Release */ = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        CODE_SIGN_STYLE = Automatic;
                        CURRENT_PROJECT_VERSION = 1;
                        GENERATE_INFOPLIST_FILE = YES;
                        INFOPLIST_FILE = Carrier/Info.plist;
                        LD_RUNPATH_SEARCH_PATHS = (
                            "$(inherited)",
                            "@executable_path/Frameworks",
                        );
                        MARKETING_VERSION = 1.0;
                        PRODUCT_NAME = "$(TARGET_NAME)";
                        SDKROOT = auto;
                        SUPPORTED_PLATFORMS = "iphoneos appletvos";
                        SUPPORTS_MACCATALYST = NO;
                        SWIFT_EMIT_LOC_STRINGS = YES;
                        SWIFT_VERSION = 5.0;
                        TARGETED_DEVICE_FAMILY = "1,2,3";
                    };
                    name = Release;
                };
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
                CC0000000000000000000061 /* Build configuration list for PBXNativeTarget "Carrier" */ = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        CC0000000000000000000073 /* Debug */,
                        CC0000000000000000000074 /* Release */,
                    );
                    defaultConfigurationIsVisible = 0;
                    defaultConfigurationName = Debug;
                };
                CC0000000000000000000062 /* Build configuration list for PBXProject "Carrier" */ = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        CC0000000000000000000071 /* Debug */,
                        CC0000000000000000000072 /* Release */,
                    );
                    defaultConfigurationIsVisible = 0;
                    defaultConfigurationName = Debug;
                };
        /* End XCConfigurationList section */
            };
            rootObject = CC0000000000000000000051 /* Project object */;
        }

        """

    static let xcscheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme
           LastUpgradeVersion = "1500"
           version = "1.7">
           <BuildAction
              parallelizeBuildables = "YES"
              buildImplicitDependencies = "YES">
              <BuildActionEntries>
                 <BuildActionEntry
                    buildForTesting = "YES"
                    buildForRunning = "YES"
                    buildForProfiling = "YES"
                    buildForArchiving = "YES"
                    buildForAnalyzing = "YES">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "CC0000000000000000000041"
                       BuildableName = "Carrier.app"
                       BlueprintName = "Carrier"
                       ReferencedContainer = "container:Carrier.xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              shouldUseLaunchSchemeArgsEnv = "YES">
           </TestAction>
           <LaunchAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              launchStyle = "0"
              useCustomWorkingDirectory = "NO"
              ignoresPersistentStateOnLaunch = "NO"
              debugDocumentVersioning = "YES"
              debugServiceExtension = "internal"
              allowLocationSimulation = "YES">
              <BuildableProductRunnable
                 runnableDebuggingMode = "0">
                 <BuildableReference
                    BuildableIdentifier = "primary"
                    BlueprintIdentifier = "CC0000000000000000000041"
                    BuildableName = "Carrier.app"
                    BlueprintName = "Carrier"
                    ReferencedContainer = "container:Carrier.xcodeproj">
                 </BuildableReference>
              </BuildableProductRunnable>
           </LaunchAction>
           <ProfileAction
              buildConfiguration = "Release"
              shouldUseLaunchSchemeArgsEnv = "YES"
              savedToolIdentifier = ""
              useCustomWorkingDirectory = "NO"
              debugDocumentVersioning = "YES">
           </ProfileAction>
           <AnalyzeAction
              buildConfiguration = "Debug">
           </AnalyzeAction>
           <ArchiveAction
              buildConfiguration = "Release"
              revealArchiveInOrganizer = "YES">
           </ArchiveAction>
        </Scheme>

        """
}
