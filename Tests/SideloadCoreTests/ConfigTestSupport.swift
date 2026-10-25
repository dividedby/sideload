import Darwin
import Foundation

@testable import SideloadCore

// Fake IDs are assembled at runtime so no UDID-shaped literal is committed.
func savedUdid(_ seed: String = "1") -> String {
    let tail = ("00" + String(repeating: "A", count: max(0, 14 - seed.count)) + seed).uppercased()
    return ["0000", "8110"].joined() + "-" + String(tail.prefix(16))
}

func savedCoreId(_ seed: String = "1") -> String {
    ["AAAAAAA" + seed, "BBBB", "CCCC", "DDDD", "EEEEEEEE" + "EEEE"].joined(separator: "-")
}

func iphoneConfig(bundleIdPrefix: String? = nil) -> Config {
    Config(
        devices: ["iphone": SavedDevice(udid: savedUdid("1"), coreDeviceId: savedCoreId("1"), platform: "ios")],
        bundleIdPrefix: bundleIdPrefix)
}

/// Runs `body` against a fresh temp `$SIDELOAD_HOME` (never the real one), created like the CLI would,
/// and removes it afterwards.
func withTestHome<T>(
    config: Config? = nil, _ body: (Paths, ConfigStore) async throws -> T
) async throws -> T {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = Paths(home: dir.path)
    try paths.ensureHome()
    let store = ConfigStore(paths: paths)
    if let config { try await store.update { $0 = config } }
    return try await body(paths, store)
}

func modeOf(_ path: String) -> Int {
    var st = stat()
    guard stat(path, &st) == 0 else { return -1 }
    return Int(st.st_mode & 0o777)
}

func listing(_ path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
}

func errorCode(of error: any Error) -> String? {
    (error as? SideloadError)?.code
}
