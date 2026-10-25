import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import SideloadCore

// Fakes for `portal`. Nothing here opens a socket: the transport is a script, and the API key is a throwaway
// P-256 key generated at runtime (the real key under $SIDELOAD_HOME is never read by any test).

/// Records every request and replays a script. A script can throw an `HTTPTransportError` to simulate failures.
final class FakeHTTPTransport: HTTPTransport {
    typealias Script = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let script: Script
    private let recorded = Mutex<[HTTPRequest]>([])

    init(_ script: @escaping Script) {
        self.script = script
    }

    /// Replays `results` in order; once exhausted, repeats the last one.
    convenience init(results: [Result<HTTPResponse, HTTPTransportError>]) {
        let next = Mutex(0)
        self.init { _ in
            let i = next.withLock { n in
                defer { n += 1 }
                return n
            }
            return try results[min(i, results.count - 1)].get()
        }
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try script(request)
    }
}

/// A clock the test moves by hand.
final class StepClock: WallClock {
    private let instant: Mutex<Date>

    init(_ start: Date = testNow) {
        instant = Mutex(start)
    }

    func now() -> Date { instant.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        instant.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Collects the waits the client asked for instead of sleeping.
final class SleepLog: Sendable {
    private let waits = Mutex<[Duration]>([])

    var durations: [Duration] { waits.withLock { $0 } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] d in waits.withLock { $0.append(d) } }
    }
}

/// Lines passed to `Services.log`.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    var log: @Sendable (String) -> Void {
        { [self] line in lines.withLock { $0.append(line) } }
    }
}

// MARK: Responses

func okPage(_ rows: [JSONValue], next: String? = nil) -> HTTPResponse {
    var root: [String: JSONValue] = ["data": .array(rows)]
    if let next { root["links"] = ["self": "https://api.appstoreconnect.apple.com/v1/x", "next": .string(next)] }
    return jsonResponse(.object(root))
}

func jsonResponse(_ value: JSONValue, status: Int = 200, retryAfter: Int? = nil) -> HTTPResponse {
    HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data(), retryAfter: retryAfter)
}

func textResponse(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(text.utf8))
}

func errorResponse(_ status: Int, code: String = "NOT_AUTHORIZED", detail: String = "detail text") -> HTTPResponse {
    jsonResponse(
        ["errors": [["status": .string(String(status)), "code": .string(code), "title": "title text", "detail": .string(detail)]]],
        status: status)
}

/// `certificateContent` as the API sends it: base64 of the DER on one line.
func certContent(_ base64: String) -> String {
    String(base64.filter { !$0.isWhitespace })
}

func resource(_ type: String, _ id: String, _ attributes: [String: JSONValue]) -> JSONValue {
    ["type": .string(type), "id": .string(id), "attributes": .object(attributes)]
}

/// Strings that stand for the data `portal` must never print. The fake server sends them on purpose.
enum Canary {
    static let certName = "Canary Cert Name Zebra"
    static let certSerial = "CANARYSERIAL0099"
    static let deviceName = "Canary Phone Zebra"
    static let profileName = "Canary Profile Zebra"
    static let appName = "Canary App Zebra"
    static let profileContent = "Q0FOQVJZUFJPRklMRUNPTlRFTlQ="
    static let foreignIdentifier = "com.zebra.secretapp"
    static let detail = "Canary Apple Detail Zebra"
    static var all: [String] {
        [certName, certSerial, deviceName, profileName, appName, profileContent, foreignIdentifier, detail]
    }
}

func certRow(
    _ id: String, type: String = "DEVELOPMENT", content: String = TestCerts.paid,
    expires: String = "2027-10-16T22:39:42.000+0000"
) -> JSONValue {
    resource(
        "certificates", id,
        [
            "certificateType": .string(type), "certificateContent": .string(certContent(content)),
            "activated": true, "expirationDate": .string(expires), "platform": "IOS",
            "name": .string(Canary.certName), "displayName": .string(Canary.certName),
            "serialNumber": .string(Canary.certSerial),
        ])
}

func bundleRow(_ id: String, _ identifier: String, seed: String = Team.id) -> JSONValue {
    resource(
        "bundleIds", id,
        [
            "identifier": .string(identifier), "platform": "IOS", "seedId": .string(seed),
            "name": .string(Canary.appName),
        ])
}

func deviceRow(_ id: String, udid: String, cls: String = "IPHONE", added: String = "2026-03-04T10:00:00.000+0000")
    -> JSONValue
{
    resource(
        "devices", id,
        [
            "udid": .string(udid), "deviceClass": .string(cls), "model": "iPhone 17", "platform": "IOS",
            "status": "ENABLED", "addedDate": .string(added), "name": .string(Canary.deviceName),
        ])
}

func profileRow(
    _ id: String, type: String = "IOS_APP_DEVELOPMENT", state: String = "ACTIVE",
    created: String = "2026-03-04T10:00:00.000+0000", expires: String = "2027-03-04T10:00:00.000+0000"
) -> JSONValue {
    resource(
        "profiles", id,
        [
            "profileType": .string(type), "profileState": .string(state), "platform": "IOS",
            "createdDate": .string(created), "expirationDate": .string(expires),
            "name": .string(Canary.profileName), "profileContent": .string(Canary.profileContent),
        ])
}

/// A routing script: rows per list path, no paging.
func routed(
    certificates: [JSONValue] = [], bundleIds: [JSONValue] = [], devices: [JSONValue] = [],
    profiles: [JSONValue] = []
) -> FakeHTTPTransport.Script {
    { request in
        switch request.url.path {
        case "/v1/certificates": return okPage(certificates)
        case "/v1/bundleIds": return okPage(bundleIds)
        case "/v1/devices": return okPage(devices)
        case "/v1/profiles": return okPage(profiles)
        default: return errorResponse(404)
        }
    }
}

// MARK: Key material

let testKeyId = "ABCDE12345"
let testIssuerId = "11111111-2222-3333-4444-555555555555"

struct PortalHome {
    let paths: Paths
    /// The throwaway key in PEM form, as written to the key file.
    let pem: String
}

/// A temp `$SIDELOAD_HOME` with `asc/key.json` and a key file holding a fresh throwaway P-256 key.
func withPortalHome<T>(
    config: Config? = Config(), role: String? = "Developer", _ body: (PortalHome) async throws -> T
) async throws -> T {
    try await withTestHome(config: config) { paths, _ in
        let pem = P256.Signing.PrivateKey().pemRepresentation
        try writeAsc(paths, pem: pem, role: role)
        return try await body(PortalHome(paths: paths, pem: pem))
    }
}

func writeAsc(_ paths: Paths, pem: String, role: String? = "Developer", keyFile: String = "AuthKey_\(testKeyId).p8") throws {
    try FileManager.default.createDirectory(
        atPath: paths.asc, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    chmod(paths.asc, 0o700)
    var fields: [String: JSONValue] = [
        "keyId": .string(testKeyId), "issuerId": .string(testIssuerId), "keyFile": .string(keyFile),
    ]
    if let role { fields["role"] = .string(role) }
    try writeSecret(paths.asc + "/key.json", Data(try JSONEncoder().encode(JSONValue.object(fields))))
    if !keyFile.contains("/") && !keyFile.isEmpty { try writeSecret(paths.asc + "/" + keyFile, Data(pem.utf8)) }
}

func writeSecret(_ path: String, _ data: Data, mode: mode_t = 0o600) throws {
    FileManager.default.createFile(atPath: path, contents: data)
    chmod(path, mode)
}

func portalServices(
    _ paths: Paths, http: any HTTPTransport, keychain: FakeKeychain = FakeKeychain(), now: Date = testNow,
    log: @escaping @Sendable (String) -> Void = { _ in },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
) -> (services: Services, runner: FakeRunner) {
    let runner = FakeRunner()
    return (
        Services(
            runner: runner, fs: FakeFileSystem.free(gb: 50), clock: FixedClock(now), keychain: keychain, home: paths,
            log: log, http: http, sleep: sleep),
        runner
    )
}

extension Envelope {
    /// The `sections[name]` object of a portal result.
    func section(_ name: String) -> JSONValue? { json["sections"]?[name] }
}
