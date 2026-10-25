import Foundation
import Testing

@testable import SideloadCore

// Golden envelopes of `provision` without `--renew`, recorded (`SIDELOAD_RECORD_GOLDEN=1 swift test --filter
// ProvisionGolden`) before the `--renew` result and error model was reworked. Byte equality afterwards proves a run
// without `--renew` prints exactly what it printed before. The fixture folder is under Fixtures/provision-golden.

private let recording = ProcessInfo.processInfo.environment["SIDELOAD_RECORD_GOLDEN"] != nil

private func goldenPath(_ name: String) -> String { fixture("provision-golden/\(name).json") }

/// The envelope as the CLI prints it, with the temp home named `<HOME>` (it should not appear at all).
func goldenText(_ out: Envelope, home: String) throws -> String {
    try out.printed().text.replacingOccurrences(of: home, with: "<HOME>")
}

@Suite("provision: golden envelopes without --renew")
struct ProvisionGoldenTests {
    @Test("every fault renders exactly the recorded envelope", arguments: Fault.allCases.filter { !$0.renewOnly })
    func matches(fault: Fault) async throws {
        try await withFaultWorld(fault) { w, scenario in
            let out = await runFault(w, scenario)
            if let code = scenario.code {
                #expect(out.errors.first?.code == code, "\(fault)")
            } else {
                #expect(out.ok, "\(fault): \(out.errors)")
            }
            let text = try goldenText(out, home: w.paths.home)
            #expect(!text.contains(w.paths.home))
            let path = goldenPath(fault.rawValue)
            if recording {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
                return
            }
            let golden = try String(contentsOfFile: path, encoding: .utf8)
            #expect(text == golden, "\(fault)")
        }
    }

    @Test("every golden file belongs to a fault")
    func coversGoldens() throws {
        let files = listing(URL(fileURLWithPath: goldenPath("x")).deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        #expect(Fault.allCases.filter { !$0.renewOnly }.map(\.rawValue).sorted() == files)
    }
}
