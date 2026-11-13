import Foundation
import Testing

/// AGENTS.md "Code": SideloadCore and the `sideload` CLI import no AppKit (the menu bar app is the only UI
/// target), and nothing reaches the pasteboard.
@Suite("import boundary")
struct ImportBoundaryTests {
    private func swiftFiles(_ target: String) throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/\(target)")
        let walker = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!files.isEmpty, "no sources under \(target)")
        return files
    }

    @Test("SideloadCore and the CLI import no AppKit and never touch the pasteboard")
    func coreAndCLIStayFree() throws {
        for target in ["SideloadCore", "sideload"] {
            for (path, text) in try swiftFiles(target) {
                for word in [
                    "import AppKit", "NSPasteboard", "pbcopy", "pbpaste",
                ] {
                    #expect(!text.contains(word), "\(path) mentions \(word)")
                }
            }
        }
    }
}
