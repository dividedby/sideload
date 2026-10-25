import Foundation
import Testing

@testable import SideloadCore
@testable import sideload

private func sourceFiles() throws -> [(path: String, text: String)] {
    // Tests/SideloadCoreTests/<this file> -> repo root -> Sources
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")
    let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var files: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
    }
    #expect(files.count > 20, "the scan must actually see the sources")
    return files
}

@Suite("portal is read-only")
struct PortalNoWriteTests {
    @Test("no source mentions a mutating HTTP method, a request body or an upload")
    func noMutatingCode() throws {
        let banned = try NSRegularExpression(
            pattern: #"\b(POST|PUT|PATCH|DELETE)\b|httpBody|httpBodyStream|uploadTask|downloadTask|\.upload\("#)
        for (path, text) in try sourceFiles() {
            let hits = banned.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            #expect(hits == 0, "\(path) mentions a mutating HTTP construct")
        }
    }

    @Test("the one place that sets an HTTP method sets GET")
    func oneMethod() throws {
        var assignments: [String] = []
        for (path, text) in try sourceFiles() {
            for line in text.split(separator: "\n") where line.contains("httpMethod") {
                assignments.append("\(URL(fileURLWithPath: path).lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        // `get` and `download` each set GET explicitly.
        #expect(assignments == Array(repeating: #"HTTPTransport.swift: urlRequest.httpMethod = "GET""#, count: 2))
    }

    @Test("URLSession and URLRequest are used in the transport file only")
    func networkConfined() throws {
        for (path, text) in try sourceFiles() where !path.hasSuffix("/Portal/HTTPTransport.swift") {
            #expect(!text.contains("URLSession(") && !text.contains("URLSession.") && !text.contains("URLRequest"), "\(path)")
        }
    }

    @Test("a request has a URL and a bearer token, nothing else")
    func requestShape() {
        let labels = Mirror(reflecting: HTTPRequest(url: URL(string: "https://x.invalid/")!, bearer: ASCSecret("t")))
            .children.compactMap(\.label)
        #expect(labels == ["url", "bearer"])
    }

    @Test("every request of a full run is a bounded GET to an allowed list, with a token and no name fields")
    func fullRun() async throws {
        try await withPortalHome(config: Config(bundleIdPrefix: "com.example")) { home in
            let transport = FakeHTTPTransport { request in
                if request.url.path == "/v1/devices", request.url.query?.contains("cursor") != true {
                    return okPage(
                        [deviceRow("D1", udid: savedUdid("1"))],
                        next: "https://api.appstoreconnect.apple.com/v1/devices?cursor=AQ&limit=200")
                }
                return try routed(profiles: [profileRow("P1")])(request)
            }
            let (services, runner) = portalServices(home.paths, http: transport)
            let envelope = await run(argv: ["portal"], services: services)
            #expect(envelope.ok)
            #expect(runner.calls.isEmpty)

            let requests = transport.requests
            #expect(requests.count == 5)
            for request in requests {
                let parts = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
                #expect(parts.scheme == "https" && parts.host == "api.appstoreconnect.apple.com")
                #expect(PortalClient.allowedPaths.contains(parts.path))
                let names = (parts.queryItems ?? []).map(\.name)
                #expect(names.contains("limit"))
                if !names.contains("cursor") {
                    let fields = try #require(parts.queryItems?.first { $0.name.hasPrefix("fields[") }?.value)
                    for banned in ["name", "displayName", "profileContent", "serialNumber"] {
                        #expect(!fields.split(separator: ",").contains(Substring(banned)))
                    }
                }
                #expect(request.bearer?.reveal { $0.split(separator: ".").count } == 3, "a JWT is attached")
            }
            // One token per run.
            #expect(Set(requests.compactMap { $0.bearer?.reveal { $0 } }).count == 1)
        }
    }
}
