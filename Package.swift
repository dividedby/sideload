// swift-tools-version: 6.4
import PackageDescription

let releaseSize: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]
let releaseLink: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]

let package = Package(
    name: "sideload",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SideloadCore", targets: ["SideloadCore"]),
        .executable(name: "sideload", targets: ["sideload"]),
        .executable(name: "SideloadMenu", targets: ["SideloadMenu"]),
    ],
    targets: [
        .target(
            name: "SideloadCore",
            swiftSettings: releaseSize
        ),
        .executableTarget(
            name: "sideload",
            dependencies: ["SideloadCore"],
            swiftSettings: releaseSize,
            linkerSettings: releaseLink
        ),
        .executableTarget(
            name: "SideloadMenu",
            dependencies: ["SideloadCore"],
            swiftSettings: releaseSize,
            linkerSettings: releaseLink
        ),
        .testTarget(
            name: "SideloadCoreTests",
            dependencies: ["SideloadCore", "sideload", "SideloadMenu"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
