import Darwin
import Dispatch
import Synchronization
import SideloadCore

/// Handles SIGINT/SIGTERM/SIGHUP with `DispatchSource`s. The default dispositions are ignored so the
/// sources see the signals; `PosixSpawnRunner` resets them in children so they still react normally.
func installInterruptHandlers(_ interrupt: Interrupt) -> [any DispatchSourceSignal] {
    let queue = DispatchQueue(label: "sideload.interrupt")
    return [SIGINT, SIGTERM, SIGHUP].map { signo in
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
        source.setEventHandler {
            // `export-cert` absorbs signals while it is writing (see `HoldSignal`) and cleans up itself: this handler
            // never touches a file. Only a signal that is not absorbed (nothing started yet, a second one after the
            // kit is in place, or after the command finished) takes the INTERRUPTED path below.
            guard case .notAbsorbed(let kit) = cliHoldSignal.trip() else { return }
            // Clear the pasteboard (only if still ours) before the process dies. Bounded to 500 ms: if main's clear is
            // still running after that, the process exits anyway and the report says the clipboard state is unknown.
            let cleared = Mutex<Bool?>(nil)
            _ = Interrupt.bounded(timeout: .milliseconds(500)) {
                // `.alreadyCleared`: the main flow got there first, which is just as good for the report.
                let outcome = cliPasteboard.clear()
                cleared.withLock { $0 = outcome.passwordCleared }
            }
            // A command that already changed things (`provision --renew` moved cached profiles) reports it. Reading the
            // report seals its progress, so a move that main starts afterwards is refused; bounded, so a stuck lock can
            // never hold the exit.
            let context = Mutex<[String: JSONValue]>([:])
            _ = Interrupt.bounded(timeout: .milliseconds(500)) {
                if let report = cliInterruptReport.current() { context.withLock { $0 = report } }
            }
            // After the kit exists the object reports it (and the clipboard) instead of saying to re-run.
            // `inspect` unpacks an untrusted IPA into a scratch folder that must not outlive the process: the interrupt
            // gate removes it once the child groups are dead and before the object is written.
            let code = interrupt.handle(
                signal: signo, kit: kit, clipboardCleared: kit == nil ? nil : cleared.withLock { $0 },
                context: context.withLock { $0 }, cleanup: { ScratchRegistry.shared.removeAllAndClose() })
            // _exit, not exit: stdio flush and atexit handlers could block after an abandoned write.
            if let code { _exit(code) } else { park() }
        }
        source.resume()
        return source
    }
}
