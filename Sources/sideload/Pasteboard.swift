import AppKit
import SideloadCore

/// The macOS general pasteboard behind `PasteboardBackend` (`SideloadCore` imports no AppKit). The item carries
/// the string plus the two community markers that make clipboard managers skip it.
struct AppKitPasteboardBackend: PasteboardBackend {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var changeCount: Int { NSPasteboard.general.changeCount }

    func replaceWithConcealed(_ secret: String) throws -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        guard item.setString(secret, forType: .string), item.setString("", forType: Self.concealed),
            item.setString("", forType: Self.transient), board.writeObjects([item])
        else {
            board.clearContents()
            throw SideloadError("PASTEBOARD_FAILED", "The pasteboard rejected the item.")
        }
        return board.changeCount
    }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}

/// The one clipboard the CLI uses. `export-cert --copy-password` copies through it and clears it after 90 s; the
/// interrupt handler clears it too, waiting up to 500 ms for a clear already in flight; if AppKit takes longer, the
/// process exits with the clear unfinished and reports `clipboardCleared` null. Until something is copied,
/// `clearIfOurs` returns without touching AppKit.
let cliPasteboard = ConcealedClipboard(backend: AppKitPasteboardBackend())

/// `export-cert`'s signal protocol; the signal handlers call `trip()` before anything else.
let cliHoldSignal = HoldSignal(onImpatient: {
    // Bounded: a full stderr pipe must not hold the signal queue.
    _ = Interrupt.bounded(timeout: .milliseconds(500)) {
        fputs("sideload: finishing cleanup; kill -9 to force\n", stderr)
    }
})

/// What a running command wants in the `INTERRUPTED` object (`provision --renew`); the signal handlers read it.
let cliInterruptReport = InterruptReport()

/// Work to run once the one stdout object was fully written (`provision`'s ledger settlement); `main.swift` runs it.
let cliPostEmit = PostEmit()

/// The live `Services` plus the CLI's pasteboard, hold signal and interrupt report.
func liveServices() -> Services {
    var services = Services.live()
    services.pasteboard = cliPasteboard
    services.holdSignal = cliHoldSignal
    services.interruptReport = cliInterruptReport
    services.postEmit = cliPostEmit
    return services
}
