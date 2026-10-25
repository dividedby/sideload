import Foundation
import Synchronization
import Testing

@testable import SideloadCore

/// Stands in for NSPasteboard.general: a change count that moves on every write, the string, and the markers.
final class FakePasteboardBackend: PasteboardBackend {
    struct State {
        var count = 1
        var contents: String?
        var markers: [String] = []
        var clears = 0
        var reads = 0
        var failWrites = false
    }

    private let state = Mutex(State())

    var snapshot: State { state.withLock { $0 } }
    var changeCount: Int {
        state.withLock { s in
            s.reads += 1
            return s.count
        }
    }

    func failNextWrites() { state.withLock { $0.failWrites = true } }

    /// The owner copies something else.
    func userCopies(_ text: String) {
        state.withLock { s in
            s.count += 1
            s.contents = text
            s.markers = []
        }
    }

    func replaceWithConcealed(_ secret: String) throws -> Int {
        try state.withLock { s in
            if s.failWrites { throw SideloadError("PASTEBOARD_FAILED", "fake") }
            s.count += 1
            s.contents = secret
            s.markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
            return s.count
        }
    }

    func clear() {
        state.withLock { s in
            s.count += 1
            s.contents = nil
            s.markers = []
            s.clears += 1
        }
    }
}

/// A backend whose `clear()` blocks until released, like an AppKit round trip that is still running.
final class BlockingClearBackend: PasteboardBackend {
    private let inner = FakePasteboardBackend()
    let clearEntered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var snapshot: FakePasteboardBackend.State { inner.snapshot }
    var changeCount: Int { inner.changeCount }
    func replaceWithConcealed(_ secret: String) throws -> Int { try inner.replaceWithConcealed(secret) }
    func clear() {
        clearEntered.signal()
        _ = release.wait(timeout: .now() + 20)  // bounded so a bug fails the test instead of hanging it
        inner.clear()
    }
}

@Suite("secret pasteboard")
struct SecretPasteboardTests {
    @Test("copy puts the secret on the pasteboard; clearIfOurs clears it once")
    func copyThenClear() throws {
        let backend = FakePasteboardBackend()
        let clipboard = ConcealedClipboard(backend: backend)
        try clipboard.copy("secret-value")
        #expect(backend.snapshot.contents == "secret-value")
        #expect(backend.snapshot.markers.contains("org.nspasteboard.ConcealedType"))
        #expect(backend.snapshot.markers.contains("org.nspasteboard.TransientType"))
        #expect(clipboard.clearIfOurs())
        #expect(backend.snapshot.contents == nil && backend.snapshot.clears == 1)
        #expect(!clipboard.clearIfOurs(), "idempotent: the second call (a signal racing the timer) does nothing")
        #expect(backend.snapshot.clears == 1)
    }

    @Test("something the owner copied since is never wiped")
    func changedByTheOwner() throws {
        let backend = FakePasteboardBackend()
        let clipboard = ConcealedClipboard(backend: backend)
        try clipboard.copy("secret-value")
        backend.userCopies("my own text")
        #expect(!clipboard.clearIfOurs())
        #expect(backend.snapshot.contents == "my own text" && backend.snapshot.clears == 0)
        #expect(!clipboard.clearIfOurs())
    }

    @Test("clear() tells apart cleared, already cleared by the main flow, changed by the owner, and never copied")
    func clearOutcomes() throws {
        let backend = FakePasteboardBackend()
        let clipboard = ConcealedClipboard(backend: backend)
        #expect(clipboard.clear() == .nothingCopied && !clipboard.clear().passwordCleared)
        try clipboard.copy("secret-value")
        #expect(clipboard.clear() == .cleared)
        #expect(clipboard.clear() == .alreadyCleared && clipboard.clear().passwordCleared, "the main flow already cleared it")
        #expect(backend.snapshot.clears == 1)

        try clipboard.copy("secret-value")
        backend.userCopies("my own text")
        #expect(clipboard.clear() == .changedSince && !clipboard.clear().passwordCleared)
        #expect(clipboard.clear() == .changedSince && backend.snapshot.contents == "my own text" && backend.snapshot.clears == 1)

        // clearIfOurs keeps its meaning: true only for the call that cleared
        try clipboard.copy("again")
        #expect(clipboard.clearIfOurs() && !clipboard.clearIfOurs())
    }

    @Test("a second clearIfOurs waits for the first clear to finish before returning")
    func secondClearWaitsForTheFirst() throws {
        let backend = BlockingClearBackend()
        let clipboard = ConcealedClipboard(backend: backend)
        try clipboard.copy("secret-value")
        let signal = HoldSignal()
        try signal.beginWriting()
        #expect(signal.beginCommit())
        signal.markCommitted(kit: "k")
        #expect(signal.beginCopy())
        signal.copyFinished()  // holding: the password is on the clipboard

        // Main's clear is in flight (an AppKit round trip), blocked inside the backend.
        let mainClear = Thread { _ = clipboard.clearIfOurs() }
        mainClear.start()
        #expect(backend.clearEntered.wait(timeout: .now() + 10) == .success)

        // First signal ends the hold; the second reaches the handler, which clears (bounded) before it exits.
        #expect(signal.trip() == .absorbed)
        #expect(signal.trip() == .notAbsorbed(kit: "k"))
        let handlerDone = DispatchSemaphore(value: 0)
        let handlerResult = Mutex<ClearOutcome?>(nil)
        Thread {
            handlerResult.withLock { $0 = clipboard.clear() }
            handlerDone.signal()
        }.start()
        #expect(handlerDone.wait(timeout: .now() + 0.3) == .timedOut, "the handler's clear returned while main's was still running")
        #expect(backend.snapshot.contents == "secret-value")

        backend.release.signal()
        #expect(handlerDone.wait(timeout: .now() + 10) == .success)
        #expect(backend.snapshot.contents == nil && backend.snapshot.clears == 1, "clear, once, before the handler may exit")
        #expect(handlerResult.withLock { $0 } == .alreadyCleared, "main cleared it; the handler reports that, not \"never held it\"")
        #expect(handlerResult.withLock { $0 }?.passwordCleared == true)
    }

    @Test("before anything is copied clearIfOurs does not touch the pasteboard at all")
    func inertUntilCopied() {
        let backend = FakePasteboardBackend()
        let clipboard = ConcealedClipboard(backend: backend)
        #expect(!clipboard.clearIfOurs())
        #expect(backend.snapshot.reads == 0 && backend.snapshot.clears == 0)
    }

    @Test("a failed write arms nothing and reports PASTEBOARD_FAILED without the secret")
    func failedWrite() {
        let backend = FakePasteboardBackend()
        backend.failNextWrites()
        let clipboard = ConcealedClipboard(backend: backend)
        do {
            try clipboard.copy("secret-value")
            Issue.record("expected a failure")
        } catch {
            let e = error as? SideloadError
            #expect(e?.code == "PASTEBOARD_FAILED")
            #expect(!(e?.message ?? "").contains("secret-value") && !(e?.fix ?? "").contains("secret-value"))
        }
        #expect(!clipboard.clearIfOurs())
    }

    @Test("the inert default throws PASTEBOARD_UNAVAILABLE")
    func inertDefault() {
        let services = Services(
            runner: FakeRunner { _ in RunResult() }, fs: FakeFileSystem.free(gb: 1), clock: FixedClock(testNow),
            keychain: FakeKeychain(), home: Paths(home: "/nonexistent-sideload-test-home"))
        #expect(throws: SideloadError.self) { try services.pasteboard.copy("x") }
        #expect(!services.pasteboard.clearIfOurs())
    }
}

@Suite("pasteboard source hygiene")
struct PasteboardSourceHygieneTests {
    private func swiftFiles(_ sub: String) throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/" + sub)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!files.isEmpty)
        return files
    }

    @Test("SideloadCore imports no AppKit and never touches NSPasteboard; nothing shells out to pbcopy")
    func coreStaysFree() throws {
        for (path, text) in try swiftFiles("SideloadCore") {
            #expect(!text.contains("import AppKit") && !text.contains("NSPasteboard"), "\(path)")
        }
        for dir in ["SideloadCore", "sideload"] {
            for (path, text) in try swiftFiles(dir) {
                #expect(!text.contains("pbcopy") && !text.contains("pbpaste"), "\(path)")
            }
        }
    }

    @Test("NSPasteboard lives in one CLI file")
    func oneFile() throws {
        let users = try swiftFiles("sideload").filter { $0.text.contains("NSPasteboard") }.map(\.path)
        #expect(users.count == 1 && users[0].hasSuffix("/Pasteboard.swift"))
    }
}
