import CryptoKit
import Darwin
import Foundation
import Testing

@testable import SideloadCore

// Fake IDs are assembled at runtime so no UDID-shaped literal is committed.
private func fakeUdid(_ seed: String = "1") -> String {
    let tail = ("00" + String(repeating: "A", count: max(0, 14 - seed.count)) + seed).uppercased()
    return ["0000", "8110"].joined() + "-" + String(tail.prefix(16))
}

private func fakeCoreId(_ seed: String = "1") -> String {
    ["AAAAAAA" + seed, "BBBB", "CCCC", "DDDD", "EEEEEEEE" + "EEEE"].joined(separator: "-")
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var writes: [String] { lock.withLock { storage } }
    var writer: Emitter.Writer { { [self] s in lock.withLock { storage.append(s) } } }
}

private func decode(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private let redactor = Redactor()

@Suite("output")
struct OutputTests {
    @Test("writes exactly one JSON object ending in a newline")
    func singleObject() throws {
        let cap = Capture()
        try Emitter(write: cap.writer).emit(.result("doctor", ["checks": []]))
        #expect(cap.writes.count == 1)
        let text = try #require(cap.writes.first)
        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false)
        let obj = try decode(text)
        #expect(obj == ["ok": true, "command": "doctor", "checks": [], "errors": []])
    }

    @Test("refuses a second emit")
    func secondEmitRefused() async {
        let cap = Capture()
        let emitter = Emitter(write: cap.writer)
        _ = try? emitter.emit(.result("x"))
        #expect(emitter.emitted)
        await #expect(processExitsWith: .failure) {
            let e = Emitter(write: { _ in })
            try e.emit(.result("x"))
            try e.emit(.result("x"))
        }
        #expect(cap.writes.count == 1)
    }

    @Test("ignores EPIPE from a reader that closed early, throws other write errors")
    func epipe() throws {
        signal(SIGPIPE, SIG_IGN)
        func closedPipeWriter() -> Emitter.Writer {
            var fds: [Int32] = [0, 0]
            #expect(pipe(&fds) == 0)
            close(fds[0])
            return Output.fileDescriptorWriter(fds[1])
        }
        #expect(throws: Never.self) { try Emitter(write: closedPipeWriter()).emit(.result("x")) }
        #expect(try Emitter(write: closedPipeWriter()).emit(.result("x")) == 0)
        #expect(try Emitter(write: closedPipeWriter()).emit(.fail("x", code: "E", message: "m", fix: "f")) == 1)
        let badFd = Output.fileDescriptorWriter(-1)
        #expect(throws: POSIXError.self) { try Emitter(write: badFd).emit(.result("x")) }
    }

    @Test("exit code is 0 iff ok")
    func exitCode() throws {
        let ok = Capture()
        #expect(try Emitter(write: ok.writer).emit(.result("x")) == 0)
        let bad = Capture()
        #expect(try Emitter(write: bad.writer).emit(.fail("x", code: "BOOM", message: "it broke", fix: "fix it")) == 1)
        let text = try #require(bad.writes.first)
        let errors = try #require(decode(text).objectValue?["errors"])
        #expect(errors == [["code": "BOOM", "message": "it broke", "fix": "fix it"]])
    }

    @Test("redacts UDIDs and CoreDevice IDs to the last 4 anywhere in the object")
    func redactsIds() throws {
        let udid = fakeUdid("7")
        let core = fakeCoreId("7")
        let envelope = Envelope.result("x", ["nested": ["list": [.string("id=\(udid)"), .string(core)]], .init(udid): 1])
        let out = try Output.render(envelope)
        #expect(!out.contains(udid))
        #expect(!out.contains(core))
        #expect(out.contains(Redactor.tail4(udid)))
        #expect(out.contains(Redactor.tail4(core)))
    }

    @Test("redacts legacy 40-hex UDIDs but not 64-hex digests")
    func legacyIds() {
        let legacy = "a1b2c3d4e5f60718293a4b5c6d7e8f9012a3b4c5"
        let sha256 = "a1b2c3d4e5f60718293a4b5c6d7e8f9012a3b4c5a1b2c3d4e5f60718293a4b5c6"
        #expect(redactor.redact(legacy) == Redactor.tail4(legacy))
        #expect(redactor.redact(sha256) == sha256)
    }

    @Test("never leaks identity names or emails")
    func identityAndEmail() throws {
        let name = "Apple Development: someone@example.invalid (ABCDE12345)"
        let out = try Output.render(
            .result("x", ["message": .string("No signing certificate \"\(name)\" found"), "other": "mail me at a.b@example.invalid"]))
        #expect(!out.contains("someone"))
        #expect(!out.contains("example.invalid"))
        #expect(out.contains("identity hidden"))
    }

    @Test("masks the user path component")
    func userPath() {
        #expect(redactor.redact("/Users/someone/repo/x") == "/Users/<user>/repo/x")
    }

    // Extra parity cases beyond the Node suite: boundaries, other identity kinds, literals.
    struct BoundaryCase: Sendable {
        let input: String
        let redacted: Bool
    }

    static let boundaryCases: [BoundaryCase] = {
        let id = ["0000", "8110", "-", "00000000AAAAAAAA"].joined()
        return [
            BoundaryCase(input: id, redacted: true),
            BoundaryCase(input: id + "B", redacted: false),  // 17 hex after the dash
            BoundaryCase(input: "a" + id, redacted: false),  // preceded by alphanumeric
            BoundaryCase(input: "-" + id, redacted: false),  // preceded by dash
            BoundaryCase(input: "x" + id.replacingOccurrences(of: "-", with: ""), redacted: false),
        ]
    }()

    @Test("id boundaries match the Node lookarounds", arguments: boundaryCases)
    func boundaries(c: BoundaryCase) {
        #expect((redactor.redact(c.input) != c.input) == c.redacted)
    }

    @Test(
        "identity name kinds are masked",
        arguments: ["Apple Development", "Apple Distribution", "iPhone Developer", "iPhone Distribution", "Developer ID Application"])
    func identityKinds(kind: String) {
        #expect(redactor.redact("\(kind): Someone (ABCDE12345)") == "\(kind) (identity hidden)")
    }

    @Test("caller literals of 8+ characters are masked, shorter ones are not")
    func literals() {
        let r = Redactor(literals: ["custom-id-12345678", "short"])
        #expect(r.redact("see custom-id-12345678 and short") == "see …5678 and short")
    }

    @Test("progress log lines never carry a JWT or a PEM private key")
    func logLinesMaskCredentials() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try ASCToken.make(
            ASCCredentials(keyId: "ABCDE12345", issuerId: "11111111-2222-3333-4444-555555555555", role: nil, privateKey: ASCSecret(key.pemRepresentation)),
            now: testNow
        ).reveal { $0 }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = Paths(home: dir.path)
        try paths.ensureHome()
        ProgressLog.makeFileOnly(home: paths, clock: FixedClock(testNow))("auth \(jwt) key \(key.pemRepresentation)")
        let logged = try String(contentsOfFile: paths.commandsLog, encoding: .utf8)
        #expect(logged.contains("<jwt>") && logged.contains("<private key>"))
        #expect(!logged.contains(jwt) && !logged.contains("BEGIN"))
    }

    @Test("object keys are redacted too")
    func keys() {
        #expect(redactor.redact(JSONValue.object(["/Users/someone/x": "a@b.invalid"])) == ["/Users/<user>/x": "<email>"])
    }

    @Test("unknown errors become INTERNAL_ERROR, SideloadError keeps its code")
    func fromError() {
        struct Boom: Error {}
        let internalError = Envelope.from(Boom(), command: "x")
        #expect(!internalError.ok)
        #expect(internalError.errors.first?.code == "INTERNAL_ERROR")
        #expect(internalError.errors.first?.fix == "This is a bug in sideload; re-run and report the code.")
        let known = Envelope.from(SideloadError("USAGE", "bad", fix: "help", data: ["k": 1]), command: "y")
        #expect(known.errors == [.init(code: "USAGE", message: "bad", fix: "help")])
        #expect(known.data == ["k": 1])
    }

    @Test("keys are sorted, slashes unescaped, missing fix encodes as null")
    func encoding() throws {
        let out = try Output.render(Envelope.fail("z", code: "C", message: "m", data: ["b": "a/b", "a": 1]))
        #expect(out == #"{"a":1,"b":"a/b","command":"z","errors":[{"code":"C","fix":null,"message":"m"}],"ok":false}"# + "\n")
    }

    @Test("envelope fields win over same-named data keys")
    func reservedKeys() {
        let e = Envelope.result("x", ["ok": false, "command": "other", "errors": "nope"])
        #expect(e.json == ["ok": true, "command": "x", "errors": []])
    }

    @Test("JSONValue round-trips and converts Encodable values")
    func jsonValue() throws {
        struct Typed: Encodable { let name: String; let count: Int; let tags: [String]; let none: String? }
        let v = try JSONValue(encoding: Typed(name: "n", count: 2, tags: ["a"], none: nil))
        #expect(v == ["name": "n", "count": 2, "tags": ["a"]])
        let text = #"{"a":[1,2.5,true,null,"s",{"b":{}}]}"#
        let decoded = try decode(text)
        #expect(try decode(String(decoding: JSONEncoder().encode(decoded), as: UTF8.self)) == decoded)
    }
}

extension JSONValue {
    fileprivate var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
