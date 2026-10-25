import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

// The fake server sends names, serial numbers, profile content, Apple error text, and the run holds a key and a
// bearer token. None of it may appear in the printed object, in errors, or in logs/commands.log, on any path.

private struct Scenario: Sendable {
    let name: String
    let script: FakeHTTPTransport.Script

    static func status(_ code: Int) -> Scenario {
        Scenario(name: "http \(code)") { _ in errorResponse(code, code: "SOME_CODE", detail: Canary.detail) }
    }
}

private let scenarios: [Scenario] = [
    Scenario(
        name: "success",
        script: routed(
            certificates: [certRow("C1"), certRow("C2", content: TestCerts.expired)],
            bundleIds: [bundleRow("B1", "com.example.app"), bundleRow("B2", Canary.foreignIdentifier)],
            devices: [deviceRow("D1", udid: savedUdid("1")), deviceRow("D2", udid: savedUdid("2"))],
            profiles: [profileRow("P1")])),
    .status(401), .status(403), .status(404), .status(429), .status(500),
    Scenario(name: "bad json") { _ in textResponse("{ \(Canary.detail) not json \(Canary.certName)") },
    Scenario(name: "timeout") { _ in throw HTTPTransportError.timedOut },
    Scenario(name: "network") { _ in throw HTTPTransportError.failed },
    Scenario(name: "off-host next") { _ in okPage([], next: "https://evil.example/v1/devices?\(Canary.detail)") },
    Scenario(name: "free team") { request in
        try routed(
            certificates: [certRow("C1", content: TestCerts.free)], devices: [deviceRow("D1", udid: savedUdid("1"))])(request)
    },
    Scenario(name: "other team") { request in
        try routed(bundleIds: [bundleRow("B1", Canary.foreignIdentifier, seed: "OTHERTEAM1")])(request)
    },
    Scenario(name: "forbidden certificates") { request in
        request.url.path == "/v1/certificates"
            ? errorResponse(403, detail: Canary.detail)
            : try routed(devices: [deviceRow("D1", udid: savedUdid("1"))], profiles: [profileRow("P1")])(request)
    },
]

@Suite("portal leaks nothing")
struct PortalLeakTests {
    @Test("canary strings, the key and the token never reach stdout or the log", arguments: scenarios.map(\.name))
    func noLeaks(name: String) async throws {
        let scenario = try #require(scenarios.first { $0.name == name })
        try await withPortalHome(config: Config(devices: ["iphone": SavedDevice(udid: savedUdid("1"))], bundleIdPrefix: "com.example")) { home in
            let transport = FakeHTTPTransport(scenario.script)
            let fileLog = ProgressLog.makeFileOnly(home: home.paths, clock: FixedClock(testNow))
            let stderr = LogLines()
            let (services, _) = portalServices(
                home.paths, http: transport,
                keychain: FakeKeychain([try keychainCert(TestCerts.paid)]),
                log: { line in
                    stderr.log(line)
                    fileLog(line)
                })
            let envelope = await run(argv: ["portal", "--show-identifiers"], services: services)
            var surfaces = [try envelope.printed().text, stderr.all.joined(separator: "\n")]
            surfaces.append((try? String(contentsOfFile: home.paths.commandsLog, encoding: .utf8)) ?? "")
            surfaces.append(String(describing: envelope))
            surfaces.append(envelope.errors.map { "\($0.code) \($0.message) \($0.fix ?? "")" }.joined(separator: "\n"))

            let pemBody = home.pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.map(String.init)
            let tokens = Set(transport.requests.compactMap { $0.bearer?.reveal { $0 } })
            var secrets = Canary.all.filter { $0 != Canary.foreignIdentifier } + pemBody + tokens
            // --show-identifiers is the one opt-in that prints a third-party identifier.
            secrets += [savedUdid("1"), savedUdid("2"), "TEST000001", "Test 000001"]
            for surface in surfaces {
                for secret in secrets where !secret.isEmpty {
                    #expect(!surface.contains(secret), "\(name): leaked a canary string")
                }
            }
            #expect(!surfaces[0].contains("BEGIN") && !surfaces[0].contains("eyJ"))
        }
    }

    @Test("without --show-identifiers the third-party identifier stays out too")
    func identifierHidden() async throws {
        try await withPortalHome(config: Config(bundleIdPrefix: "com.example")) { home in
            let transport = FakeHTTPTransport(scenarios[0].script)
            let (services, _) = portalServices(home.paths, http: transport)
            let envelope = await run(argv: ["portal"], services: services)
            let text = try envelope.printed().text
            #expect(!text.contains(Canary.foreignIdentifier))
        }
    }
}
