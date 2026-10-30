import CryptoKit
import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

private struct Outcome {
    var envelope: Envelope
    var text: String
    var json: JSONValue
    var transport: FakeHTTPTransport
    var runner: FakeRunner
    var logLines: [String]
    var commandsLog: String
    var pem: String

    var code: String? { envelope.errors.first?.code }
}

private func invoke(
    _ argv: [String], config: Config? = Config(bundleIdPrefix: "com.example"), configured: Bool = true,
    keychain: FakeKeychain = FakeKeychain(), script: @escaping FakeHTTPTransport.Script
) async throws -> Outcome {
    try await withTestHome(config: config) { paths, _ in
        let pem = P256.Signing.PrivateKey().pemRepresentation
        if configured { try writeAsc(paths, pem: pem) }
        let transport = FakeHTTPTransport(script)
        let lines = LogLines()
        let fileLog = ProgressLog.makeFileOnly(home: paths, clock: FixedClock(testNow))
        let (services, runner) = portalServices(
            paths, http: transport, keychain: keychain,
            log: { line in
                lines.log(line)
                fileLog(line)
            })
        let envelope = await run(argv: argv, services: services)
        let (text, json) = try envelope.printed()
        let commandsLog = (try? String(contentsOfFile: paths.commandsLog, encoding: .utf8)) ?? ""
        return Outcome(
            envelope: envelope, text: text, json: json, transport: transport, runner: runner, logLines: lines.all,
            commandsLog: commandsLog, pem: pem)
    }
}

private let allRows = routed(
    certificates: [certRow("CERT000001"), certRow("CERT000002", content: TestCerts.expired)],
    bundleIds: [bundleRow("B1", "com.example.app"), bundleRow("B2", Canary.foreignIdentifier)],
    devices: [deviceRow("D1", udid: savedUdid("1"))], profiles: [profileRow("P1")])

@Suite("portal command")
struct PortalCommandTests {
    @Test("no argument lists all four resources in order, with GET requests only")
    func all() async throws {
        let out = try await invoke(["portal"], keychain: FakeKeychain([try keychainCert(TestCerts.paid)]), script: allRows)
        #expect(out.envelope.ok, "\(out.envelope.errors)")
        #expect(out.envelope.exitCode == 0)
        #expect(out.json["command"] == "portal" && out.json["team"] == "7AGMPUPP64")
        #expect(out.json["key"] == ["role": "Developer", "idTail": "2345"])
        #expect(out.transport.requests.map(\.url.path) == ["/v1/certificates", "/v1/bundleIds", "/v1/devices", "/v1/profiles"])
        for name in ["certificates", "bundleIds", "devices", "profiles"] {
            #expect(out.envelope.section(name)?["status"] == "ok", "\(name)")
        }
        #expect(out.envelope.section("certificates")?["count"] == 2)
        #expect(out.runner.calls.isEmpty, "no subprocess")
        #expect(out.json["summary"]?["certificatesNotInKeychain"] == 1)
        #expect(out.json["summary"]?["otherPrefixBundleIds"] == 1)
    }

    @Test("one positional lists one resource", arguments: PortalResource.allCases)
    func one(resource: PortalResource) async throws {
        let out = try await invoke(["portal", resource.cliName], script: allRows)
        #expect(out.envelope.ok)
        #expect(out.transport.requests.map(\.url.path) == [resource.path])
        for other in PortalResource.allCases where other != resource {
            #expect(out.envelope.section(other.rawValue)?["status"] == "skipped")
        }
    }

    @Test("--show-identifiers reaches the report")
    func showIdentifiers() async throws {
        let hidden = try await invoke(["portal", "bundle-ids"], script: allRows)
        #expect(!hidden.text.contains(Canary.foreignIdentifier))
        let shown = try await invoke(["portal", "bundle-ids", "--show-identifiers"], script: allRows)
        #expect(shown.text.contains(Canary.foreignIdentifier))
        #expect(!shown.text.contains(Canary.appName))
        let flagFirst = try await invoke(["portal", "--show-identifiers"], script: allRows)
        #expect(flagFirst.text.contains(Canary.foreignIdentifier))
        #expect(flagFirst.transport.requests.count == 4)
    }

    @Test("usage errors make no request and read no key", arguments: [
        ["portal", "bogus"], ["portal", "devices", "profiles"], ["portal", "--nope"], ["portal", "--yes"],
        ["portal", "--show-identifiers=1"], ["portal", "--device", "x"], ["portal", "bundleIds"],
    ])
    func usage(argv: [String]) async throws {
        let out = try await invoke(argv, script: allRows)
        #expect(out.code == "USAGE", "\(argv)")
        #expect(out.envelope.exitCode == 1)
        #expect(out.transport.requests.isEmpty)
    }

    @Test("without an asc key it stops before any request")
    func notConfigured() async throws {
        let out = try await invoke(["portal"], configured: false, script: allRows)
        #expect(out.code == "PORTAL_NOT_CONFIGURED")
        #expect(out.transport.requests.isEmpty)
        #expect(out.envelope.errors.first?.fix?.isEmpty == false)
    }

    @Test("a key with loose permissions stops before any request")
    func loosePermissions() async throws {
        try await withTestHome { paths, _ in
            try writeAsc(paths, pem: P256.Signing.PrivateKey().pemRepresentation)
            chmod(paths.asc + "/AuthKey_\(testKeyId).p8", 0o644)
            let transport = FakeHTTPTransport(allRows)
            let (services, _) = portalServices(paths, http: transport)
            let envelope = await run(argv: ["portal"], services: services)
            #expect(envelope.errorCodes == ["ASC_KEY_PERMISSIONS"])
            #expect(transport.requests.isEmpty)
        }
    }

    @Test("an invalid config.json is reported before any request")
    func badConfig() async throws {
        try await withTestHome { paths, _ in
            try writeAsc(paths, pem: P256.Signing.PrivateKey().pemRepresentation)
            try writeSecret(paths.config, Data("{ nope".utf8))
            let transport = FakeHTTPTransport(allRows)
            let (services, _) = portalServices(paths, http: transport)
            let envelope = await run(argv: ["portal"], services: services)
            #expect(envelope.errorCodes == ["CONFIG_INVALID"])
            #expect(transport.requests.isEmpty)
        }
    }

    @Test("savedLocally is null without a config.json")
    func noConfigFile() async throws {
        let out = try await invoke(["portal", "devices"], config: nil, script: allRows)
        #expect(out.envelope.section("devices")?["items"]?.array?.first?["savedLocally"] == .null)
    }

    @Test("a forbidden list does not hide the others and the exit is 1")
    func partial() async throws {
        let out = try await invoke(["portal"]) { request in
            request.url.path == "/v1/certificates" ? errorResponse(403, code: "FORBIDDEN_ERROR") : try allRows(request)
        }
        #expect(!out.envelope.ok && out.envelope.exitCode == 1)
        #expect(out.envelope.errorCodes == ["ASC_FORBIDDEN"])
        #expect(out.envelope.section("certificates")?["status"] == "error")
        #expect(out.envelope.section("devices")?["status"] == "ok")
        #expect(out.envelope.section("profiles")?["count"] == 1)
        #expect(out.envelope.errors.first?.fix?.contains("Admin") == true)
    }

    @Test("a cancelled retry wait ends the run as CANCELLED without trying the other lists")
    func cancelled() async throws {
        try await withPortalHome { home in
            let transport = FakeHTTPTransport { _ in errorResponse(500) }
            let (services, _) = portalServices(home.paths, http: transport, sleep: { _ in throw CancellationError() })
            let envelope = await run(argv: ["portal"], services: services)
            #expect(envelope.errorCodes == ["CANCELLED"])
            #expect(envelope.exitCode == 1)
            #expect(transport.requests.count == 1)
        }
    }

    @Test("output is one JSON object with the envelope keys")
    func shape() async throws {
        let out = try await invoke(["portal"], script: allRows)
        #expect(out.text.hasSuffix("\n") && !out.text.dropLast().contains("\n"))
        for key in ["ok", "command", "errors", "team", "key", "sections", "summary", "warnings"] {
            #expect(out.json[key] != nil, "\(key)")
        }
    }

    @Test("progress lines name the path and page only")
    func progress() async throws {
        let out = try await invoke(["portal", "devices"], script: allRows)
        #expect(out.logLines == ["portal: GET /v1/devices page 1"])
        #expect(out.commandsLog.contains("portal: GET /v1/devices page 1"))
    }

    @Test("help lists portal as built, with its usage line")
    func help() async throws {
        let out = try await invoke(["help"], script: allRows)
        #expect(out.json["built"] == ["doctor", "device", "canary", "ledger", "portal", "export-cert", "status", "inspect", "fetch", "provision", "sign", "install", "refresh", "app", "slot", "updates", "clean"])
        let usage = out.json["usage"]?.array?.compactMap(\.string) ?? []
        #expect(usage.contains { $0.hasPrefix("portal") && $0.contains("--show-identifiers") })
        #expect(out.json["commands"]?.array?.count == 17)
        #expect(out.transport.requests.isEmpty)
    }
}
