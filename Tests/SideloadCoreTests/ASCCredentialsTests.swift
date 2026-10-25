import CryptoKit
import Foundation
import Testing

@testable import SideloadCore

@Suite("portal API key")
struct ASCCredentialsTests {
    private func load(_ paths: Paths) -> Result<ASCCredentials, SideloadError> {
        Result { try ASCCredentials.load(paths) }.mapError { $0 as! SideloadError }
    }

    private func code(_ paths: Paths) -> String? {
        if case .failure(let e) = load(paths) { return e.code }
        return nil
    }

    @Test("loads key.json and the key file")
    func loads() async throws {
        try await withPortalHome { home in
            let creds = try ASCCredentials.load(home.paths)
            #expect(creds.keyId == testKeyId)
            #expect(creds.issuerId == testIssuerId)
            #expect(creds.role == "Developer")
            #expect(creds.privateKey.reveal { $0 } == home.pem)
        }
    }

    @Test("the key never shows in a description or a dump")
    func secretIsOpaque() async throws {
        try await withPortalHome { home in
            let creds = try ASCCredentials.load(home.paths)
            let body = try #require(home.pem.split(separator: "\n").dropFirst().first.map(String.init))
            for text in [String(describing: creds), String(reflecting: creds), "\(creds.privateKey)"] {
                #expect(!text.contains(body))
            }
            var dumped = ""
            dump(creds, to: &dumped)
            #expect(!dumped.contains(body))
            #expect("\(creds.privateKey)" == "<redacted>")
        }
    }

    @Test("a missing asc directory, key.json or key file is PORTAL_NOT_CONFIGURED")
    func notConfigured() async throws {
        try await withTestHome { paths, _ in
            #expect(code(paths) == "PORTAL_NOT_CONFIGURED")
            try FileManager.default.createDirectory(
                atPath: paths.asc, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            #expect(code(paths) == "PORTAL_NOT_CONFIGURED", "no key.json")
        }
        try await withPortalHome { home in
            try FileManager.default.removeItem(atPath: home.paths.asc + "/AuthKey_\(testKeyId).p8")
            #expect(code(home.paths) == "PORTAL_NOT_CONFIGURED", "no key file")
        }
    }

    @Test("loose modes on the directory or either file are ASC_KEY_PERMISSIONS")
    func permissions() async throws {
        try await withPortalHome { home in
            chmod(home.paths.asc, 0o755)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
            chmod(home.paths.asc, 0o700)
            chmod(home.paths.asc + "/key.json", 0o644)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
            chmod(home.paths.asc + "/key.json", 0o600)
            chmod(home.paths.asc + "/AuthKey_\(testKeyId).p8", 0o640)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
            chmod(home.paths.asc + "/AuthKey_\(testKeyId).p8", 0o600)
            #expect(code(home.paths) == nil)
        }
    }

    @Test("symlinks are refused, for the directory and for the files")
    func symlinks() async throws {
        try await withPortalHome { home in
            let target = home.paths.tmp + "/real-key"
            try writeSecret(target, Data(home.pem.utf8))
            let keyPath = home.paths.asc + "/AuthKey_\(testKeyId).p8"
            try FileManager.default.removeItem(atPath: keyPath)
            try FileManager.default.createSymbolicLink(atPath: keyPath, withDestinationPath: target)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
        }
        try await withTestHome { paths, _ in
            let real = paths.tmp + "/real-asc"
            try FileManager.default.createDirectory(
                atPath: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(atPath: paths.asc, withDestinationPath: real)
            #expect(code(paths) == "ASC_KEY_PERMISSIONS")
        }
    }

    @Test("the key file name is a bare AuthKey_<id>.p8", arguments: [
        "../AuthKey_ABCDE12345.p8", "/etc/hosts", "AuthKey_abcde12345.p8", "AuthKey_ABCDE12345.pem", "sub/AuthKey_ABCDE12345.p8",
        "AuthKey_ABCDE12345.p8 ", "",
    ])
    func keyFileName(name: String) async throws {
        try await withTestHome { paths, _ in
            try writeAsc(paths, pem: P256.Signing.PrivateKey().pemRepresentation, keyFile: name)
            #expect(code(paths) == "ASC_KEY_INVALID")
        }
    }

    @Test("bad key.json shapes are ASC_KEY_INVALID and never echoed")
    func badJSON() async throws {
        let echo = "ECHOMARKER-should-not-appear"
        let bodies: [String] = [
            "{ not json \(echo)", "[\"\(echo)\"]",
            #"{"keyId":"\#(echo)","issuerId":"\#(testIssuerId)","keyFile":"AuthKey_\#(testKeyId).p8"}"#,
            #"{"keyId":"\#(testKeyId)","issuerId":"\#(echo)","keyFile":"AuthKey_\#(testKeyId).p8"}"#,
            #"{"keyId":"\#(testKeyId)","issuerId":"\#(testIssuerId)","keyFile":"\#(echo)"}"#,
            #"{"keyId":7,"issuerId":"\#(testIssuerId)","keyFile":"AuthKey_\#(testKeyId).p8"}"#,
        ]
        for body in bodies {
            try await withPortalHome { home in
                try writeSecret(home.paths.asc + "/key.json", Data(body.utf8))
                let result = load(home.paths)
                guard case .failure(let error) = result else {
                    Issue.record("accepted \(body)")
                    return
                }
                #expect(error.code == "ASC_KEY_INVALID")
                #expect(!error.message.contains(echo) && !(error.fix ?? "").contains(echo))
            }
        }
    }

    @Test("a key file that is too large or not a P-256 PEM key is ASC_KEY_INVALID and never echoed")
    func badKey() async throws {
        let echo = "ECHOMARKER-key-bytes"
        let other = P256.Signing.PrivateKey().publicKey.pemRepresentation
        for content in [echo, String(repeating: "A", count: 5000), other, ""] {
            try await withPortalHome { home in
                try writeSecret(home.paths.asc + "/AuthKey_\(testKeyId).p8", Data(content.utf8))
                guard case .failure(let error) = load(home.paths) else {
                    Issue.record("accepted a bad key file")
                    return
                }
                #expect(error.code == "ASC_KEY_INVALID")
                #expect(!error.message.contains(echo) && !(error.fix ?? "").contains(echo))
            }
        }
    }

    @Test("a FIFO in place of a key file is refused without hanging")
    func fifo() async throws {
        try await withPortalHome { home in
            let path = home.paths.asc + "/AuthKey_\(testKeyId).p8"
            try FileManager.default.removeItem(atPath: path)
            #expect(mkfifo(path, 0o600) == 0)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
        }
        try await withPortalHome { home in
            let path = home.paths.asc + "/key.json"
            try FileManager.default.removeItem(atPath: path)
            #expect(mkfifo(path, 0o600) == 0)
            #expect(code(home.paths) == "ASC_KEY_PERMISSIONS")
        }
    }

    @Test("a role that is not word-shaped is dropped, a missing one is nil")
    func role() async throws {
        try await withPortalHome(role: "x\"<script>") { home in
            let role = try ASCCredentials.load(home.paths).role
            #expect(role == nil)
        }
        try await withPortalHome(role: nil) { home in
            let role = try ASCCredentials.load(home.paths).role
            #expect(role == nil)
        }
        try await withPortalHome(role: "App Manager") { home in
            let role = try ASCCredentials.load(home.paths).role
            #expect(role == "App Manager")
        }
    }
}
